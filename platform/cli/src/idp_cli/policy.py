"""Policy guardrail engine and deterministic resource profile mapping."""

from __future__ import annotations

import re
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml
from pydantic import ValidationError

from idp_cli.schema import EnvironmentName, ResolvedServiceConfig, ServiceSpec, SizingProfileName

ALL_ENVIRONMENTS: tuple[EnvironmentName, ...] = ("staging", "prod")

RESOURCE_PROFILES: dict[SizingProfileName, dict[str, dict[str, str]]] = {
    "small": {
        "requests": {"cpu": "100m", "memory": "128Mi"},
        "limits": {"cpu": "250m", "memory": "256Mi"},
    },
    "medium": {
        "requests": {"cpu": "250m", "memory": "256Mi"},
        "limits": {"cpu": "500m", "memory": "512Mi"},
    },
    "large": {
        "requests": {"cpu": "500m", "memory": "512Mi"},
        "limits": {"cpu": "1000m", "memory": "1Gi"},
    },
}

SECRET_KEY_PATTERNS: tuple[re.Pattern[str], ...] = (
    re.compile(r"(?:^|_)(?:PASSWORD|PASSWD|PWD)(?:$|_)", re.IGNORECASE),
    re.compile(r"(?:^|_)SECRETS?(?:$|_)", re.IGNORECASE),
    re.compile(r"(?:^|_)TOKENS?(?:$|_)", re.IGNORECASE),
    re.compile(r"(?:^|_)API_?KEY(?:$|_)", re.IGNORECASE),
    re.compile(r"(?:^|_)PRIVATE_?KEY(?:$|_)", re.IGNORECASE),
    re.compile(r"(?:^|_)AWS_SECRET", re.IGNORECASE),
    re.compile(r"(?:^|_)ACCESS_?KEY(?:$|_)", re.IGNORECASE),
    re.compile(r"(?:^|_)CREDENTIALS?(?:$|_)", re.IGNORECASE),
)

SECRET_VALUE_PATTERNS: tuple[re.Pattern[str], ...] = (
    re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
)


class SpecParseError(Exception):
    """Raised when a service.yaml file cannot be read or parsed as YAML mapping."""


@dataclass(frozen=True)
class PolicyViolation:
    """Structured schema or policy violation returned by validation."""

    code: str
    environment: str
    field: str
    message: str

    def to_dict(self) -> dict[str, str]:
        return {
            "code": self.code,
            "environment": self.environment,
            "field": self.field,
            "message": self.message,
        }


@dataclass(frozen=True)
class ValidationResult:
    """Aggregate result of schema + policy validation."""

    valid: bool
    spec: ServiceSpec | None
    violations: tuple[PolicyViolation, ...]

    def to_dict(self, file_path: Path, environments: Sequence[EnvironmentName]) -> dict[str, Any]:
        return {
            "valid": self.valid,
            "file": str(file_path),
            "environments": list(environments),
            "violations": [v.to_dict() for v in self.violations],
        }


def get_resources_for_profile(profile: SizingProfileName) -> dict[str, dict[str, str]]:
    """Return deterministic CPU/memory requests and limits for a sizing profile."""
    profile_resources = RESOURCE_PROFILES[profile]
    return {
        "requests": dict(profile_resources["requests"]),
        "limits": dict(profile_resources["limits"]),
    }


def load_raw_yaml(path: Path) -> dict[str, Any]:
    """Read and parse a YAML file, ensuring the root document is a mapping."""
    if not path.exists():
        raise SpecParseError(f"Service specification file not found: {path}")
    if not path.is_file():
        raise SpecParseError(f"Path is not a file: {path}")

    try:
        content = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise SpecParseError(f"Failed to read {path}: {exc}") from exc

    try:
        parsed = yaml.safe_load(content)
    except yaml.YAMLError as exc:
        raise SpecParseError(f"Invalid YAML syntax in {path}: {exc}") from exc

    if not isinstance(parsed, dict):
        raise SpecParseError(f"Expected a YAML mapping at root of {path}")

    return parsed


