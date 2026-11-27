#!/usr/bin/env bash
set -euo pipefail

KUBE_CONTEXT="kind-idp-local"
NAMESPACE="payments-team-prod"
# Tenant NetworkPolicy admits same-namespace traffic only, so the client runs beside the service.
CLIENT_NS="${NAMESPACE}"
CLIENT_POD="exp02-traffic-client"
DEPLOYMENT="payments-api"
SERVICE="payments-api"
CLIENT_IMAGE="local/payments-api:1.0.0"
SERVICE_URL="http://${SERVICE}.${NAMESPACE}.svc.cluster.local/"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROD_MANIFEST="${REPO_ROOT}/rendered/prod/payments-api/manifests.yaml"

delete_client_pod() {
  kubectl --context "${KUBE_CONTEXT}" -n "${CLIENT_NS}" \
    delete pod "${CLIENT_POD}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
}

# Imperative edits (set env / patch) are not tracked by apply's last-applied
# annotation, so apply alone cannot revert them. Replace the Deployment with the
# rendered spec, then wait until only the desired replicas exist and are Ready.
restore_baseline() {
  kubectl --context "${KUBE_CONTEXT}" apply -f "${PROD_MANIFEST}" >/dev/null
  kubectl --context "${KUBE_CONTEXT}" create --dry-run=client -o json -f "${PROD_MANIFEST}" \
    | python3 -c '
import json, sys
raw, dec, pos, docs = sys.stdin.read(), json.JSONDecoder(), 0, []
while raw[pos:].strip():
    obj, end = dec.raw_decode(raw, pos + len(raw[pos:]) - len(raw[pos:].lstrip()))
    docs.extend(obj["items"] if obj.get("kind") == "List" else [obj])
    pos = end
print(json.dumps(next(d for d in docs if d["kind"] == "Deployment")))' \
    | kubectl --context "${KUBE_CONTEXT}" replace --save-config -f - >/dev/null
  kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
    rollout status "deployment/${DEPLOYMENT}" --timeout=120s
  local desired
  desired="$(kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
    get "deployment/${DEPLOYMENT}" -o jsonpath='{.spec.replicas}')"
  for _ in $(seq 1 120); do
    local count
    count="$(kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
      get pods -l "app.kubernetes.io/name=${DEPLOYMENT}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${count}" == "${desired}" ]]; then
      return 0
    fi
    sleep 1
  done
  echo "ERROR: extra pods still present after rollback." >&2
  return 1
}

cleanup() {
  delete_client_pod
}
trap cleanup EXIT

sample_cluster_state() {
  local label="$1"
  local ts
  ts="$(date -u +%H:%M:%SZ)"
  local ep_json pod_json
  ep_json="$(kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
    get endpointslice -l "kubernetes.io/service-name=${SERVICE}" -o json)"
  pod_json="$(kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
    get pods -l "app.kubernetes.io/name=${DEPLOYMENT}" -o json)"

  python3 - "${label}" "${ts}" "${ep_json}" "${pod_json}" <<'PY'
import json
import sys

label, ts, ep_raw, pod_raw = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
ep_data = json.loads(ep_raw)
pod_data = json.loads(pod_raw)

ready_ep = 0
not_ready_ep = 0
for item in ep_data.get("items", []):
    for ep in item.get("endpoints", []) or []:
        cond = ep.get("conditions", {}) or {}
        if cond.get("ready") is True:
            ready_ep += 1
        else:
            not_ready_ep += 1

pod_summaries = []
for pod in pod_data.get("items", []):
    name = pod["metadata"]["name"]
    phase = pod.get("status", {}).get("phase", "Unknown")
    statuses = pod.get("status", {}).get("containerStatuses", []) or []
    ready = sum(1 for c in statuses if c.get("ready"))
    total = len(statuses)
    restarts = sum(int(c.get("restartCount", 0)) for c in statuses)
    reason = phase
    for c in statuses:
        waiting = (c.get("state") or {}).get("waiting")
        if waiting and waiting.get("reason"):
            reason = waiting["reason"]
    pod_summaries.append(f"{name}:{ready}/{total}:{reason}:restarts={restarts}")

print(
    f"[{ts}] {label} | endpointslice ready={ready_ep} not_ready={not_ready_ep} "
    f"total={ready_ep + not_ready_ep} | pods=[{', '.join(pod_summaries)}]"
)
PY
}

