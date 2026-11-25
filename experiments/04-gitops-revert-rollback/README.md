# Experiment 04: Imperative Rollback vs. GitOps `git revert` Under Argo CD `selfHeal`

## QUESTION

When a broken manifest lands in Git and Argo CD deploys it with automated `selfHeal: true`, what happens if an operator runs an imperative `kubectl rollout undo`, and how long does a GitOps `git revert` take to restore `Synced / Healthy` under default polling versus an immediate refresh?

## HYPOTHESIS

- Running `kubectl rollout undo` against a Deployment managed by Argo CD with `selfHeal: true` will revert the pod template only briefly; Argo CD will detect drift (`OutOfSync`) and re-apply the broken commit from Git within seconds.
- Pushing a `git revert` commit to the tracked branch will converge permanently to `Synced / Healthy`. Recovery latency will be dominated by Git discovery: up to ~180 s under Argo CD's default 3-minute reconciliation polling interval (`timeout.reconciliation`), versus a few seconds when triggered immediately via webhook or `argocd.argoproj.io/refresh=hard`.
- Because `payments-api` deploys with `maxUnavailable: 0`, `maxSurge: 1`, and a `PodDisruptionBudget`, a bad image tag (`ImagePullBackOff` on the surge pod) should cause zero client-visible request failures throughout both rollback paths.

## SETUP

- **Cluster & Argo CD:** local `kind` cluster `idp-local` (Kubernetes v1.35.0) bootstrapped with pinned Argo CD `v2.14.2` (`./platform/kind/bootstrap.sh --with-argocd`).
  - Live verification of the main `idp-services` `ApplicationSet` against `https://github.com/mohananarasimha/internal-developer-platform.git` revealed that Argo CD 2.x defaults to label-based resource tracking, rewriting `app.kubernetes.io/instance` on managed objects to the Application name and colliding with the chart's own `app.kubernetes.io/instance` label. Applying [`gitops/argocd/argocd-cm.yaml`](../../gitops/argocd/argocd-cm.yaml) (`application.resourceTrackingMethod: annotation`) resolved the collision; both `prod-payments-api` and `staging-payments-api` reconciled to `Synced / Healthy` at commit `8b333a9`.
  - `RespectIgnoreDifferences=true` + `ignoreDifferences: [/spec/replicas]` was verified live: scaling `payments-api` to 3 replicas and triggering a hard refresh left Argo CD `Synced` with no sync operation (`op_started` unchanged), while Kubernetes HPA scaled the Deployment back to 2 (`SuccessfulRescale: All metrics below target`).
- **Isolated sandbox:** to avoid landing broken commits on protected `main` or fighting `prod-payments-api` over objects in `prod`, the experiment ran against a temporary remote branch `exp04-sandbox` (deleted after the runs) and an experiment-only [`sandbox-application.yaml`](sandbox-application.yaml) deploying `rendered/prod/payments-api/manifests.yaml` retargeted to namespace `exp04-sandbox` (restricted PSS, `prune: true`, `selfHeal: true`, `RespectIgnoreDifferences=true`).
- **Bad release:** changing the rendered Deployment image from `local/payments-api:1.0.0` to `local/payments-api:9.9.9-missing` (triggers `ImagePullBackOff` on the surge pod while the 2 healthy `1.0.0` pods keep serving). After pushing each bad commit, an explicit `argocd.argoproj.io/refresh=hard` landed the broken revision promptly so the rollback comparison started from a known `Synced / Progressing` state.
- **Availability client:** [`load_client.py`](../03-fixed-replicas-vs-hpa/load_client.py) running inside the cluster (`default/exp04-availability-client`, local image, restricted securityContext) sending 10 req/s open-loop to `http://payments-api.exp04-sandbox.svc.cluster.local/` (2 s timeout) for the full trial.
- **Observer:** [`run-experiment.sh`](run-experiment.sh) sampled the Argo CD `Application` status and `exp04-sandbox/payments-api` Deployment once per second to `results/trial<N>-timeline.csv`.

```bash
# Setup (after creating a temporary exp04-sandbox branch whose rendered prod manifests target namespace exp04-sandbox)
./experiments/04-gitops-revert-rollback/run-experiment.sh setup-cluster
./experiments/04-gitops-revert-rollback/run-experiment.sh observe-start 1
# ... push bad commit, run `kubectl -n exp04-sandbox rollout undo deployment/payments-api`, push revert commit ...
./experiments/04-gitops-revert-rollback/run-experiment.sh observe-stop 1
./experiments/04-gitops-revert-rollback/run-experiment.sh teardown-cluster
```

## VARIABLE

Rollback mechanism (and, for GitOps revert, Git discovery mode):

1. **Imperative rollback:** `kubectl -n exp04-sandbox rollout undo deployment/payments-api` while `selfHeal: true` is active (tested in both Trial 1 and Trial 2).
2. **GitOps `git revert` — default polling (Trial 1):** push a revert commit restoring `local/payments-api:1.0.0` with no manual refresh or webhook; wait for Argo CD's default 180 s reconciliation loop.
3. **GitOps `git revert` — immediate refresh (Trial 2):** push a revert commit restoring `local/payments-api:1.0.0` and immediately annotate `argocd.argoproj.io/refresh=hard` (equivalent to a Git push webhook or `argocd app get --hard-refresh`).

Application spec, `selfHeal` policy, bad image change, and availability client (10 req/s) were identical across both trials.

## METRIC

- Time from `kubectl rollout undo` until Argo CD `selfHeal` re-applied `local/payments-api:9.9.9-missing` (and Argo CD sync event confirmation).
- Time from `git revert` push to `Synced / Healthy` on the revert commit SHA.
- In-cluster availability client results across the entire trial: requests sent, OK count, error rate, and p50/p95/p99 latency.

