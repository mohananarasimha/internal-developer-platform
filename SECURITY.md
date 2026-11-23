# Security Policy

## Secrets Boundary

Secret values **never** enter Git in this repository:

- Developers declare only Kubernetes `Secret` object names under `secretRefs` in `service.yaml`.
- The `idp` policy engine explicitly blocks secret-like environment variable keys (such as `*_PASSWORD`, `*_SECRET`, `*_TOKEN`, `*_API_KEY`, `*_PRIVATE_KEY`, `AWS_SECRET*`) inside `env` and environment overrides.
- Secret material is provisioned out-of-band in the target cluster (for example via External Secrets Operator, Sealed Secrets, or cloud KMS integrations in production, and out-of-band `kubectl create secret` in local `kind` environments).
- `.env`, `.env.*`, `*.pem`, `*.key`, and `kubeconfig*` files are excluded via `.gitignore` and must never be committed.

## Hardened Workload Defaults

Every service rendered by `platform/charts/web-service` inherits non-overridable container and pod security defaults:

- `runAsNonRoot: true` with explicit non-root UID/GID (`10001`)
- `readOnlyRootFilesystem: true` (with a writable `emptyDir` mounted at `/tmp`)
- `allowPrivilegeEscalation: false`
- `capabilities.drop: ["ALL"]`
- `seccompProfile.type: RuntimeDefault`
- `automountServiceAccountToken: false`
- Non-privileged container ports enforced at validation time (`1024–65535`)
- Immutable image tags enforced at validation time (`latest` blocked; semver or `sha256:` digest required)

## Reporting a Vulnerability

If you discover a security issue in the CLI, policy engine, Helm chart, or CI workflows:

1. Do **not** open a public GitHub issue with exploit details.
2. Report it privately using GitHub Security Advisories for `mohananarasimha/internal-developer-platform`, or contact the repository maintainer directly via their GitHub profile.
3. Include reproduction steps, affected file paths, and expected vs. observed behavior.

Reports are triaged within 5 business days. Confirmed issues are patched on `main` with a regression test covering the failure mode.