def _is_secret_like_key(key: str) -> bool:
    return any(pattern.search(key) for pattern in SECRET_KEY_PATTERNS)


def _is_secret_like_value(value: str) -> bool:
    return any(pattern.search(value) for pattern in SECRET_VALUE_PATTERNS)


def evaluate_resolved_policies(resolved: ResolvedServiceConfig) -> list[PolicyViolation]:
    """Evaluate platform guardrails against a single resolved environment config."""
    violations: list[PolicyViolation] = []
    env_name = resolved.environment

    # 1. Secrets boundary: block secret-like keys or raw credential values in env
    for key, val in resolved.env.items():
        if _is_secret_like_key(key):
            violations.append(
                PolicyViolation(
                    code="IDP_ENV_SECRET_FORBIDDEN",
                    environment=env_name,
                    field=f"env.{key}",
                    message=(
                        f"Environment key '{key}' looks like a secret; "
                        "declare external Secret names under secretRefs instead"
                    ),
                )
            )
        elif _is_secret_like_value(val):
            violations.append(
                PolicyViolation(
                    code="IDP_ENV_SECRET_VALUE_FORBIDDEN",
                    environment=env_name,
                    field=f"env.{key}",
                    message=(
                        f"Environment value for '{key}' matches a credential pattern; "
                        "secret values must never enter Git"
                    ),
                )
            )

    # 2. Replica range invariant: maxReplicas >= minReplicas
    if resolved.sizing.maxReplicas < resolved.sizing.minReplicas:
        violations.append(
            PolicyViolation(
                code="IDP_REPLICAS_RANGE",
                environment=env_name,
                field="sizing.maxReplicas",
                message=(
                    f"maxReplicas ({resolved.sizing.maxReplicas}) must be >= "
                    f"minReplicas ({resolved.sizing.minReplicas})"
                ),
            )
        )

    # 3. Production HA guardrail: prod requires minReplicas >= 2
    if env_name == "prod" and resolved.sizing.minReplicas < 2:
        violations.append(
            PolicyViolation(
                code="IDP_PROD_MIN_REPLICAS",
                environment=env_name,
                field="sizing.minReplicas",
                message=(
                    f"Production requires minReplicas >= 2 for availability "
                    f"(got {resolved.sizing.minReplicas})"
                ),
            )
        )

    return violations


def validate_spec_dict(
    raw: dict[str, Any],
    environments: Sequence[EnvironmentName] = ALL_ENVIRONMENTS,
) -> ValidationResult:
    """Validate raw parsed YAML against Pydantic schema and policy guardrails."""
    try:
        spec = ServiceSpec.model_validate(raw)
    except ValidationError as exc:
        violations: list[PolicyViolation] = []
        for err in exc.errors():
            err_type = str(err.get("type", "value_error"))
            code = err_type if err_type.startswith("IDP_") else "IDP_SCHEMA_ERROR"
            loc = ".".join(str(part) for part in err.get("loc", ())) or "<root>"
            msg = str(err.get("msg", "Schema validation error"))
            violations.append(
                PolicyViolation(
                    code=code,
                    environment="global",
                    field=loc,
                    message=msg,
                )
            )
        return ValidationResult(valid=False, spec=None, violations=tuple(violations))

    policy_violations: list[PolicyViolation] = []
    for env_name in environments:
        resolved = spec.resolve_environment(env_name)
        policy_violations.extend(evaluate_resolved_policies(resolved))

    return ValidationResult(
        valid=len(policy_violations) == 0,
        spec=spec,
        violations=tuple(policy_violations),
    )


def validate_service_file(
    path: Path,
    environments: Sequence[EnvironmentName] = ALL_ENVIRONMENTS,
) -> ValidationResult:
    """Load, schema-validate, and policy-check a service.yaml file."""
    raw = load_raw_yaml(path)
    return validate_spec_dict(raw, environments=environments)
