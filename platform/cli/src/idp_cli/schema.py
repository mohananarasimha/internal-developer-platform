"""Pydantic v2 schema definitions for developer-authored service.yaml files."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator
from pydantic_core import PydanticCustomError

EnvironmentName = Literal["staging", "prod"]
TierName = Literal["critical", "standard"]
SizingProfileName = Literal["small", "medium", "large"]

DNS1123_LABEL_RE = re.compile(r"^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$")
TEAM_SLUG_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
SECRET_NAME_RE = re.compile(r"^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$")
SEMVER_RE = re.compile(
    r"^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)
SHA256_DIGEST_RE = re.compile(r"^sha256:[a-f0-9]{64}$")

MIN_NON_PRIVILEGED_PORT = 1024
MAX_PORT = 65535
MIN_TARGET_CPU = 50
MAX_TARGET_CPU = 90


def _validate_port(value: int) -> int:
    if value < MIN_NON_PRIVILEGED_PORT:
        raise PydanticCustomError(
            "IDP_PORT_PRIVILEGED",
            "Container port {port} is privileged (<1024); non-root containers require 1024-65535",
            {"port": value},
        )
    if value > MAX_PORT:
        raise PydanticCustomError(
            "IDP_PORT_OUT_OF_RANGE",
            "Container port {port} exceeds maximum TCP port 65535",
            {"port": value},
        )
    return value


def _validate_target_cpu(value: int) -> int:
    if value < MIN_TARGET_CPU or value > MAX_TARGET_CPU:
        raise PydanticCustomError(
            "IDP_TARGET_CPU_RANGE",
            "targetCPU must be between 50 and 90 percent (got {value})",
            {"value": value},
        )
    return value


def _validate_min_positive_replicas(value: int) -> int:
    if value < 1:
        raise PydanticCustomError(
            "IDP_REPLICAS_MIN",
            "Replica count must be >= 1 (got {value})",
            {"value": value},
        )
    return value


def _validate_http_path(value: str) -> str:
    if not value.startswith("/") or any(ch.isspace() for ch in value):
        raise PydanticCustomError(
            "IDP_PATH_INVALID",
            "HTTP path must start with '/' and contain no whitespace (got '{value}')",
            {"value": value},
        )
    return value


class MetadataConfig(BaseModel):
    """Service ownership and identity metadata."""

    model_config = ConfigDict(extra="forbid")

    name: str
    owner: str
    tier: TierName

    @field_validator("name")
    @classmethod
    def validate_name(cls, value: str) -> str:
        if not DNS1123_LABEL_RE.match(value):
            raise PydanticCustomError(
                "IDP_METADATA_NAME",
                "metadata.name must be a valid DNS-1123 lowercase label (got '{value}')",
                {"value": value},
            )
        return value

    @field_validator("owner")
    @classmethod
    def validate_owner(cls, value: str) -> str:
        stripped = value.strip()
        if not stripped or not TEAM_SLUG_RE.match(stripped):
            raise PydanticCustomError(
                "IDP_METADATA_OWNER",
                "metadata.owner must be a non-empty lowercase team slug (got '{value}')",
                {"value": value},
            )
        return stripped


class RuntimeConfig(BaseModel):
    """Container image, port, and probe/metrics endpoint configuration."""

    model_config = ConfigDict(extra="forbid")

    image: str
    tag: str
    port: int
    healthPath: str = "/healthz"
    metricsPath: str = "/metrics"

    @field_validator("image")
    @classmethod
    def validate_image(cls, value: str) -> str:
        if not value or any(ch.isspace() for ch in value):
            raise PydanticCustomError(
                "IDP_IMAGE_INVALID",
                "runtime.image must be a non-empty container image reference without whitespace",
            )
        final_segment = value.rsplit("/", maxsplit=1)[-1]
        if ":" in final_segment or "@" in value:
            raise PydanticCustomError(
                "IDP_IMAGE_EMBEDDED_TAG",
                "runtime.image must not embed a tag or digest; specify it in runtime.tag",
            )
        return value

    @field_validator("tag")
    @classmethod
    def validate_tag(cls, value: str) -> str:
        if not value or any(ch.isspace() for ch in value):
            raise PydanticCustomError(
                "IDP_TAG_INVALID",
                "runtime.tag must be non-empty and contain no whitespace",
            )
        if value.lower() == "latest":
            raise PydanticCustomError(
                "IDP_TAG_LATEST",
                "Mutable image tag 'latest' is forbidden; use immutable semver or sha256 digest",
            )
        if not (SEMVER_RE.match(value) or SHA256_DIGEST_RE.match(value)):
            raise PydanticCustomError(
                "IDP_TAG_FORMAT",
                "runtime.tag must be a semver tag (e.g. 1.4.2) or sha256:<64-hex> digest",
            )
        return value

    @field_validator("port")
    @classmethod
    def validate_port(cls, value: int) -> int:
        return _validate_port(value)

    @field_validator("healthPath", "metricsPath")
    @classmethod
    def validate_paths(cls, value: str) -> str:
        return _validate_http_path(value)


class SizingConfig(BaseModel):
    """Workload sizing profile and autoscaling bounds."""

    model_config = ConfigDict(extra="forbid")

    profile: SizingProfileName
    minReplicas: int
    maxReplicas: int
    targetCPU: int

    @field_validator("minReplicas", "maxReplicas")
    @classmethod
    def validate_replicas(cls, value: int) -> int:
        return _validate_min_positive_replicas(value)

    @field_validator("targetCPU")
    @classmethod
    def validate_target_cpu(cls, value: int) -> int:
        return _validate_target_cpu(value)


class SizingOverride(BaseModel):
    """Optional environment-specific overrides for sizing fields."""

    model_config = ConfigDict(extra="forbid")

    profile: SizingProfileName | None = None
    minReplicas: int | None = None
    maxReplicas: int | None = None
    targetCPU: int | None = None

    @field_validator("minReplicas", "maxReplicas")
    @classmethod
    def validate_replicas(cls, value: int | None) -> int | None:
        if value is not None:
            return _validate_min_positive_replicas(value)
        return value

    @field_validator("targetCPU")
    @classmethod
    def validate_target_cpu(cls, value: int | None) -> int | None:
        if value is not None:
            return _validate_target_cpu(value)
        return value


class EnvironmentOverride(BaseModel):
    """Per-environment override block inside service.yaml."""

    model_config = ConfigDict(extra="forbid")

    sizing: SizingOverride | None = None
    env: dict[str, str] = Field(default_factory=dict)


class EnvironmentsConfig(BaseModel):
    """Supported target deployment environments."""

    model_config = ConfigDict(extra="forbid")

    staging: EnvironmentOverride | None = None
    prod: EnvironmentOverride | None = None


@dataclass(frozen=True)
class ResolvedServiceConfig:
    """Merged service configuration for a single target environment."""

    environment: EnvironmentName
    metadata: MetadataConfig
    runtime: RuntimeConfig
    sizing: SizingConfig
    env: dict[str, str]
    secretRefs: tuple[str, ...]


class ServiceSpec(BaseModel):
    """Top-level developer-owned service specification."""

    model_config = ConfigDict(extra="forbid")

    apiVersion: Literal["idp.local/v1"] = "idp.local/v1"
    kind: Literal["ServiceSpec"] = "ServiceSpec"
    metadata: MetadataConfig
    runtime: RuntimeConfig
    sizing: SizingConfig
    env: dict[str, str] = Field(default_factory=dict)
    secretRefs: list[str] = Field(default_factory=list)
    environments: EnvironmentsConfig = Field(default_factory=EnvironmentsConfig)

    @field_validator("secretRefs")
    @classmethod
    def validate_secret_refs(cls, value: list[str]) -> list[str]:
        for secret_name in value:
            if not SECRET_NAME_RE.match(secret_name):
                raise PydanticCustomError(
                    "IDP_SECRET_REF_NAME",
                    "secretRefs entry '{name}' is not a valid Kubernetes Secret name",
                    {"name": secret_name},
                )
        return value

    def resolve_environment(self, env: EnvironmentName) -> ResolvedServiceConfig:
        """Merge base config with environment-specific overrides."""
        override = getattr(self.environments, env)
        merged_sizing = self.sizing.model_dump()
        merged_env = dict(self.env)

        if override is not None:
            if override.sizing is not None:
                for key, val in override.sizing.model_dump(exclude_none=True).items():
                    merged_sizing[key] = val
            merged_env.update(override.env)

        sorted_env = dict(sorted(merged_env.items()))
        sorted_secrets = tuple(sorted(set(self.secretRefs)))

        return ResolvedServiceConfig(
            environment=env,
            metadata=self.metadata,
            runtime=self.runtime,
            sizing=SizingConfig.model_validate(merged_sizing),
            env=sorted_env,
            secretRefs=sorted_secrets,
        )
