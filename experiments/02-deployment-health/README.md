# Experiment 02: Healthy vs. Failed Deployment (`maxUnavailable: 0` & Probes)

## QUESTION
When a developer rolls out a broken application revision—either one failing `/healthz` readiness checks or referencing an unpullable container image—do the platform's enforced rolling-update (`maxUnavailable: 0`, `maxSurge: 1`), `PodDisruptionBudget`, and probe defaults preserve 100% availability of healthy `v1` pods while stalling the broken rollout?

## HYPOTHESIS
In the `prod` namespace (`minReplicas: 2`, `maxUnavailable: 0`, `maxSurge: 1`, `PodDisruptionBudget` `minAvailable: 1`, Kubernetes `restricted` Pod Security Admission):
1. A healthy `local/payments-api:1.0.0` deployment will schedule under `restricted` PSS, converge to `2/2` Ready pods, and serve `100%` `200 OK` responses on `/`, `/healthz`, and `/metrics`.
2. Rolling out a revision with `FAIL_HEALTH=true` will create 1 surge pod that fails readiness (`0/1 Ready` with `Unhealthy` probe events), stall the rollout, and keep both `v1` pods serving `100%` `200 OK` traffic.
3. Rolling out a nonexistent image tag (`local/payments-api:9.9.9-missing`) will stall in `ErrImagePull`/`ImagePullBackOff` on the surge pod while keeping both `v1` pods serving `100%` `200 OK` traffic.

## SETUP
- **Cluster**: Local `kind` cluster (`idp-local`, 1 control-plane + 1 worker) provisioned via `./platform/kind/bootstrap.sh`.
- **Namespace**: `prod` with `pod-security.kubernetes.io/enforce: restricted`.
- **Manifests**: `rendered/prod/payments-api/manifests.yaml` (rendered by `idp render services/payments-api/service.yaml --env prod`).
- **Execution script**: `./experiments/02-deployment-health/run-experiment.sh`.

## VARIABLE
Deployment failure mode injected into `Deployment/payments-api` in `prod`:
- **Case A (Baseline)**: Healthy `local/payments-api:1.0.0` (`FAIL_HEALTH` unset).
- **Case B (Readiness Failure)**: `FAIL_HEALTH=true` injected into `Deployment/payments-api` while sending live HTTP requests to `svc/payments-api`.
- **Case C (Image Pull Failure)**: Image updated to `local/payments-api:9.9.9-missing` while sending live HTTP requests to `svc/payments-api`.

## METRIC
- Ready `v1` pod count during rollout failure (target: `2/2` maintained)
- Failing surge pod state and Kubernetes event reason (`Unhealthy`, `ErrImagePull` / `ImagePullBackOff`)
- `PodDisruptionBudget` status (`currentHealthy`, `disruptionsAllowed`)
- Live HTTP request success rate against `svc/payments-api` during each failure window (`200 OK` / total requests)
- Recovery time back to `2/2` Ready after restoring `rendered/prod/payments-api/manifests.yaml`

## RESULT

Measured live on local `kind` (`kindest/node:v1.35.0`, 1 control-plane + 1 worker, `prod` namespace with `pod-security.kubernetes.io/enforce: restricted`) running `./platform/kind/bootstrap.sh` and `./experiments/02-deployment-health/run-experiment.sh`:

| Case | Ready `v1` Pods | Surge Pod State | Observed Events | Traffic Success (`200 OK` / Total) | Rollout Outcome |
| --- | --- | --- | --- | --- | --- |
| Case A — Healthy Baseline (`1.0.0`) | `2/2` (`1/1 Running`) | N/A | Clean startup in `17s` | `20/20` (`100%`) | `successfully rolled out` |
| Case B — Probe Failure (`FAIL_HEALTH=true`) | `2/2` (`1/1 Running`) | `0/1 Running` (`payments-api-6b759fc584-5rkxp`) | `Warning Unhealthy`: `Startup probe failed: HTTP probe failed with statuscode: 503` | `47/47` (`100%`, `0` fail) | Stalled (`rollout status` exit `1`) |
| Case C — Bad Image (`9.9.9-missing`) | `2/2` (`1/1 Running`) | `0/1 ImagePullBackOff` (`payments-api-6d99ff8469-hm45l`) | `ErrImagePull` / `ImagePullBackOff` | `47/47` (`100%`, `0` fail) | Stalled (`rollout status` exit `1`) |
| Recovery — Restore `1.0.0` | `2/2` (`1/1 Running`) | Broken surge pod `Terminating` | Immediate convergence | `100%` uninterrupted | Recovered in `0s` |

- **Pod Security Admission (`restricted`) verification**: Passed admission with zero warnings on `prod` (`pod-security.kubernetes.io/enforce: restricted`).
- **`PodDisruptionBudget` observed status**: `payments-api` — `MIN AVAILABLE: 1`, `ALLOWED DISRUPTIONS: 1` (`2/2` healthy).
- **`/metrics` scrape verification**: Returned `payments_api_up 1`, `payments_api_requests_total{path="/",status="200"} 20`, and `payments_api_requests_total{path="/healthz",status="200"} 4`.

## INTERPRETATION
Both injected failure classes—application-level health regressions (`FAIL_HEALTH=true` -> HTTP `503`) and artifact/registry mistakes (`local/payments-api:9.9.9-missing` -> `ImagePullBackOff`)—were completely isolated to the single surge pod (`maxSurge: 1`). Because the platform enforces `maxUnavailable: 0` alongside startup and readiness probes, Kubernetes refused to terminate either healthy `v1` pod or add the failing surge pod to Service endpoints, preserving `47/47` (`100%`) `200 OK` responses during both failure windows. Reverting to `1.0.0` converged in `0s` because the healthy `v1` ReplicaSet was never scaled down.

## ENGINEERING LESSON
Platform defaults turn deployment failures from user-facing outages into contained, observable rollout stalls. Relying on developers to manually author `maxUnavailable: 0`, startup/readiness probes, `PodDisruptionBudget`, and `restricted` Pod Security Admission `securityContext` leads to inconsistent drift across services; encoding them centrally in the golden-path chart ensures every service inherits zero-downtime failure containment by default.
