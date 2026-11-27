"""Deterministic Helm values and Kubernetes manifest renderer."""

from __future__ import annotations

import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

from idp_cli.policy import SpecParseError, evaluate_resolved_policies, get_resources_for_profile
from idp_cli.schema import EnvironmentName, ResolvedServiceConfig, ServiceSpec
from idp_cli.tenancy import load_teams, quota_shortfalls, tenant_namespace

ROLLING_UPDATE_MAX_SURGE = 1


class RenderError(Exception):
    """Raised when manifest rendering fails."""


@dataclass(frozen=True)
class RenderedArtifacts:
    """Paths written for a single rendered service environment."""

    environment: EnvironmentName
    service_name: str
    values_path: Path
    manifests_path: Path


REPO_ROOT = Path(__file__).resolve().parents[4]


def default_chart_dir() -> Path:
    """Resolve platform/charts/web-service relative to the repository root."""
    return REPO_ROOT / "platform" / "charts" / "web-service"


def default_teams_dir() -> Path:
    return REPO_ROOT / "teams"


def build_helm_values(resolved: ResolvedServiceConfig) -> dict[str, Any]:
    """Construct deterministic Helm values from a resolved environment config."""
    return {
        "environment": resolved.environment,
        "namespace": tenant_namespace(resolved.metadata.owner, resolved.environment),
        "metadata": {
            "name": resolved.metadata.name,
            "owner": resolved.metadata.owner,
            "tier": resolved.metadata.tier,
        },
        "runtime": {
            "image": resolved.runtime.image,
            "tag": resolved.runtime.tag,
            "port": resolved.runtime.port,
            "healthPath": resolved.runtime.healthPath,
            "livenessPath": resolved.runtime.livenessPath,
            "metricsPath": resolved.runtime.metricsPath,
        },
        "sizing": {
            "profile": resolved.sizing.profile,
            "minReplicas": resolved.sizing.minReplicas,
            "maxReplicas": resolved.sizing.maxReplicas,
            "targetCPU": resolved.sizing.targetCPU,
        },
        "resources": get_resources_for_profile(resolved.sizing.profile),
        "env": dict(sorted(resolved.env.items())),
        "secretRefs": list(resolved.secretRefs),
    }


def render_environment(
    spec: ServiceSpec,
    env: EnvironmentName,
    out_dir: Path,
    chart_dir: Path | None = None,
    teams_dir: Path | None = None,
) -> RenderedArtifacts:
    """Render values.yaml and Helm-templated manifests.yaml for one environment."""
    resolved = spec.resolve_environment(env)
    violations = evaluate_resolved_policies(resolved)
    if violations:
        codes = ", ".join(v.code for v in violations)
        raise RenderError(f"Refusing to render invalid {env} config ({codes})")

    try:
        teams = load_teams(teams_dir or default_teams_dir())
    except SpecParseError as exc:
        raise RenderError(str(exc)) from None
    if resolved.metadata.owner not in teams:
        raise RenderError(
            f"IDP_OWNER_UNKNOWN: metadata.owner '{resolved.metadata.owner}' has no TeamSpec in "
            f"{teams_dir or default_teams_dir()}; a service can only deploy into its owner's "
            "tenant namespace"
        )
    worst_case_pods = resolved.sizing.maxReplicas + ROLLING_UPDATE_MAX_SURGE
    shortfalls = quota_shortfalls(
        teams[resolved.metadata.owner].spec.quota[env],
        worst_case_pods,
        get_resources_for_profile(resolved.sizing.profile),
    )
    if shortfalls:
        raise RenderError(
            f"IDP_QUOTA_EXCEEDED: {env} maxReplicas + rolling-update surge "
            f"({worst_case_pods} pods) does not fit team '{resolved.metadata.owner}' quota: "
            + "; ".join(shortfalls)
        )

    resolved_chart = (chart_dir or default_chart_dir()).resolve()
    if not (resolved_chart / "Chart.yaml").is_file():
        raise RenderError(f"Helm chart not found at {resolved_chart}")

    helm_bin = shutil.which("helm")
    if helm_bin is None:
        raise RenderError("helm executable not found on PATH")

    target_dir = out_dir / env / resolved.metadata.name
    target_dir.mkdir(parents=True, exist_ok=True)

    values_path = target_dir / "values.yaml"
    manifests_path = target_dir / "manifests.yaml"

    values_dict = build_helm_values(resolved)
    values_yaml = yaml.safe_dump(values_dict, sort_keys=False, default_flow_style=False)
    values_path.write_text(values_yaml, encoding="utf-8")

    cmd = [
        helm_bin,
        "template",
        resolved.metadata.name,
        str(resolved_chart),
        "--namespace",
        values_dict["namespace"],
        "--values",
        str(values_path),
    ]
    proc = subprocess.run(  # noqa: S603
        cmd,
        shell=False,
        check=False,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        stderr = proc.stderr.strip() or proc.stdout.strip()
        raise RenderError(f"helm template failed for {env}: {stderr}")

    rendered_manifests = proc.stdout.strip() + "\n"
    manifests_path.write_text(rendered_manifests, encoding="utf-8")

    return RenderedArtifacts(
        environment=env,
        service_name=resolved.metadata.name,
        values_path=values_path,
        manifests_path=manifests_path,
    )
