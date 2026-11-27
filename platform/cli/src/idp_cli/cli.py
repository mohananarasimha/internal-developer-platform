"""Typer CLI entrypoint for validating and rendering service.yaml files."""

from __future__ import annotations

import json
from enum import StrEnum
from pathlib import Path
from typing import Annotated

import typer
from rich.console import Console
from rich.table import Table

from idp_cli.policy import ALL_ENVIRONMENTS, SpecParseError, validate_service_file
from idp_cli.renderer import RenderError, render_environment
from idp_cli.schema import EnvironmentName
from idp_cli.tenancy import render_tenants

app = typer.Typer(
    name="idp",
    help="Internal Developer Platform CLI — validate and render service.yaml specs.",
    no_args_is_help=True,
)
console = Console()
err_console = Console(stderr=True)


class EnvOption(StrEnum):
    STAGING = "staging"
    PROD = "prod"
    ALL = "all"


class FormatOption(StrEnum):
    TABLE = "table"
    JSON = "json"


def _resolve_envs(env_option: EnvOption) -> tuple[EnvironmentName, ...]:
    if env_option == EnvOption.ALL:
        return ALL_ENVIRONMENTS
    if env_option == EnvOption.STAGING:
        return ("staging",)
    return ("prod",)


def _print_violations_table(violations: tuple, service_file: Path) -> None:
    table = Table(title=f"Policy Violations: {service_file}")
    table.add_column("Code", style="bold red", no_wrap=True)
    table.add_column("Env", style="cyan", no_wrap=True)
    table.add_column("Field", style="yellow")
    table.add_column("Message")
    for item in violations:
        table.add_row(item.code, item.environment, item.field, item.message)
    console.print(table)


@app.command("validate")
def validate_cmd(
    service_file: Annotated[
        Path,
        typer.Argument(help="Path to developer-authored service.yaml"),
    ],
    env: Annotated[
        EnvOption,
        typer.Option("--env", help="Target environment(s) to validate"),
    ] = EnvOption.ALL,
    output_format: Annotated[
        FormatOption,
        typer.Option("--format", help="Output format (table or json)"),
    ] = FormatOption.TABLE,
) -> None:
    """Validate service.yaml against schema and platform policy guardrails."""
    target_envs = _resolve_envs(env)
    try:
        result = validate_service_file(service_file, environments=target_envs)
    except SpecParseError as exc:
        if output_format == FormatOption.JSON:
            payload = {"valid": False, "file": str(service_file), "error": str(exc)}
            typer.echo(json.dumps(payload, indent=2))
        else:
            err_console.print(f"[bold red]PARSE ERROR:[/bold red] {exc}")
        raise typer.Exit(code=2) from None

    if output_format == FormatOption.JSON:
        typer.echo(json.dumps(result.to_dict(service_file, target_envs), indent=2))
    elif result.valid:
        envs_label = ", ".join(target_envs)
        console.print(f"[bold green]VALID:[/bold green] {service_file} ({envs_label})")
    else:
        _print_violations_table(result.violations, service_file)

    raise typer.Exit(code=0 if result.valid else 1)


@app.command("render")
def render_cmd(
    service_file: Annotated[
        Path,
        typer.Argument(help="Path to developer-authored service.yaml"),
    ],
    env: Annotated[
        EnvOption,
        typer.Option("--env", help="Target environment(s) to render"),
    ] = EnvOption.ALL,
    out_dir: Annotated[
        Path,
        typer.Option("--out-dir", help="Output directory for rendered manifests"),
    ] = Path("rendered"),
    chart_dir: Annotated[
        Path | None,
        typer.Option("--chart-dir", help="Override path to platform web-service Helm chart"),
    ] = None,
    teams_dir: Annotated[
        Path | None,
        typer.Option("--teams-dir", help="Directory of TeamSpec files (default: repo teams/)"),
    ] = None,
) -> None:
    """Validate and render deterministic Helm values and Kubernetes manifests."""
    target_envs = _resolve_envs(env)
    try:
        result = validate_service_file(service_file, environments=target_envs)
    except SpecParseError as exc:
        err_console.print(f"[bold red]PARSE ERROR:[/bold red] {exc}")
        raise typer.Exit(code=2) from None

    if not result.valid or result.spec is None:
        _print_violations_table(result.violations, service_file)
        raise typer.Exit(code=1)

    for target_env in target_envs:
        try:
            artifacts = render_environment(
                spec=result.spec,
                env=target_env,
                out_dir=out_dir,
                chart_dir=chart_dir,
                teams_dir=teams_dir,
            )
        except RenderError as exc:
            err_console.print(f"[bold red]RENDER ERROR:[/bold red] {exc}")
            raise typer.Exit(code=1) from None

        console.print(
            f"[bold green]RENDERED[/bold green] {artifacts.service_name} "
            f"({artifacts.environment}): {artifacts.manifests_path}"
        )


@app.command("render-tenants")
def render_tenants_cmd(
    teams_dir: Annotated[
        Path,
        typer.Option("--teams-dir", help="Directory of TeamSpec files"),
    ] = Path("teams"),
    out_dir: Annotated[
        Path,
        typer.Option("--out-dir", help="Output directory for tenant namespace bundles"),
    ] = Path("rendered-tenants"),
) -> None:
    """Render each team's per-environment namespace, RBAC, quota, and network policy."""
    try:
        written = render_tenants(teams_dir, out_dir)
    except SpecParseError as exc:
        err_console.print(f"[bold red]PARSE ERROR:[/bold red] {exc}")
        raise typer.Exit(code=2) from None
    for path in written:
        console.print(f"[bold green]RENDERED[/bold green] tenant: {path}")


if __name__ == "__main__":
    app()
