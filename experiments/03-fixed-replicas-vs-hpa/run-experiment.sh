#!/usr/bin/env bash
set -euo pipefail

# Experiment 03: fixed replicas=2 vs. HPA (min 2 / max 6 / 65% CPU) under the same
# open-loop CPU-bound load, generated in-cluster through the Service DNS name.
#
# Usage:
#   run-experiment.sh capacity            # step open-loop rates against fixed 2 replicas
#   run-experiment.sh fixed <run-id>      # fixed replicas=2, no HPA
#   run-experiment.sh hpa <run-id>        # rendered prod HPA applied
#   run-experiment.sh reset               # restore rendered prod manifest (incl. HPA)
#
# Tunables (env): WORK_MS, RATE_RPS, LOAD_SEC, POST_SEC, CAPACITY_RATES, CAPACITY_SEC

KUBE_CONTEXT="kind-idp-local"
NAMESPACE="payments-team-prod"
# Tenant NetworkPolicy admits same-namespace traffic only, so the client runs beside the service.
CLIENT_NS="${NAMESPACE}"
CLIENT_POD="exp03-load-client"
CLIENT_CM="exp03-load-client"
DEPLOYMENT="payments-api"
CLIENT_IMAGE="local/payments-api:1.0.0"

WORK_MS="${WORK_MS:-20}"
RATE_RPS="${RATE_RPS:-60}"
LOAD_SEC="${LOAD_SEC:-240}"
POST_SEC="${POST_SEC:-360}"
INTERVAL_SEC="${INTERVAL_SEC:-10}"
TIMEOUT_SEC="${TIMEOUT_SEC:-5}"
MAX_INFLIGHT="${MAX_INFLIGHT:-600}"
SAMPLE_SEC="${SAMPLE_SEC:-5}"
CAPACITY_RATES="${CAPACITY_RATES:-20 30 40 50 60}"
CAPACITY_SEC="${CAPACITY_SEC:-40}"
TARGET_URL="http://payments-api.${NAMESPACE}.svc.cluster.local/work?ms=${WORK_MS}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROD_MANIFEST="${REPO_ROOT}/rendered/prod/payments-api/manifests.yaml"
RESULTS_DIR="${SCRIPT_DIR}/results"
SAMPLER_PID=""

k() { kubectl --context "${KUBE_CONTEXT}" "$@"; }

