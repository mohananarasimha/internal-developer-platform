# Experiment 02: Failed Rollouts Behind a Service (Readiness vs. Liveness)

> **Namespace change after these results.** The results below were measured before team tenancy, with the service in namespace `prod` and the client in `default`. The script now targets `payments-team-prod` and runs the client in that namespace, because the tenant NetworkPolicy only admits same-namespace and peer-team traffic. It has not been re-run since.

## QUESTION

When a broken revision is rolled out, do the golden-path defaults (`maxUnavailable: 0`, `maxSurge: 1`, readiness on `/healthz`, startup and liveness on `/livez`) keep real Service traffic at 100% success, and what changes if liveness is pointed at the same endpoint as readiness?

## HYPOTHESIS

1. A surge pod that fails readiness is never added to the Service's ready endpoints, so in-cluster clients see no errors. Because liveness checks `/livez`, the pod is not restarted. The rollout stalls and reports `ProgressDeadlineExceeded`.
2. An unpullable image stalls the same way (`ErrImagePull` / `ImagePullBackOff`) with no client errors.
3. If liveness also checks `/healthz`, a readiness failure turns into restart churn, which is the usual probe anti-pattern. Traffic is still protected by readiness, but the kubelet keeps killing the pod.

## SETUP

- kind cluster `idp-local` (Kubernetes `v1.35.0`, 1 control plane + 1 worker) from `platform/kind/bootstrap.sh`. Argo CD is not installed for this experiment, so self-heal does not undo the injected faults.
- `prod` namespace with Pod Security Admission `enforce: restricted`. Workload is `rendered/prod/payments-api/manifests.yaml`: 2 replicas, PDB `minAvailable: 1`, `maxUnavailable: 0`, `maxSurge: 1`.
- `payments-api` app: `/livez` always returns 200 while the process serves. `/healthz` returns 503 when `FAIL_HEALTH=true`.
- **Traffic goes through the Service, from inside the cluster.** A client pod in `default` (same `local/payments-api` image, restricted security context, no external pulls) calls `http://payments-api.prod.svc.cluster.local/` every 200 ms and prints per-second counts of 2xx, non-2xx and connection errors. Earlier versions used `kubectl port-forward svc/...`, which pins to one pod and bypasses endpoint readiness, so they could not test this question.
- During each fault the script samples EndpointSlice ready/not-ready counts and per-pod readiness and restarts every 5–10 s. `progressDeadlineSeconds` is lowered to 25–30 s so the stall is reported within the window.
- Rollback replaces the Deployment with the rendered spec and waits until only the baseline pods remain.

Run it: `./experiments/02-deployment-health/run-experiment.sh`.

## VARIABLE

The injected fault: none (A), `FAIL_HEALTH=true` (B), image `local/payments-api:9.9.9-missing` (C), `FAIL_HEALTH=true` with liveness changed to `/healthz` (D, contrast).

## METRIC

Client success rate through the Service, EndpointSlice ready/not-ready counts, surge-pod restarts, Deployment `Progressing` condition, and time from rollback until only baseline pods remain.

## RESULT

Measured live (second full run after fixing the rollback helper; the first run showed the same traffic and endpoint results):

| Case | EndpointSlice (ready / not ready) | Surge pod | Surge restarts | Client requests OK | Rollout |
|---|---|---|---|---|---|
| A — healthy | 2 / 0 | — | — | smoke `/`, `/livez`, `/healthz`, `/metrics` all 200 | complete |
| B — readiness fails | 2 / 1 for all 8 samples (40 s) | `0/1 Running` | **0** | **225 / 225** | `ProgressDeadlineExceeded`, `rollout status` exit 1 |
| C — bad image | 2 / 1 for all 6 samples (30 s) | `ErrImagePull` → `ImagePullBackOff` | 0 | **175 / 175** | `ProgressDeadlineExceeded`, `rollout status` exit 1 |
| D — liveness on `/healthz` | 2 / 1 for all 9 samples (90 s) | `0/1 Running` | **2** (at ~50 s and ~80 s) | **450 / 450** | stalled |

- Rollback to baseline-only pods took 3 s (B), 1 s (C) and 3 s (final). This is fast because the old ReplicaSet was never scaled down (`maxUnavailable: 0`). Rollback only deletes the surge pod. It is not a measure of recovering from an outage; there was no outage.
- Events: B shows only `Readiness probe failed: ... 503` for the surge pod. D shows `Liveness probe failed: ... 503` followed by restarts.
- The Deployment stayed `Available=True` (`MinimumReplicasAvailable`) in every case.

## INTERPRETATION

- Readiness gating works through the Service: the failing pod was listed as not ready in the EndpointSlice and received no client traffic, so 625 requests across B and C had zero errors.
- Splitting liveness (`/livez`) from readiness (`/healthz`) is what kept the failing pod from restarting in B. In D the only change was the liveness path, and the same fault produced 2 restarts in 90 s. Users were still protected by readiness, but in a real dependency outage a coupled liveness probe restarts every pod that cannot reach the dependency, which turns a partial failure into restart churn and cold starts.
- `maxUnavailable: 0` + `maxSurge: 1` limit a bad revision to one extra pod. The rollout stalls visibly (`ProgressDeadlineExceeded`) instead of replacing healthy pods.

## LESSON

Readiness answers "should this pod get traffic?"; liveness answers "is this process wedged and worth killing?". Point them at different endpoints. Verify rollout safety with traffic that goes through the Service, because `port-forward` bypasses exactly the mechanism under test.
