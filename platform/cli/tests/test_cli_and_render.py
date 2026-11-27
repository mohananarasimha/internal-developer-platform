"""CLI and Helm manifest rendering integration tests."""

from __future__ import annotations

import json
from pathlib import Path

import pytest
import yaml
from typer.testing import CliRunner

from idp_cli.cli import app

REPO_ROOT = Path(__file__).resolve().parents[3]
PAYMENTS_SPEC = REPO_ROOT / "services" / "payments-api" / "service.yaml"
EXP01_DIR = REPO_ROOT / "experiments" / "01-config-validation"

runner = CliRunner()


def test_cli_validate_valid_config_exits_0() -> None:
    res = runner.invoke(app, ["validate", str(PAYMENTS_SPEC), "--env", "all", "--format", "json"])
    assert res.exit_code == 0, res.output
    payload = json.loads(res.stdout)
    assert payload["valid"] is True
    assert payload["violations"] == []


@pytest.mark.parametrize(
    ("fixture_name", "expected_code"),
    [
        ("invalid-latest-tag.yaml", "IDP_TAG_LATEST"),
        ("invalid-secret-in-env.yaml", "IDP_ENV_SECRET_FORBIDDEN"),
        ("invalid-prod-single-replica.yaml", "IDP_PROD_MIN_REPLICAS"),
        ("invalid-privileged-port.yaml", "IDP_PORT_PRIVILEGED"),
    ],
)
def test_cli_validate_invalid_fixtures_exit_1(fixture_name: str, expected_code: str) -> None:
    fixture = EXP01_DIR / fixture_name
    res = runner.invoke(app, ["validate", str(fixture), "--env", "all", "--format", "json"])
    assert res.exit_code == 1
    payload = json.loads(res.stdout)
    assert payload["valid"] is False
    codes = {v["code"] for v in payload["violations"]}
    assert expected_code in codes


def test_cli_validate_missing_and_malformed_yaml_exit_2(tmp_path: Path) -> None:
    missing = tmp_path / "missing.yaml"
    res_missing = runner.invoke(app, ["validate", str(missing), "--format", "json"])
    assert res_missing.exit_code == 2

    malformed = tmp_path / "bad.yaml"
    malformed.write_text("runtime:\n  port: : :\n", encoding="utf-8")
    res_malformed = runner.invoke(app, ["validate", str(malformed), "--format", "json"])
    assert res_malformed.exit_code == 2


def test_cli_render_produces_hardened_k8s_manifests_deterministically(tmp_path: Path) -> None:
    out_dir = tmp_path / "rendered"
    first = runner.invoke(
        app,
        ["render", str(PAYMENTS_SPEC), "--env", "all", "--out-dir", str(out_dir)],
    )
    assert first.exit_code == 0, first.output

    prod_manifests_path = out_dir / "prod" / "payments-api" / "manifests.yaml"
    staging_manifests_path = out_dir / "staging" / "payments-api" / "manifests.yaml"
    assert prod_manifests_path.is_file()
    assert staging_manifests_path.is_file()

    prod_text_run1 = prod_manifests_path.read_text(encoding="utf-8")
    prod_docs = [doc for doc in yaml.safe_load_all(prod_text_run1) if doc is not None]
    staging_docs = [
        doc
        for doc in yaml.safe_load_all(staging_manifests_path.read_text(encoding="utf-8"))
        if doc is not None
    ]

    prod_by_kind = {doc["kind"]: doc for doc in prod_docs}
    staging_by_kind = {doc["kind"]: doc for doc in staging_docs}

    assert set(prod_by_kind.keys()) == {
        "Deployment",
        "Service",
        "PodDisruptionBudget",
        "HorizontalPodAutoscaler",
    }
    assert set(staging_by_kind.keys()) == {
        "Deployment",
        "Service",
        "HorizontalPodAutoscaler",
    }

    deployment = prod_by_kind["Deployment"]
    assert {doc["metadata"]["namespace"] for doc in prod_docs} == {"payments-team-prod"}
    assert deployment["spec"]["strategy"]["rollingUpdate"]["maxUnavailable"] == 0

    pod_spec = deployment["spec"]["template"]["spec"]
    assert pod_spec["securityContext"]["runAsNonRoot"] is True
    assert pod_spec["securityContext"]["seccompProfile"]["type"] == "RuntimeDefault"

    container = pod_spec["containers"][0]
    assert container["securityContext"]["runAsNonRoot"] is True
    assert container["securityContext"]["readOnlyRootFilesystem"] is True
    assert container["securityContext"]["allowPrivilegeEscalation"] is False
    assert container["securityContext"]["capabilities"]["drop"] == ["ALL"]
    assert container["resources"] == {
        "requests": {"cpu": "250m", "memory": "256Mi"},
        "limits": {"cpu": "500m", "memory": "512Mi"},
    }
    assert container["envFrom"] == [
        {"secretRef": {"name": "payments-db-credentials"}},
        {"secretRef": {"name": "payments-signing-keys"}},
    ]
    assert container["startupProbe"]["httpGet"]["path"] == "/livez"
    assert container["livenessProbe"]["httpGet"]["path"] == "/livez"
    assert container["readinessProbe"]["httpGet"]["path"] == "/healthz"

    annotations = deployment["spec"]["template"]["metadata"]["annotations"]
    assert annotations["prometheus.io/scrape"] == "true"
    assert annotations["prometheus.io/port"] == "8080"
    assert annotations["prometheus.io/path"] == "/metrics"

    pdb = prod_by_kind["PodDisruptionBudget"]
    assert pdb["spec"]["minAvailable"] == 1

    hpa = prod_by_kind["HorizontalPodAutoscaler"]
    assert hpa["spec"]["behavior"]["scaleDown"]["stabilizationWindowSeconds"] == 300

    # Re-render and verify byte-identical determinism
    second = runner.invoke(
        app,
        ["render", str(PAYMENTS_SPEC), "--env", "all", "--out-dir", str(out_dir)],
    )
    assert second.exit_code == 0, second.output
    assert prod_manifests_path.read_text(encoding="utf-8") == prod_text_run1


def test_cli_render_refuses_invalid_spec(tmp_path: Path) -> None:
    out_dir = tmp_path / "rendered"
    invalid = EXP01_DIR / "invalid-latest-tag.yaml"
    res = runner.invoke(app, ["render", str(invalid), "--env", "all", "--out-dir", str(out_dir)])
    assert res.exit_code == 1
    assert not out_dir.exists()