cleanup() {
  if [[ -n "${SAMPLER_PID}" ]]; then
    kill "${SAMPLER_PID}" >/dev/null 2>&1 || true
  fi
  k -n "${CLIENT_NS}" delete pod "${CLIENT_POD}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  k -n "${CLIENT_NS}" delete configmap "${CLIENT_CM}" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Print the JSON of one rendered prod object (by kind) without needing PyYAML on the host.
rendered_doc() {
  local kind="$1"
  k create --dry-run=client -o json -f "${PROD_MANIFEST}" | python3 -c '
import json, sys
kind = sys.argv[1]
raw, dec, pos, docs = sys.stdin.read(), json.JSONDecoder(), 0, []
while raw[pos:].strip():
    obj, end = dec.raw_decode(raw, pos + len(raw[pos:]) - len(raw[pos:].lstrip()))
    docs.extend(obj["items"] if obj.get("kind") == "List" else [obj])
    pos = end
print(json.dumps(next(d for d in docs if d["kind"] == kind)))' "${kind}"
}

wait_for_pod_count() {
  local want="$1"
  for _ in $(seq 1 180); do
    local count
    count="$(k -n "${NAMESPACE}" get pods -l "app.kubernetes.io/name=${DEPLOYMENT}" \
      --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    [[ "${count}" == "${want}" ]] && return 0
    sleep 1
  done
  echo "ERROR: pod count did not settle at ${want}" >&2
  return 1
}

# Wait (bounded) until every payments-api pod reports < 20m CPU in metrics-server, so a
# run never starts while the previous run's CPU is still in the metrics window.
wait_for_idle_cpu() {
  for _ in $(seq 1 36); do
    local max_m
    max_m="$(k -n "${NAMESPACE}" top pods -l "app.kubernetes.io/name=${DEPLOYMENT}" --no-headers 2>/dev/null \
      | awk '{gsub("m","",$2); if ($2+0>m) m=$2+0} END {print m+0}')"
    if [[ -n "${max_m}" && "${max_m}" -lt 20 ]]; then
      echo "idle: max pod CPU ${max_m}m"
      return 0
    fi
    sleep 5
  done
  echo "ERROR: pods did not go idle within 180s" >&2
  return 1
}

baseline_fixed() {
  echo "==> Baseline: rendered prod Deployment/Service/PDB, HPA removed, replicas=2"
  k -n "${NAMESPACE}" delete hpa "${DEPLOYMENT}" --ignore-not-found >/dev/null
  for kind in Service PodDisruptionBudget Deployment; do
    rendered_doc "${kind}" | k apply -f - >/dev/null
  done
  k -n "${NAMESPACE}" scale "deployment/${DEPLOYMENT}" --replicas=2 >/dev/null
  k -n "${NAMESPACE}" rollout status "deployment/${DEPLOYMENT}" --timeout=120s >/dev/null
  wait_for_pod_count 2
  wait_for_idle_cpu
}

baseline_hpa() {
  baseline_fixed
  echo "==> Applying rendered prod HPA and waiting for it to observe idle CPU at 2 replicas"
  rendered_doc HorizontalPodAutoscaler | k apply -f - >/dev/null
  for _ in $(seq 1 40); do
    local state
    state="$(k -n "${NAMESPACE}" get hpa "${DEPLOYMENT}" \
      -o jsonpath='{.status.desiredReplicas} {.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null || true)"
    read -r desired util <<<"${state}"
    if [[ "${desired:-}" == "2" && -n "${util:-}" && "${util}" -lt 65 ]]; then
      echo "HPA ready: desired=${desired} cpu=${util}%"
      return 0
    fi
    sleep 3
  done
  echo "ERROR: HPA did not report desired=2 with a CPU reading within 120s" >&2
  return 1
}

sampler() {
  local out="$1"
  echo "host_epoch,deploy_spec_replicas,deploy_ready_replicas,hpa_current,hpa_desired,hpa_cpu_util_pct,pods_cpu_m" >"${out}"
  while true; do
    local now dep hpa cpu
    now="$(date +%s)"
    dep="$(k -n "${NAMESPACE}" get deploy "${DEPLOYMENT}" \
      -o jsonpath='{.spec.replicas},{.status.readyReplicas}' 2>/dev/null || echo ",")"
    hpa="$(k -n "${NAMESPACE}" get hpa "${DEPLOYMENT}" \
      -o jsonpath='{.status.currentReplicas},{.status.desiredReplicas},{.status.currentMetrics[0].resource.current.averageUtilization}' \
      2>/dev/null || echo ",,")"
    cpu="$(k -n "${NAMESPACE}" top pods -l "app.kubernetes.io/name=${DEPLOYMENT}" --no-headers 2>/dev/null \
      | awk '{gsub("m","",$2); printf "%s%s", sep, $2; sep=";"}' || true)"
    echo "${now},${dep},${hpa},${cpu}" >>"${out}"
    sleep "${SAMPLE_SEC}"
  done
}

start_client() {
  local rate="$1" duration="$2" interval="$3"
  k -n "${CLIENT_NS}" delete pod "${CLIENT_POD}" --ignore-not-found --wait=true >/dev/null
  k -n "${CLIENT_NS}" create configmap "${CLIENT_CM}" --from-file="load_client.py=${SCRIPT_DIR}/load_client.py" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  cat <<EOF | k -n "${CLIENT_NS}" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${CLIENT_POD}
  labels:
    app.kubernetes.io/name: exp03-load-client
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
      command: ["python", "-u", "/client/load_client.py"]
      env:
        - {name: TARGET_URL, value: "${TARGET_URL}"}
        - {name: RATE_RPS, value: "${rate}"}
        - {name: DURATION_SEC, value: "${duration}"}
        - {name: INTERVAL_SEC, value: "${interval}"}
        - {name: TIMEOUT_SEC, value: "${TIMEOUT_SEC}"}
        - {name: MAX_INFLIGHT, value: "${MAX_INFLIGHT}"}
      resources:
        requests: {cpu: 250m, memory: 128Mi}
        limits: {cpu: "1", memory: 512Mi}
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
        seccompProfile:
          type: RuntimeDefault
      volumeMounts:
        - {name: client, mountPath: /client, readOnly: true}
  volumes:
    - name: client
      configMap:
        name: ${CLIENT_CM}
EOF
  k -n "${CLIENT_NS}" wait --for=condition=Ready "pod/${CLIENT_POD}" --timeout=60s >/dev/null
}

wait_client_done() {
  local max_sec="$1"
  for _ in $(seq 1 "${max_sec}"); do
    local phase
    phase="$(k -n "${CLIENT_NS}" get pod "${CLIENT_POD}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "${phase}" == "Succeeded" || "${phase}" == "Failed" ]] && return 0
    sleep 1
  done
  echo "ERROR: client pod did not finish within ${max_sec}s" >&2
  return 1
}