## RESULT

Raw timelines, event logs, and client logs are stored in [`results/`](results/):
- Trial 1: [`trial1-events.txt`](results/trial1-events.txt), [`trial1-timeline.csv`](results/trial1-timeline.csv), [`trial1-client.log`](results/trial1-client.log)
- Trial 2: [`trial2-events.txt`](results/trial2-events.txt), [`trial2-timeline.csv`](results/trial2-timeline.csv), [`trial2-client.log`](results/trial2-client.log)

### Summary table

| Trial | Bad commit SHA | `kubectl rollout undo` outcome (`selfHeal: true`) | Revert commit SHA | Revert discovery mode | Push -> `Synced / Healthy` | In-cluster client (10 req/s) | Latency (p50 / p95 / p99) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Trial 1 | `8cfa656` | Re-applied `9.9.9-missing` in **1 s** | `f1fda79` | Default 3-min polling (no refresh) | **173 s** | **2200 / 2200 OK** (0.0% err) | 4.1 / 8.0 / 10.1 ms |
| Trial 2 | `d2e886e` | Re-applied `9.9.9-missing` in **1 s** | `6ab6c21` | Immediate `refresh=hard` (webhook-equiv.) | **5 s** | **500 / 500 OK** (0.0% err) | 4.9 / 8.9 / 11.1 ms |

*(Commits `8cfa656`, `f1fda79`, `d2e886e`, and `6ab6c21` were on the temporary `exp04-sandbox` branch, which was deleted after teardown so `main` stayed clean.)*

### Observed state transitions (from 1 s CSV timelines)

**Trial 1 (`trial1-timeline.csv`):**
- `t=0 s` (`09:20:02Z`): baseline `Synced / Healthy` at `a581b2b` (`1.0.0`, `2/2` ready).
- `t+10 s`: pushed bad commit `8cfa656` + `refresh=hard`; `t+14 s` (`09:20:16Z`): `Synced / Progressing`, image `9.9.9-missing`, `ready=2, updated=1, unavailable=1` (surge pod in `ImagePullBackOff`).
- `t+22 s` (`09:20:24Z`): ran `kubectl rollout undo`. The 1 s sampler caught the transient `OutOfSync / Healthy` state with image `1.0.0` (`op_phase=Running`, `Partial sync operation to 8cfa656`).
- `t+23 s` (`09:20:25Z`, **+1 s**): `Synced / Progressing`, image back to `9.9.9-missing`, `unavailable=1`.
- `t+35 s` (`09:20:37Z`): pushed revert commit `f1fda79` (no refresh).
- `t+208 s` (`09:23:30Z`, **+173 s**): Argo CD's scheduled poll synced `f1fda79` (`1.0.0`); `Synced / Healthy` confirmed at `t+208–209 s` (`2/2` ready, `0` unavailable).

**Trial 2 (`trial2-timeline.csv`):**
- `t+10 s`: pushed bad commit `d2e886e` + `refresh=hard`; `t+14 s`: `Synced / Progressing` (`9.9.9-missing`).
- `t+22 s` (`09:25:33Z`): ran `kubectl rollout undo`; Argo CD fired `Partial sync operation to d2e886e` within the same second (`op_started=09:25:33Z`), restoring `9.9.9-missing` by `t+23 s` (**+1 s**).
- `t+35 s` (`09:25:46Z`): pushed revert commit `6ab6c21` + immediate `argocd.argoproj.io/refresh=hard`.
- `t+39–40 s` (`09:25:49–09:25:51Z`, **+5 s**): Argo CD synced `6ab6c21` and reached `Synced / Healthy` (`2/2` ready).

## INTERPRETATION

- **Imperative cluster fixes fight `selfHeal`:** Kubernetes informer watches let Argo CD detect `kubectl rollout undo` almost immediately (~1 s in both trials) and re-apply the broken Git revision. Even if an operator temporarily pauses auto-sync to run `kubectl rollout undo`, the cluster is left drifted from Git until Git itself is reverted.
- **Polling interval dominates GitOps MTTR:** The 168 s gap between Trial 1 (173 s) and Trial 2 (5 s) is purely Git detection latency. In Trial 1, the previous refresh happened at `09:20:15Z`, and Argo CD's default 180 s reconciliation timer fired at `09:23:30Z`. Once Argo CD saw the revert commit, sync-to-healthy took only ~1–2 s because the healthy `1.0.0` ReplicaSet was still running at 2 replicas.
- **Zero-error availability is due to rollout strategy, not Argo CD:** Both trials served 100% of requests (2700 / 2700 combined) with ~4–5 ms p50 because `maxUnavailable: 0` kept the 2 healthy `1.0.0` pods in the Service endpoints while the broken `9.9.9-missing` surge pod stayed unready. A bad release that passes readiness probes (for example a logic regression returning 500s on `/`) would impact traffic during the entire 173 s polling window unless webhooks or manual refresh are used.

## LESSON

- **Revert in Git, never with `kubectl rollout undo`, when `selfHeal: true` is enabled:** Cluster-side rollbacks are undone in ~1 s and create audit drift.
- **Configure Git webhooks (or document `argocd app get --hard-refresh`) for production:** Relying on default 3-minute polling adds up to 180 s of avoidable recovery latency during incidents; immediate refresh cut end-to-end revert recovery from **173 s** to **5 s**.
- **Test GitOps controllers live against real rendered manifests:** Running Argo CD v2.14.2 live caught the `app.kubernetes.io/instance` label-tracking collision that static YAML linting and Helm linting cannot detect (`gitops/argocd/argocd-cm.yaml`).
