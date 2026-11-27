# Experiment 03: Fixed Replicas vs. HPA Under Open-Loop CPU Load

> **Namespace change after these results.** The results below were measured before team tenancy, with the service in namespace `prod` and the client in `default`. The script now targets `payments-team-prod` and runs the client in that namespace, because the tenant NetworkPolicy only admits same-namespace and peer-team traffic. The client now also sets an explicit 1 CPU limit. Without one, the namespace LimitRange would give it a 250m default limit and throttle the load generator. It has not been re-run since.

## QUESTION

When offered load exceeds what the prod baseline of 2 replicas can serve, how much does the golden-path HPA (`minReplicas: 2`, `maxReplicas: 6`, `targetCPU: 65`) actually help, and how long are users exposed to overload before it does?

## HYPOTHESIS

- Fixed 2 replicas will saturate: latency grows until client timeouts, and the error rate stays high for the whole load window.
- The HPA will recover, but only after a lag made of metrics-server scrape + HPA sync + pod startup/readiness. Errors will cluster in the first tens of seconds.
- After load stops, the HPA will keep the extra pods for about the 300 s scale-down stabilization window.

## SETUP

- **Cluster:** local `kind` cluster `idp-local` (1 control-plane + 1 worker, Kubernetes v1.35.0). Every payments-api pod landed on `idp-local-worker`. metrics-server v0.7.2 runs with `--metric-resolution=15s`, installed by [`platform/kind/install-metrics-server.sh`](../../platform/kind/install-metrics-server.sh) (pinned manifest; `--kubelet-insecure-tls` only because kind kubelets serve self-signed certs).
- **Workload:** the rendered prod manifest (`rendered/prod/payments-api/manifests.yaml`), unchanged. Each pod has **requests `cpu: 250m`** and limits `cpu: 500m`. HPA utilization is a percentage of the *request*, so 65% = 162.5m per pod, and a pod running at its limit reads as 200%.
- **CPU-bound endpoint:** `GET /work?ms=20` spins until the handling thread has used 20 ms of CPU (`time.thread_time()`, bounded to 1–2000 ms, unit-tested). Theoretical ceiling for 2 replicas: 2 × 500m / 20 ms = **50 req/s**.
- **Load:** [`load_client.py`](load_client.py), stdlib Python in a pod in `default`. It runs the local image with a restricted securityContext and is mounted from a ConfigMap.
  - Requests go to `http://payments-api.prod.svc.cluster.local/work?ms=20`.
  - Arrivals are open-loop at a fixed rate, one thread per request. Latency is measured from the *scheduled* send time, so a slow server cannot slow the arrival rate.
  - Client timeout is 5 s, with at most 600 requests in flight (never reached; the peak was 242).
- **Sampling:** [`run-experiment.sh`](run-experiment.sh) samples the Deployment, the HPA, and `kubectl top pods` every 5 s. Scale-up timings come from API-server timestamps (pod `creationTimestamp`, Ready condition, HPA `SuccessfulRescale` events), measured relative to the client's `LOAD_START` (same clock).
- **Baseline before every run:** HPA deleted, rendered Deployment/Service/PDB re-applied, scaled to 2, exactly 2 pods, every pod < 20m CPU. For HPA runs the rendered HPA is then re-created, and the run waits until it reports `desired=2` and a CPU reading below target. This matters: an HPA created right after a load run reads stale CPU and immediately scales up.
- **Shared host:** the laptop (10 CPUs for OrbStack) was shared with another kind cluster running a separate experiment. Absolute latencies are indicative only; comparisons within this experiment use identical parameters.

```bash
./experiments/03-fixed-replicas-vs-hpa/run-experiment.sh capacity
RATE_RPS=60 ./experiments/03-fixed-replicas-vs-hpa/run-experiment.sh fixed 1
RATE_RPS=60 ./experiments/03-fixed-replicas-vs-hpa/run-experiment.sh hpa 1
./experiments/03-fixed-replicas-vs-hpa/run-experiment.sh reset   # restore rendered prod (incl. HPA)
```

## VARIABLE

Scaling mode only:

- **fixed:** no HPA, `replicas: 2`.
- **hpa:** the rendered prod HPA (min 2, max 6, 65% CPU, `scaleDown.stabilizationWindowSeconds: 300`).

Requests/limits, image, endpoint, arrival rate (60 req/s), duration (240 s) and client settings are identical across runs.

## METRIC

- Per 10 s interval and overall: requests sent and OK, error rate (timeouts + connection errors), p50/p95/p99 latency of successful requests.
  - Successful-request latency is capped near the 5 s timeout. Read it together with the error rate.
  - p99 can exceed 5 s because urllib's timeout applies per socket operation, so connect and read each get up to 5 s.
