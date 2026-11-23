# CLAUDE.md — Internal Developer Platform Charter

## Repository Charter

`internal-developer-platform` is a clean-room, declarative Kubernetes golden path that converts a small developer-authored `service.yaml` into policy-checked, hardened Helm/Kubernetes manifests synced via GitOps (Argo CD) onto a local `kind` cluster.

### Explicit Non-Goals
- No Backstage clone or web portal frontend
- No custom Kubernetes operator or CRDs
- No service mesh

## Architecture

```
services/<svc>/service.yaml
  -> platform/cli (`idp validate` + `idp render`)
  -> platform/charts/web-service (Helm template)
  -> rendered/<env>/<svc>/{values.yaml,manifests.yaml}
  -> GitHub Actions CI gate (ruff, pytest, helm lint, validate, drift check)
  -> Argo CD GitOps sync onto local kind cluster (staging / prod)
```

## Schema & Policy Contract

- `metadata.name`: DNS-1123 lowercase label; `metadata.owner`: non-empty team slug; `metadata.tier`: `critical | standard`.
- `runtime.tag`: immutable semver or `sha256:` digest; `latest`, empty, and whitespace tags are rejected.
- `runtime.port`: `1024–65535` (non-privileged port required for non-root containers).
- `sizing.profile`: `small | medium | large`, mapped deterministically to CPU/memory requests and limits.
- `sizing.targetCPU`: `50–90`; `maxReplicas >= minReplicas`.
- `env`: flat non-secret strings only; secret-like keys (`PASSWORD`, `SECRET`, `TOKEN`, `API_KEY`, `PRIVATE_KEY`, `AWS_SECRET`, etc.) are blocked.
- `secretRefs`: Kubernetes `Secret` names only (never secret values).
- `prod` environment enforces `minReplicas >= 2` (and triggers automatic `PodDisruptionBudget` generation).

## Verification Gates

Run from the repository root before considering any change complete:
- `uv sync --directory platform/cli --extra dev`
- `uv run --directory platform/cli ruff check .`
- `uv run --directory platform/cli pytest -v`
- `helm lint platform/charts/web-service`
- `uv run --project platform/cli idp validate services/payments-api/service.yaml --env all`
- `uv run --project platform/cli idp render services/payments-api/service.yaml --env all --out-dir rendered && git diff --exit-code rendered/`

## Clean-Room & Security Rules

- Clean-room personal engineering code only; zero employer or company references.
- Never commit secrets, `.env`, `.pem`, `.key`, or kubeconfig files.
- Never use `shell=True` in subprocess invocations; keep `ruff` security rules (`S`) enabled and passing.
- Do not bypass or weaken pod `securityContext` defaults in `platform/charts/web-service`.