start_traffic_client() {
  local duration_sec="$1"
  local interval_sec="$2"
  delete_client_pod

  cat <<EOF | kubectl --context "${KUBE_CONTEXT}" -n "${CLIENT_NS}" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${CLIENT_POD}
  namespace: ${CLIENT_NS}
  labels:
    app.kubernetes.io/name: exp02-traffic-client
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: client
      image: ${CLIENT_IMAGE}
      imagePullPolicy: IfNotPresent
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        capabilities:
          drop:
            - ALL
        seccompProfile:
          type: RuntimeDefault
      command:
        - python
        - -u
        - -c
        - |
          import time, urllib.request, urllib.error

          url = "${SERVICE_URL}"
          duration = float("${duration_sec}")
          interval = float("${interval_sec}")
          start = time.monotonic()
          total_2xx = 0
          total_non2xx = 0
          total_err = 0
          sec = 0

          while time.monotonic() - start < duration:
              sec += 1
              bucket_end = start + sec
              b_2xx = 0
              b_non2xx = 0
              b_err = 0
              while time.monotonic() < bucket_end and time.monotonic() - start < duration:
                  t0 = time.monotonic()
                  try:
                      with urllib.request.urlopen(url, timeout=2.0) as resp:
                          code = resp.getcode()
                          resp.read()
                          if 200 <= code < 300:
                              b_2xx += 1
                          else:
                              b_non2xx += 1
                  except urllib.error.HTTPError:
                      b_non2xx += 1
                  except Exception:
                      b_err += 1
                  sleep_for = interval - (time.monotonic() - t0)
                  if sleep_for > 0:
                      time.sleep(min(sleep_for, max(0.0, bucket_end - time.monotonic())))
              total_2xx += b_2xx
              total_non2xx += b_non2xx
              total_err += b_err
              print(f"sec={sec:02d} ok_2xx={b_2xx} non_2xx={b_non2xx} conn_err={b_err}")

          total = total_2xx + total_non2xx + total_err
          print(f"SUMMARY total={total} ok_2xx={total_2xx} non_2xx={total_non2xx} conn_err={total_err}")
EOF

  # Wait for client pod to begin running
  for _ in $(seq 1 30); do
    local phase
    phase="$(kubectl --context "${KUBE_CONTEXT}" -n "${CLIENT_NS}" \
      get pod "${CLIENT_POD}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "${phase}" == "Running" || "${phase}" == "Succeeded" ]]; then
      return 0
    fi
    sleep 0.5
  done
  echo "ERROR: client pod ${CLIENT_POD} did not enter Running phase." >&2
  kubectl --context "${KUBE_CONTEXT}" -n "${CLIENT_NS}" describe pod "${CLIENT_POD}" >&2 || true
  return 1
}

collect_traffic_client() {
  for _ in $(seq 1 120); do
    local phase
    phase="$(kubectl --context "${KUBE_CONTEXT}" -n "${CLIENT_NS}" \
      get pod "${CLIENT_POD}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "${phase}" == "Succeeded" || "${phase}" == "Failed" ]]; then
      break
    fi
    sleep 1
  done
  kubectl --context "${KUBE_CONTEXT}" -n "${CLIENT_NS}" logs "${CLIENT_POD}"
  delete_client_pod
}

run_endpoint_smoke_check() {
  delete_client_pod
  cat <<EOF | kubectl --context "${KUBE_CONTEXT}" -n "${CLIENT_NS}" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${CLIENT_POD}
  namespace: ${CLIENT_NS}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: client
      image: ${CLIENT_IMAGE}
      imagePullPolicy: IfNotPresent
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        capabilities:
          drop:
            - ALL
        seccompProfile:
          type: RuntimeDefault
      command:
        - python
        - -u
        - -c
        - |
          import urllib.request

          base = "http://${SERVICE}.${NAMESPACE}.svc.cluster.local"
          for path in ("/", "/livez", "/healthz"):
              with urllib.request.urlopen(base + path, timeout=3.0) as r:
                  print(f"GET {path} -> HTTP {r.getcode()} {r.read().decode().strip()}")
          with urllib.request.urlopen(base + "/metrics", timeout=3.0) as r:
              body = r.read().decode()
              lines = [ln for ln in body.splitlines() if ln.startswith("payments_api_")]
              print(f"GET /metrics -> HTTP {r.getcode()}")
              for ln in lines:
                  print("  " + ln)
EOF
  collect_traffic_client
}

for cmd in kubectl python3; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: Required tool '${cmd}' is not installed." >&2
    exit 1
  fi
done

echo "========================================================================"
echo "Experiment 02: Healthy vs. Failed Deployment (In-Cluster Service Traffic)"
echo "Target Service: ${SERVICE_URL}"
echo "========================================================================"