- Goodput (OK requests / 240 s).
- Replicas (spec / ready) and HPA current / desired / CPU utilization over time.
- Time from load start to the first scale-up decision and to new pods Ready.
- Liveness restarts.

## RESULT

### Capacity sweep (fixed 2 replicas, 40 s per rate)

Measured first, to pick a load that exceeds 2 replicas: [`results/capacity.log`](results/capacity.log)

| Offered req/s | OK / sent | Errors | p50 | p95 | p99 | Goodput |
| --- | --- | --- | --- | --- | --- | --- |
| 20 | 800 / 800 | 0% | 21.9 ms | 25.3 ms | 26.5 ms | 20.0 |
| 30 | 1200 / 1200 | 0% | 21.9 ms | 54.8 ms | 84.8 ms | 30.0 |
| 40 | 1600 / 1600 | 0% | 27.0 ms | 205.8 ms | 285.7 ms | 40.0 |
| 50 | 1981 / 2000 | 0.95% | 365.1 ms | 2514.9 ms | 4086.3 ms | 49.5 |
| 60 | 1935 / 2400 | 19.38% | 489.0 ms | 4570.3 ms | 6488.4 ms | 48.4 |

**Measured capacity of 2 replicas:**

- About 40 req/s with bounded latency (p99 < 300 ms).
- Hard saturation at about 48–50 req/s, matching the 50 req/s theoretical ceiling.
- At 60 req/s, one pod was restarted by its liveness probe.

The comparison runs use **60 req/s**: 1.5× the clean capacity and 1.2× the ceiling.

### Fixed replicas = 2, 60 req/s, 240 s

| Run | OK / sent | Errors | p50 | p95 | p99 | Goodput | Liveness restarts during run |
| --- | --- | --- | --- | --- | --- | --- | --- |
| [fixed 1](results/fixed-run1-client.log) | 10791 / 14400 | 25.06% (3368 timeout, 241 conn) | 499.2 ms | 4570.9 ms | 6114.9 ms | 44.96 | 4 |
| [fixed 2](results/fixed-run2-client.log) | 11020 / 14400 | 23.47% (3238 timeout, 142 conn) | 554.0 ms | 4672.0 ms | 6136.1 ms | 45.92 | 2 |
| [fixed 3](results/fixed-run3-client.log) | 10779 / 14400 | 25.15% (3428 timeout, 193 conn) | 541.0 ms | 4700.4 ms | 6169.9 ms | 44.91 | 4 |

- **No improvement over time.** Every 10 s interval in every fixed run had 6.7–48.5% errors.
- **CPU pinned at the limit.** Both pods sat at about 500m (= limit = 200% of request) for the whole window.
- **Readiness flapping.** In fixed run 3, the Deployment reported only 1 ready replica in 9 of 49 samples.
- **Liveness restarts.** Restarts happened in every run. Connection-error bursts line up with these restarts and readiness drops.
- **Run 3 confirms runs 1 and 2.** Fixed run 3 was run later, on freshly restarted pods, purely to confirm the cluster still behaved like runs 1–2. It matches within about 2 percentage points.

### HPA (min 2 / max 6 / 65%), 60 req/s, 240 s

| Run | OK / sent | Errors | p50 | p95 | p99 | Goodput |
| --- | --- | --- | --- | --- | --- | --- |
| [hpa 1](results/hpa-run1-client.log) | 14006 / 14400 | 2.74% (394 timeout) | 23.0 ms | 1580.8 ms | 4456.2 ms | 58.36 |
| [hpa 2](results/hpa-run2-client.log) | 14233 / 14400 | 1.16% (167 timeout) | 23.1 ms | 454.6 ms | 3401.6 ms | 59.30 |

Scale-up timeline (seconds after load start):

| Run | HPA decisions | New pods created | First new pod Ready | All new pods Ready | Last interval with errors | Steady-state errors |
| --- | --- | --- | --- | --- | --- | --- |
| hpa 1 | t+29 s: 2 → 6 | t+29 s | t+39 s | t+39 s | 30–40 s (15.0%) | 0% from 40 s to 240 s |
| hpa 2 | t+14 s: 2 → 4; t+29 s: 4 → 6 | t+14 s, t+29 s | t+22 s | t+37 s | 20–30 s (1.83%) | 0% from 30 s to 240 s |