# Scale-up timings from API-server timestamps (same clock as the client pod's LOAD_START).
scaleup_report() {
  local load_start="$1"
  local pods_json events_json
  pods_json="$(k -n "${NAMESPACE}" get pods -l "app.kubernetes.io/name=${DEPLOYMENT}" -o json)"
  events_json="$(k -n "${NAMESPACE}" get events -o json \
    --field-selector "involvedObject.kind=HorizontalPodAutoscaler,reason=SuccessfulRescale")"
  python3 - "${load_start}" "${pods_json}" "${events_json}" <<'PY'
import json, sys
from datetime import datetime, timezone

def ts(s):
    if not s:
        return None
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()

load_start = float(sys.argv[1])
pods = json.loads(sys.argv[2])["items"]
events = json.loads(sys.argv[3])["items"]
for ev in sorted(events, key=lambda e: e.get("lastTimestamp") or ""):
    t = ts(ev.get("lastTimestamp") or ev.get("firstTimestamp"))
    if t is not None and t >= load_start - 1:
        print(f"HPA_EVENT t+{t - load_start:.0f}s count={ev.get('count')} {ev.get('message')}")
new = []
for p in pods:
    created = ts(p["metadata"]["creationTimestamp"])
    ready = next((ts(c.get("lastTransitionTime")) for c in p["status"].get("conditions", [])
                  if c["type"] == "Ready" and c["status"] == "True"), None)
    restarts = sum(cs.get("restartCount", 0) for cs in p["status"].get("containerStatuses", []))
    tag = "new" if created >= load_start else "pre"
    rel = lambda t: "n/a" if t is None else f"t+{t - load_start:.0f}s"
    print(f"POD {p['metadata']['name']} {tag} created={rel(created)} ready={rel(ready)} "
          f"node={p['spec'].get('nodeName')} restarts={restarts}")
    if tag == "new":
        new.append((created, ready))
if new:
    first_created = min(c for c, _ in new)
    readies = [r for _, r in new if r is not None]
    print(f"SCALEUP new_pods={len(new)} first_pod_created=t+{first_created - load_start:.0f}s "
          f"first_new_ready={'n/a' if not readies else f't+{min(readies) - load_start:.0f}s'} "
          f"all_new_ready={'n/a' if len(readies) < len(new) else f't+{max(readies) - load_start:.0f}s'}")
else:
    print("SCALEUP new_pods=0")
PY
}

