# Experiment 01: Config Validation & Policy Guardrails

## QUESTION
Can shift-left schema and policy validation in `idp validate` deterministically block unsafe service declarations (mutable image tags, inline secrets, single-replica production configs, and privileged ports) before manifest rendering or cluster deployment?

## HYPOTHESIS
Enforcing typed schema validation (`pydantic` v2) combined with environment-aware policy checks (`policy.py`) will accept a compliant multi-environment `service.yaml` with exit code `0`, reject all four unsafe fixture patterns with exit code `1` and machine-readable violation codes, and isolate YAML/file parse errors with exit code `2`.

## SETUP
- **Baseline valid spec**: `services/payments-api/service.yaml` (`staging` + `prod` overrides, immutable semver tag `1.0.0`, port `8080`, `secretRefs` only, `prod` `minReplicas: 2`).
- **Invalid fixtures** (located in `experiments/01-config-validation/`):
  1. `invalid-latest-tag.yaml` — sets `runtime.tag: latest`
  2. `invalid-secret-in-env.yaml` — embeds `DB_PASSWORD` and `STRIPE_API_KEY` under `env`
  3. `invalid-prod-single-replica.yaml` — sets `environments.prod.sizing.minReplicas: 1`
  4. `invalid-privileged-port.yaml` — sets `runtime.port: 80` (incompatible with non-root containers)
- **Command**: `uv run --project platform/cli idp validate <file> --env all --format json`

## VARIABLE
Single targeted guardrail violation introduced per fixture while holding the remaining `service.yaml` structure valid.

## METRIC
- CLI exit code (`0` = valid, `1` = schema/policy rejection, `2` = I/O or YAML parse failure)
- Exact structured violation code(s) emitted in JSON/table output
- Render refusal (`idp render` exits `1` and writes zero manifests on violation)

## RESULT

| Fixture | Exit Code | Violation Code(s) | Outcome |
| --- | --- | --- | --- |
| `services/payments-api/service.yaml` | `0` | None | Accepted (`staging` + `prod`) |
| `invalid-latest-tag.yaml` | `1` | `IDP_TAG_LATEST` | Blocked before render |
| `invalid-secret-in-env.yaml` | `1` | `IDP_ENV_SECRET_FORBIDDEN` | Blocked before render |
| `invalid-prod-single-replica.yaml` | `1` | `IDP_PROD_MIN_REPLICAS` | Blocked before render |
| `invalid-privileged-port.yaml` | `1` | `IDP_PORT_PRIVILEGED` | Blocked before render |
| Missing or malformed YAML | `2` | Parse error (`SpecParseError`) | Isolated from policy failures |

## INTERPRETATION
Every misconfiguration failed fast at authoring/CI time in milliseconds without touching a Kubernetes cluster. Separating exit code `1` (policy/schema rejection) from exit code `2` (file/syntax error) lets CI workflows distinguish developer guardrail feedback from tooling or path errors. Because `idp render` invokes the same validation pipeline before executing `helm template`, invalid specs cannot produce partial or drifted artifacts in `rendered/`.

## ENGINEERING LESSON
Encoding platform invariants at the declarative input boundary (`service.yaml`) catches deployment-breaking errors (like binding port `80` inside a `runAsNonRoot: true` container, or leaking credentials into Git) far earlier and with clearer diagnostics than waiting for Kubernetes admission webhooks or `CrashLoopBackOff` at runtime.