echo ""
echo "==> Case A: Healthy Baseline (local/payments-api:1.0.0, split /livez & /healthz)"
restore_baseline
sample_cluster_state "case-a-baseline"
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get pdb "${DEPLOYMENT}"
run_endpoint_smoke_check

echo ""
echo "==> Case B: Failing Readiness Probe (FAIL_HEALTH=true, split /livez vs /healthz)"
start_traffic_client 45 0.2
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
  patch "deployment/${DEPLOYMENT}" --type=merge -p '{"spec":{"progressDeadlineSeconds":30}}' >/dev/null
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
  set env "deployment/${DEPLOYMENT}" FAIL_HEALTH=true

for i in $(seq 1 8); do
  sleep 5
  sample_cluster_state "case-b-t+$((i * 5))s"
done

echo "--- Case B Deployment Progressing Condition ---"
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
  get "deployment/${DEPLOYMENT}" -o jsonpath='{range .status.conditions[*]}{.type}={.status} reason={.reason} message={.message}{"\n"}{end}'

set +e
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
  rollout status "deployment/${DEPLOYMENT}" --timeout=10s
CASE_B_ROLLOUT_EXIT=$?
set -e
echo "Case B rollout status exit code (non-zero expected): ${CASE_B_ROLLOUT_EXIT}"

echo "--- Case B Unhealthy Events ---"
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
  get events --field-selector reason=Unhealthy --sort-by=.lastTimestamp | tail -n 10 || true

echo "--- Case B In-Cluster Client Traffic Logs ---"
collect_traffic_client

echo ""
echo "==> Rollback after Case B (restoring rendered prod manifest)"
RB_B_START="$(date +%s)"
restore_baseline
RB_B_END="$(date +%s)"
echo "Case B time from rollback to baseline-only pods: $((RB_B_END - RB_B_START))s"
sample_cluster_state "case-b-post-rollback"

echo ""
echo "==> Case C: Bad Image Tag (local/payments-api:9.9.9-missing -> ImagePullBackOff)"
start_traffic_client 35 0.2
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
  patch "deployment/${DEPLOYMENT}" --type=merge -p '{"spec":{"progressDeadlineSeconds":25}}' >/dev/null
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
  set image "deployment/${DEPLOYMENT}" "${DEPLOYMENT}=local/payments-api:9.9.9-missing"

for i in $(seq 1 6); do
  sleep 5
  sample_cluster_state "case-c-t+$((i * 5))s"
done

echo "--- Case C Deployment Progressing Condition ---"
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
  get "deployment/${DEPLOYMENT}" -o jsonpath='{range .status.conditions[*]}{.type}={.status} reason={.reason} message={.message}{"\n"}{end}'

set +e
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
  rollout status "deployment/${DEPLOYMENT}" --timeout=10s
CASE_C_ROLLOUT_EXIT=$?
set -e
echo "Case C rollout status exit code (non-zero expected): ${CASE_C_ROLLOUT_EXIT}"

echo "--- Case C In-Cluster Client Traffic Logs ---"
collect_traffic_client

echo ""
echo "==> Rollback after Case C (restoring rendered prod manifest)"
RB_C_START="$(date +%s)"
restore_baseline
RB_C_END="$(date +%s)"
echo "Case C time from rollback to baseline-only pods: $((RB_C_END - RB_C_START))s"
sample_cluster_state "case-c-post-rollback"

echo ""
echo "==> Case D (Contrast): Coupled Liveness Probe (livenessProbe=/healthz + FAIL_HEALTH=true)"
start_traffic_client 90 0.2
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
  patch "deployment/${DEPLOYMENT}" --type=json -p '[
    {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/path","value":"/healthz"},
    {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"FAIL_HEALTH","value":"true"}}
  ]' >/dev/null

for i in $(seq 1 9); do
  sleep 10
  sample_cluster_state "case-d-coupled-t+$((i * 10))s"
done

echo "--- Case D Liveness Probe Events ---"
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
  get events --field-selector reason=Unhealthy --sort-by=.lastTimestamp | tail -n 10 || true

echo "--- Case D In-Cluster Client Traffic Logs ---"
collect_traffic_client

echo ""
echo "==> Final Cleanup & Baseline Restore (local/payments-api:1.0.0)"
RB_D_START="$(date +%s)"
restore_baseline
RB_D_END="$(date +%s)"
echo "Final time from rollback to baseline-only pods: $((RB_D_END - RB_D_START))s"
sample_cluster_state "final-baseline"
