"""Team tenancy: TeamSpec schema and the per-environment namespace bundle the platform owns.

Each team gets one namespace per environment, named ``<team>-<env>``, containing:
restricted Pod Security labels, a RoleBinding of the built-in ``edit`` ClusterRole to the
team's group, a ResourceQuota, a LimitRange, and ingress NetworkPolicies that deny traffic
from other namespaces unless the team lists the caller in ``allowIngressFrom``.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any, Literal

import yaml
from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator

from idp_cli.policy import ALL_ENVIRONMENTS, SpecParseError, load_raw_yaml
from idp_cli.schema import TEAM_SLUG_RE, EnvironmentName

QUANTITY_RE = re.compile(r"^[0-9]+(\.[0-9]+)?(m|Ki|Mi|Gi|Ti)?$")
MAX_NAMESPACE_LEN = 63
PSA_LABELS: dict[str, str] = {
    f"pod-security.kubernetes.io/{mode}{suffix}": value
    for mode in ("enforce", "warn", "audit")
    for suffix, value in (("", "restricted"), ("-version", "latest"))
}
LIMIT_RANGE_DEFAULTS: dict[str, dict[str, str]] = {
    "defaultRequest": {"cpu": "100m", "memory": "128Mi"},
    "default": {"cpu": "250m", "memory": "256Mi"},
}


_MEMORY_UNITS = {"": 1, "Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "Ti": 2**40}


def cpu_millicores(quantity: str) -> int:
    if quantity.endswith("m"):
        return int(float(quantity[:-1]))
    return int(float(quantity) * 1000)


def memory_bytes(quantity: str) -> int:
    for unit in ("Ki", "Mi", "Gi", "Ti"):
        if quantity.endswith(unit):
            return int(float(quantity[: -len(unit)]) * _MEMORY_UNITS[unit])
    return int(float(quantity))


def quota_shortfalls(
    quota: TeamQuota, pods: int, resources: dict[str, dict[str, str]]
) -> list[str]:
    """Quota dimensions that ``pods`` copies of a pod with ``resources`` would exceed."""
    checks = (
        ("requests.cpu", cpu_millicores, resources["requests"]["cpu"], quota.requestsCpu),
        ("requests.memory", memory_bytes, resources["requests"]["memory"], quota.requestsMemory),
        ("limits.cpu", cpu_millicores, resources["limits"]["cpu"], quota.limitsCpu),
        ("limits.memory", memory_bytes, resources["limits"]["memory"], quota.limitsMemory),
    )
    out = [
        f"{dim} {pods} x {per_pod} > {hard}"
        for dim, parse, per_pod, hard in checks
        if pods * parse(per_pod) > parse(hard)
    ]
    if pods > quota.pods:
        out.append(f"pods {pods} > {quota.pods}")
    return out


def tenant_namespace(team: str, env: EnvironmentName) -> str:
    """Namespace that holds ``team``'s workloads in ``env``."""
    return f"{team}-{env}"


class TeamQuota(BaseModel):
    model_config = ConfigDict(extra="forbid")

    requestsCpu: str
    requestsMemory: str
    limitsCpu: str
    limitsMemory: str
    pods: int = Field(..., ge=1, le=500)

    @field_validator("requestsCpu", "requestsMemory", "limitsCpu", "limitsMemory")
    @classmethod
    def validate_quantity(cls, value: str) -> str:
        if not QUANTITY_RE.match(value):
            raise ValueError(f"'{value}' is not a Kubernetes quantity like 500m, 2, 1Gi")
        return value


