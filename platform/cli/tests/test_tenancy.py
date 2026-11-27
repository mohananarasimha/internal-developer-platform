"""TeamSpec validation, tenant bundle rendering, and tenancy guardrails in service rendering."""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml
from typer.testing import CliRunner

from idp_cli.cli import app
from idp_cli.policy import SpecParseError
from idp_cli.renderer import RenderError, render_environment
from idp_cli.schema import ServiceSpec
from idp_cli.tenancy import (
    TeamQuota,
    build_tenant_manifests,
    cpu_millicores,
    load_teams,
    memory_bytes,
    quota_shortfalls,
)

REPO_ROOT = Path(__file__).resolve().parents[3]
TEAMS_DIR = REPO_ROOT / "teams"
PAYMENTS_SPEC = REPO_ROOT / "services" / "payments-api" / "service.yaml"
runner = CliRunner()

QUOTA = {
    "requestsCpu": "1",
    "requestsMemory": "1Gi",
    "limitsCpu": "2",
    "limitsMemory": "2Gi",
    "pods": 6,
}


def _write_team(directory: Path, name: str, **spec: object) -> Path:
    body = {"group": f"team:{name}", "quota": {"staging": QUOTA, "prod": QUOTA}}
    body.update(spec)
    doc = {"apiVersion": "idp.local/v1", "kind": "TeamSpec", "metadata": {"name": name}}
    doc["spec"] = body
    path = directory / f"{name}.yaml"
    path.write_text(yaml.safe_dump(doc), encoding="utf-8")
    return path


def test_repo_teams_load_and_bundle_shape() -> None:
    teams = load_teams(TEAMS_DIR)
    assert set(teams) == {"ledger-team", "payments-team"}

    docs = build_tenant_manifests(teams["payments-team"], "prod")
    kinds = [(d["kind"], d["metadata"]["name"]) for d in docs]
    assert kinds == [
        ("Namespace", "payments-team-prod"),
        ("RoleBinding", "team-edit"),
        ("ResourceQuota", "team-quota"),
        ("LimitRange", "team-defaults"),
        ("NetworkPolicy", "default-deny-ingress"),
        ("NetworkPolicy", "allow-same-namespace"),
        ("NetworkPolicy", "allow-from-peer-teams"),
    ]
    ns_labels = docs[0]["metadata"]["labels"]
    assert ns_labels["pod-security.kubernetes.io/enforce"] == "restricted"
    assert ns_labels["idp.local/team"] == "payments-team"
    assert docs[1]["subjects"][0]["name"] == "team:payments-team"
    assert docs[2]["spec"]["hard"]["services.nodeports"] == "0"

    peer_rule = docs[6]["spec"]["ingress"][0]["from"][0]["namespaceSelector"]
    assert peer_rule["matchExpressions"] == [
        {"key": "idp.local/team", "operator": "In", "values": ["ledger-team"]},
        {"key": "idp.local/environment", "operator": "In", "values": ["prod"]},
    ]


def test_team_without_peers_has_no_peer_policy() -> None:
    ledger = load_teams(TEAMS_DIR)["ledger-team"]
    names = [d["metadata"]["name"] for d in build_tenant_manifests(ledger, "staging")]
    assert "allow-from-peer-teams" not in names
    assert "default-deny-ingress" in names


def test_unknown_peer_team_is_rejected(tmp_path: Path) -> None:
    _write_team(tmp_path, "alpha-team", allowIngressFrom=["ghost-team"])
    with pytest.raises(SpecParseError, match="unknown team"):
        load_teams(tmp_path)


def test_missing_environment_quota_is_rejected(tmp_path: Path) -> None:
    _write_team(tmp_path, "alpha-team", quota={"staging": QUOTA})
    with pytest.raises(SpecParseError, match="missing"):
        load_teams(tmp_path)


def test_filename_must_match_team_name(tmp_path: Path) -> None:
    path = _write_team(tmp_path, "alpha-team")
    path.rename(tmp_path / "other.yaml")
    with pytest.raises(SpecParseError, match="must be named after"):
        load_teams(tmp_path)


def test_quantity_parsing_and_quota_shortfalls() -> None:
    assert cpu_millicores("250m") == 250
    assert cpu_millicores("1.5") == 1500
    assert memory_bytes("256Mi") == 256 * 2**20
    assert memory_bytes("1Gi") == 2**30

    quota = TeamQuota(**QUOTA)
    small = {
        "requests": {"cpu": "100m", "memory": "128Mi"},
        "limits": {"cpu": "250m", "memory": "256Mi"},
    }
    assert quota_shortfalls(quota, 6, small) == []
    over = quota_shortfalls(quota, 9, small)
    assert "limits.cpu 9 x 250m > 2" in over
    assert "pods 9 > 6" in over


def _spec(owner: str, max_replicas: int) -> ServiceSpec:
    raw = yaml.safe_load(PAYMENTS_SPEC.read_text(encoding="utf-8"))
    raw["metadata"]["owner"] = owner
    raw["environments"]["staging"]["sizing"]["maxReplicas"] = max_replicas
    return ServiceSpec.model_validate(raw)


def test_render_rejects_owner_without_team(tmp_path: Path) -> None:
    with pytest.raises(RenderError, match="IDP_OWNER_UNKNOWN"):
        render_environment(_spec("ghost-team", 2), "staging", tmp_path / "out", teams_dir=TEAMS_DIR)


def test_render_rejects_hpa_ceiling_above_team_quota(tmp_path: Path) -> None:
    # payments-team staging: limits.cpu 2, small profile limit 250m -> at most 8 pods incl. surge.
    with pytest.raises(RenderError, match="IDP_QUOTA_EXCEEDED"):
        render_environment(
            _spec("payments-team", 8), "staging", tmp_path / "out", teams_dir=TEAMS_DIR
        )
    ok = render_environment(
        _spec("payments-team", 5), "staging", tmp_path / "out", teams_dir=TEAMS_DIR
    )
    values = yaml.safe_load(ok.values_path.read_text(encoding="utf-8"))
    assert values["namespace"] == "payments-team-staging"


def test_cli_render_tenants_writes_every_team_and_env(tmp_path: Path) -> None:
    out = tmp_path / "tenants"
    res = runner.invoke(
        app, ["render-tenants", "--teams-dir", str(TEAMS_DIR), "--out-dir", str(out)]
    )
    assert res.exit_code == 0, res.output
    written = sorted(p.relative_to(out).as_posix() for p in out.rglob("tenant.yaml"))
    assert written == [
        "ledger-team/prod/tenant.yaml",
        "ledger-team/staging/tenant.yaml",
        "payments-team/prod/tenant.yaml",
        "payments-team/staging/tenant.yaml",
    ]

    res = runner.invoke(app, ["render-tenants", "--teams-dir", str(tmp_path / "missing")])
    assert res.exit_code == 2