run_capacity() {
  mkdir -p "${RESULTS_DIR}"
  local out="${RESULTS_DIR}/capacity.log"
  baseline_fixed
  {
    echo "# capacity probe: fixed replicas=2, WORK_MS=${WORK_MS}, ${CAPACITY_SEC}s per rate, $(date -u +%FT%TZ)"
    for rate in ${CAPACITY_RATES}; do
      wait_for_idle_cpu >/dev/null
      start_client "${rate}" "${CAPACITY_SEC}" "${CAPACITY_SEC}"
      wait_client_done $((CAPACITY_SEC + 60))
      echo "RATE ${rate} $(k -n "${CLIENT_NS}" logs "${CLIENT_POD}" | grep '^SUMMARY')"
      k -n "${NAMESPACE}" get pods -l "app.kubernetes.io/name=${DEPLOYMENT}" --no-headers \
        | awk '{print "  pod " $1 " ready=" $2 " restarts=" $4}'
    done
  } | tee "${out}"
}

run_mode() {
  local mode="$1" run_id="$2"
  mkdir -p "${RESULTS_DIR}"
  local prefix="${RESULTS_DIR}/${mode}-run${run_id}"
  if [[ "${mode}" == "hpa" ]]; then baseline_hpa; else baseline_fixed; fi
  k -n "${NAMESPACE}" get pods -l "app.kubernetes.io/name=${DEPLOYMENT}" --no-headers \
    | awk '{print "PRE_RUN_POD " $1 " restarts=" $4}' >"${prefix}-pre-run-pods.log"

  sampler "${prefix}-timeline.csv" &
  SAMPLER_PID=$!
  echo "==> ${mode} run ${run_id}: ${RATE_RPS} rps open-loop to ${TARGET_URL} for ${LOAD_SEC}s"
  start_client "${RATE_RPS}" "${LOAD_SEC}" "${INTERVAL_SEC}"
  wait_client_done $((LOAD_SEC + 2 * TIMEOUT_SEC + 60))
  k -n "${CLIENT_NS}" logs "${CLIENT_POD}" >"${prefix}-client.log"
  local load_start
  load_start="$(awk -F'epoch=' '/^LOAD_START/ {print $2}' "${prefix}-client.log")"
  scaleup_report "${load_start}" >"${prefix}-scaleup.log"

  if [[ "${mode}" == "hpa" ]]; then
    echo "==> Load finished; observing scale-down for ${POST_SEC}s"
    sleep "${POST_SEC}"
    scaleup_report "${load_start}" | grep '^HPA_EVENT' >"${prefix}-hpa-events-after.log" || true
  fi
  kill "${SAMPLER_PID}" >/dev/null 2>&1 || true
  SAMPLER_PID=""

  echo "load_start_epoch=${load_start}" >"${prefix}-meta.txt"
  echo "mode=${mode} rate_rps=${RATE_RPS} work_ms=${WORK_MS} load_sec=${LOAD_SEC} timeout_sec=${TIMEOUT_SEC}" >>"${prefix}-meta.txt"
  grep -E '^(INTERVAL|SUMMARY|DRAINED)' "${prefix}-client.log"
  cat "${prefix}-scaleup.log"
}

case "${1:-}" in
  capacity) run_capacity ;;
  fixed|hpa)
    [[ -n "${2:-}" ]] || { echo "run id required" >&2; exit 1; }
    run_mode "$1" "$2"
    ;;
  reset)
    k -n "${NAMESPACE}" delete hpa "${DEPLOYMENT}" --ignore-not-found >/dev/null
    k apply -f "${PROD_MANIFEST}" >/dev/null
    k -n "${NAMESPACE}" rollout status "deployment/${DEPLOYMENT}" --timeout=120s
    ;;
  *) sed -n '4,13p' "$0"; exit 1 ;;
esac