- **Same overload as fixed until scale-up.** Before scale-up, the HPA runs looked exactly like fixed mode: 7.5–21.7% errors per interval, p99 4.9–6.6 s.
- **Fast recovery afterwards.** Once the new pods were Ready, the backlog drained within about 10 s. From t+50 s on, both runs had 0 errors, p50 22–23 ms, p95 45–74 ms and p99 75–150 ms.
- **Steady state.** Both runs sat at 6 replicas. Average HPA utilization between t+60 s and t+240 s was 81% (run 1) and 82% (run 2), about 204m per pod.
- **No restarts.** HPA runs had zero liveness restarts.
- **Scale-down.** The HPA's CPU reading fell below target about 15–20 s after load ended. Scale-down to 2 happened at t+542 s (run 1) and t+554 s (run 2), about 287–295 s later, in line with the 300 s stabilization window. Sampling is at 5 s granularity.

Raw data: [`results/`](results/). Notes on the raw data:

- **Recovered logs.** `capacity.log`, `fixed-run{1,2}-client.log`, `hpa-run1-client.log` and `hpa-run1-timeline.csv` were recovered from the runner's terminal output, after a concurrent process deleted the original result files. The numbers are exactly what the runner printed.
- **Elided rows.** Identical idle rows are elided from `hpa-run1-timeline.csv`.
- **UTC/IST bug.** The original scale-up report for fixed runs 1 and 2 parsed API-server UTC timestamps as local IST, so pod offsets were off by 19800 s. Those offsets are corrected and annotated in the files, and the script is fixed. This only affected the pod `created`/`ready` offsets, never the latency or error data.
- **Discarded run.** An earlier HPA run 2 was discarded: another process was changing the same Deployment during it. The HPA run 2 reported here is a clean rerun.

## INTERPRETATION

- **Fixed replicas fail gracelessly under open-loop overload.**
  - Arrivals do not slow down when the service does, so the backlog grows until requests hit the client timeout.
  - The server keeps burning CPU on requests whose clients already gave up, because nothing propagates a deadline. Goodput therefore stays near the ceiling (about 45 req/s), but a quarter of users see failures.
  - **The liveness restarts are a side effect of CPU saturation, not an app bug.** `/livez` is answered by the same Python process. That process is CFS-throttled at its 500m limit and has its GIL shared with dozens of busy request threads, so probe responses exceed the 2 s probe timeout. After 3 misses the kubelet kills the container, which removes capacity exactly when it is most needed and causes the connection-error bursts. This is the probe "death spiral" in a small form.
- **The HPA lag is about 15–40 s here, and it is all exposure.** The pipeline is:
  1. The kubelet/cAdvisor CPU measurement window.
  2. The metrics-server 15 s resolution.
  3. The HPA controller's 15 s sync loop.
  4. Pod scheduling and start.
  5. The readiness probe (`initialDelaySeconds: 5`, `periodSeconds: 5`).

  The two runs differed only in where the load start fell relative to these 15 s cycles. Run 2 caught a sync at t+14 s with a partial window (115%) and scaled in two steps. Run 1 first acted at t+29 s, with a full saturated reading, in one step to 6. Pod start to Ready took 8–10 s, dominated by the readiness probe delay and period.
- **CPU utilization lags queueing latency.** At t+5–10 s, p99 was already several seconds, but the HPA had not yet seen any CPU above target. Worse, CPU utilization tops out at the limit (200% of request) while queueing latency keeps growing without bound. CPU says "busy"; it cannot say "how far behind". A latency or queue-depth signal would react sooner. That needs a custom/external metrics adapter, which is outside this repo's scope.
- **6 pods sat above the 65% target because 6 is `maxReplicas`.** 60 req/s × 20 ms ≈ 1.2 cores of pure work, plus HTTP overhead, measured at about 1.22 cores. That is ≈ 7.5 pods' worth at 162.5m each, so the HPA wanted more than the cap. It still served cleanly, because the target is a planning margin and each pod could go to 500m. But it means 6 pods ran with only about 1.4× headroom (204m used vs. 500m limit) instead of the 3× the target intends.
- **Scale-down stabilization worked as designed.** All 6 pods stayed for about 5 minutes after load ended. That cushions a quick return of load, at the price of about 1 core-minute per pod of idle reservation.

## LESSON

- **Size `minReplicas` to the load you must absorb during the HPA lag, not to average load.** Here the HPA cut errors from about 24% to 1–3%, but every error it allowed happened in the first 30–40 s. If that window matters, raise the floor or scale on a leading signal.
- **CPU-saturated pods and in-process liveness probes are a dangerous mix.** Keep the liveness timeout generous, or make liveness cheap and independent of request threads. Otherwise overload turns into restarts.
- **Check that `maxReplicas` covers the peak at the target utilization**, not just at the CPU limit. At 6 the HPA was pinned at its cap at 81–82% utilization during this load.
- **Expect scale-down to take `stabilizationWindowSeconds` plus up to one sync period** after CPU drops. That is about 5 minutes with the platform default.
