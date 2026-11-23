# AGENTS.md — Operating Instructions for AI Agents

## Scope & Boundaries

This repository implements a declarative Kubernetes golden path (`service.yaml` -> Python CLI validator/renderer -> standardized Helm chart -> rendered manifests -> GitOps).

- Keep changes minimal, deterministic, and auditable in Git diffs.
- Do not introduce a web frontend, Backstage portal, Kubernetes operator, or service mesh.
- Keep all code clean-room and personal; never include employer/company names or proprietary material.

## Directory Map

- `platform/cli/`: Python 3.11+ `idp` CLI (`schema.py`, `policy.py`, `renderer.py`, `cli.py`) and pytest suite.
- `platform/charts/web-service/`: Standardized Helm chart enforcing hardened `securityContext`, probes, PDB, HPA, and Prometheus scrape annotations.
- `services/<name>/service.yaml`: Developer-owned service intent declarations.
- `rendered/<env>/<name>/`: Deterministic rendered Helm values and Kubernetes manifests checked into Git and drift-verified in CI.
- `experiments/`: Controlled platform experiments with reproducible fixtures and recorded observations.

## Schema & Policy Invariants

1. `idp validate` exits `0` on valid specs, `1` on schema/policy violations, and `2` on missing files or YAML parse errors.
2. `idp render` must produce byte-identical output across repeated runs (`git diff --exit-code rendered/`).
3. Secret values must never appear in `service.yaml`, `values.yaml`, or `rendered/`. Only `secretRefs` names are permitted.
4. Security defaults (`runAsNonRoot: true`, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault`) must remain non-overridable.

## Required Checks Before Finishing Changes

```bash
make check
```

Which runs:
1. `ruff check .` (including `S` security rules)
2. `pytest -v`
3. `helm lint platform/charts/web-service`
4. `idp validate services/payments-api/service.yaml --env all`
5. `idp render` + `git diff --exit-code rendered/`