class TeamMetadata(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str

    @field_validator("name")
    @classmethod
    def validate_name(cls, value: str) -> str:
        longest = max(len(tenant_namespace(value, env)) for env in ALL_ENVIRONMENTS)
        if not TEAM_SLUG_RE.match(value) or longest > MAX_NAMESPACE_LEN:
            raise ValueError(
                f"team name '{value}' must be a lowercase slug and leave room for the "
                f"environment suffix within {MAX_NAMESPACE_LEN} characters"
            )
        return value


class TeamBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    group: str = Field(..., min_length=1)
    allowIngressFrom: list[str] = Field(default_factory=list)
    quota: dict[EnvironmentName, TeamQuota]

    @field_validator("allowIngressFrom")
    @classmethod
    def validate_peers(cls, value: list[str]) -> list[str]:
        for peer in value:
            if not TEAM_SLUG_RE.match(peer):
                raise ValueError(f"allowIngressFrom entry '{peer}' is not a team slug")
        return sorted(set(value))

    @field_validator("quota")
    @classmethod
    def validate_all_envs(cls, value: dict[EnvironmentName, TeamQuota]) -> dict[str, TeamQuota]:
        missing = [env for env in ALL_ENVIRONMENTS if env not in value]
        if missing:
            raise ValueError(f"quota is required for every environment; missing {missing}")
        return value


class TeamSpec(BaseModel):
    model_config = ConfigDict(extra="forbid")

    apiVersion: Literal["idp.local/v1"] = "idp.local/v1"
    kind: Literal["TeamSpec"] = "TeamSpec"
    metadata: TeamMetadata
    spec: TeamBody


def load_team_file(path: Path) -> TeamSpec:
    raw = load_raw_yaml(path)
    try:
        team = TeamSpec.model_validate(raw)
    except ValidationError as exc:
        details = "; ".join(
            f"{'.'.join(str(p) for p in e['loc']) or '<root>'}: {e['msg']}" for e in exc.errors()
        )
        raise SpecParseError(f"Invalid TeamSpec {path}: {details}") from None
    if path.stem != team.metadata.name:
        raise SpecParseError(
            f"TeamSpec file {path.name} must be named after metadata.name "
            f"('{team.metadata.name}.yaml')"
        )
    return team


def load_teams(teams_dir: Path) -> dict[str, TeamSpec]:
    """Load every ``<team>.yaml`` and check that ``allowIngressFrom`` names known teams."""
    if not teams_dir.is_dir():
        raise SpecParseError(f"Teams directory not found: {teams_dir}")
    teams = {t.metadata.name: t for t in map(load_team_file, sorted(teams_dir.glob("*.yaml")))}
    for team in teams.values():
        unknown = [p for p in team.spec.allowIngressFrom if p not in teams]
        if unknown:
            raise SpecParseError(
                f"Team '{team.metadata.name}' allows ingress from unknown team(s): {unknown}"
            )
    return teams


def build_tenant_manifests(team: TeamSpec, env: EnvironmentName) -> list[dict[str, Any]]:
    """Kubernetes objects for one team in one environment, in apply order."""
    name = team.metadata.name
    ns = tenant_namespace(name, env)
    labels = {
        "app.kubernetes.io/managed-by": "idp-platform",
        "idp.local/team": name,
        "idp.local/environment": env,
    }
    quota = team.spec.quota[env]

    def meta(obj_name: str) -> dict[str, Any]:
        return {"name": obj_name, "namespace": ns, "labels": dict(labels)}

    docs: list[dict[str, Any]] = [
        {
            "apiVersion": "v1",
            "kind": "Namespace",
            "metadata": {"name": ns, "labels": {**labels, **PSA_LABELS}},
        },
        {
            "apiVersion": "rbac.authorization.k8s.io/v1",
            "kind": "RoleBinding",
            "metadata": meta("team-edit"),
            "roleRef": {
                "apiGroup": "rbac.authorization.k8s.io",
                "kind": "ClusterRole",
                "name": "edit",
            },
            "subjects": [
                {
                    "apiGroup": "rbac.authorization.k8s.io",
                    "kind": "Group",
                    "name": team.spec.group,
                }
            ],
        },
        {
            "apiVersion": "v1",
            "kind": "ResourceQuota",
            "metadata": meta("team-quota"),
            "spec": {
                "hard": {
                    "requests.cpu": quota.requestsCpu,
                    "requests.memory": quota.requestsMemory,
                    "limits.cpu": quota.limitsCpu,
                    "limits.memory": quota.limitsMemory,
                    "pods": str(quota.pods),
                    "services.loadbalancers": "0",
                    "services.nodeports": "0",
                }
            },
        },
        {
            "apiVersion": "v1",
            "kind": "LimitRange",
            "metadata": meta("team-defaults"),
            "spec": {"limits": [{"type": "Container", **LIMIT_RANGE_DEFAULTS}]},
        },
        {
            "apiVersion": "networking.k8s.io/v1",
            "kind": "NetworkPolicy",
            "metadata": meta("default-deny-ingress"),
            "spec": {"podSelector": {}, "policyTypes": ["Ingress"]},
        },
        {
            "apiVersion": "networking.k8s.io/v1",
            "kind": "NetworkPolicy",
            "metadata": meta("allow-same-namespace"),
            "spec": {
                "podSelector": {},
                "policyTypes": ["Ingress"],
                "ingress": [{"from": [{"podSelector": {}}]}],
            },
        },
    ]
    if team.spec.allowIngressFrom:
        docs.append(
            {
                "apiVersion": "networking.k8s.io/v1",
                "kind": "NetworkPolicy",
                "metadata": meta("allow-from-peer-teams"),
                "spec": {
                    "podSelector": {},
                    "policyTypes": ["Ingress"],
                    "ingress": [
                        {
                            "from": [
                                {
                                    "namespaceSelector": {
                                        "matchExpressions": [
                                            {
                                                "key": "idp.local/team",
                                                "operator": "In",
                                                "values": list(team.spec.allowIngressFrom),
                                            },
                                            {
                                                "key": "idp.local/environment",
                                                "operator": "In",
                                                "values": [env],
                                            },
                                        ]
                                    }
                                }
                            ]
                        }
                    ],
                },
            }
        )
    return docs


def render_tenants(teams_dir: Path, out_dir: Path) -> list[Path]:
    """Write ``<out_dir>/<team>/<env>/tenant.yaml`` for every team and environment."""
    written = []
    for name, team in load_teams(teams_dir).items():
        for env in ALL_ENVIRONMENTS:
            target = out_dir / name / env / "tenant.yaml"
            target.parent.mkdir(parents=True, exist_ok=True)
            docs = build_tenant_manifests(team, env)
            target.write_text(
                yaml.safe_dump_all(docs, sort_keys=False, default_flow_style=False),
                encoding="utf-8",
            )
            written.append(target)
    return written
