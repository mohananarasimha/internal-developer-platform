"""Unit tests for service.yaml schema validation and policy guardrails."""

from __future__ import annotations

from pathlib import Path

import pytest

from idp_cli.policy import (
    RESOURCE_PROFILES,
    SpecParseError,
    get_resources_for_profile,
    validate_service_file,
    validate_spec_dict,
)

REPO_ROOT = Path(__file__).resolve().parents[3]
PAYMENTS_SPEC = REPO_ROOT / "services" / "payments-api" / "service.yaml"
EXP01_DIR = REPO_ROOT / "experiments" / "01-config-validation"


def test_valid_payments_api_spec_passes() -> None:
    result = validate_service_file(PAYMENTS_SPEC, environments=("staging", "prod"))
    assert result.valid is True
    assert result.spec is not None
    assert result.violations == ()

    staging = result.spec.resolve_environment("staging")
    prod = result.spec.resolve_environment("prod")
    assert staging.sizing.profile == "small"
    assert staging.sizing.minReplicas == 1
    assert staging.env["APP_ENV"] == "staging"
    assert prod.sizing.profile == "medium"
    assert prod.sizing.minReplicas == 2
    assert prod.sizing.maxReplicas == 6
    assert prod.env["APP_ENV"] == "prod"


@pytest.mark.parametrize(
    ("fixture_name", "expected_codes"),
    [
        ("invalid-latest-tag.yaml", {"IDP_TAG_LATEST"}),
        ("invalid-secret-in-env.yaml", {"IDP_ENV_SECRET_FORBIDDEN"}),
        (
            "invalid-prod-single-replica.yaml",
            {"IDP_PROD_MIN_REPLICAS", "IDP_CRITICAL_PROD_REPLICAS"},
        ),
        ("invalid-privileged-port.yaml", {"IDP_PORT_PRIVILEGED"}),
    ],
)
def test_experiment_01_invalid_fixtures_fail_with_exact_codes(
    fixture_name: str,
    expected_codes: set[str],
) -> None:
    fixture_path = EXP01_DIR / fixture_name
    result = validate_service_file(fixture_path, environments=("staging", "prod"))
    assert result.valid is False
    observed_codes = {violation.code for violation in result.violations}
    assert expected_codes.issubset(observed_codes)


def test_sha256_digest_tag_is_accepted() -> None:
    raw = {
        "apiVersion": "idp.local/v1",
        "kind": "ServiceSpec",
        "metadata": {"name": "ledger-worker", "owner": "payments-team", "tier": "standard"},
        "runtime": {
            "image": "ghcr.io/mohananarasimha/ledger-worker",
            "tag": "sha256:" + "a" * 64,
            "port": 8080,
        },
        "sizing": {"profile": "large", "minReplicas": 2, "maxReplicas": 4, "targetCPU": 70},
        "env": {"LOG_LEVEL": "info"},
        "secretRefs": ["ledger-db"],
    }
    result = validate_spec_dict(raw, environments=("staging", "prod"))
    assert result.valid is True
    assert result.violations == ()


def test_max_replicas_less_than_min_replicas_rejected() -> None:
    raw = {
        "apiVersion": "idp.local/v1",
        "kind": "ServiceSpec",
        "metadata": {"name": "checkout-api", "owner": "checkout-team", "tier": "standard"},
        "runtime": {
            "image": "ghcr.io/mohananarasimha/checkout-api",
            "tag": "2.0.1",
            "port": 8080,
        },
        "sizing": {"profile": "small", "minReplicas": 3, "maxReplicas": 2, "targetCPU": 70},
    }
    result = validate_spec_dict(raw, environments=("prod",))
    assert result.valid is False
    assert {v.code for v in result.violations} == {"IDP_REPLICAS_RANGE"}


def test_deterministic_resource_profile_mapping() -> None:
    assert set(RESOURCE_PROFILES.keys()) == {"small", "medium", "large"}
    assert get_resources_for_profile("small") == {
        "requests": {"cpu": "100m", "memory": "128Mi"},
        "limits": {"cpu": "250m", "memory": "256Mi"},
    }
    assert get_resources_for_profile("medium") == {
        "requests": {"cpu": "250m", "memory": "256Mi"},
        "limits": {"cpu": "500m", "memory": "512Mi"},
    }
    assert get_resources_for_profile("large") == {
        "requests": {"cpu": "500m", "memory": "512Mi"},
        "limits": {"cpu": "1000m", "memory": "1Gi"},
    }


def test_missing_and_malformed_yaml_raise_parse_error(tmp_path: Path) -> None:
    with pytest.raises(SpecParseError):
        validate_service_file(tmp_path / "does-not-exist.yaml")

    malformed = tmp_path / "malformed.yaml"
    malformed.write_text("metadata:\n  name: [unclosed\n", encoding="utf-8")
    with pytest.raises(SpecParseError):
        validate_service_file(malformed)
