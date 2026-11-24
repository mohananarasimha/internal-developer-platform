#!/usr/bin/env bash
set -euo pipefail

KUBE_CONTEXT="kind-idp-local"
NAMESPACE="prod"
DEPLOYMENT="payments-api"
SERVICE="payments-api"
LOCAL_PORT="18080"
PROBE_DURATION_SEC=25

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROD_MANIFEST="${REPO_ROOT}/rendered/prod/payments-api/manifests.yaml"

PF_PID=""
TMP_DIR="$(mktemp -d)"

stop_port_forward() {
  if [[ -n "${PF_PID}" ]] && kill -0 "${PF_PID}" >/dev/null 2>&1; then
    kill "${PF_PID}" >/dev/null 2>&1 || true
    wait "${PF_PID}" >/dev/null 2>&1 || true
  fi
  PF_PID=""
}

start_port_forward() {
  stop_port_forward
  kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
    port-forward "svc/${SERVICE}" "${LOCAL_PORT}:80" >"${TMP_DIR}/port-forward.log" 2>&1 &
  PF_PID=$!
  for _ in $(seq 1 20); do
    if curl -fsS "http://127.0.0.1:${LOCAL_PORT}/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  echo "ERROR: port-forward to svc/${SERVICE} did not become ready." >&2
  cat "${TMP_DIR}/port-forward.log" >&2 || true
  return 1
}

restore_baseline() {
  kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
    set env "deployment/${DEPLOYMENT}" FAIL_HEALTH- >/dev/null 2>&1 || true
  kubectl --context "${KUBE_CONTEXT}" apply -f "${PROD_MANIFEST}" >/dev/null
  kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
    rollout status "deployment/${DEPLOYMENT}" --timeout=120s
}

cleanup() {
  stop_port_forward
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

run_traffic_probe() {
  local duration="$1"
  local out_file="$2"
  local ok=0
  local fail=0
  local end_ts=$(( $(date +%s) + duration ))
  while [[ $(date +%s) -lt ${end_ts} ]]; do
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${LOCAL_PORT}/" || echo "000")"
    if [[ "${code}" == "200" ]]; then
      ok=$((ok + 1))
    else
      fail=$((fail + 1))
    fi
    sleep 0.5
  done
  echo "ok=${ok} fail=${fail} total=$((ok + fail))" >"${out_file}"
}

for cmd in kubectl curl; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: Required tool '${cmd}' is not installed." >&2
    exit 1
  fi
done

echo "============================================================"
echo "Experiment 02: Healthy vs. Failed Deployment (${NAMESPACE})"
echo "============================================================"

echo ""
echo "==> Case A: Healthy Baseline (local/payments-api:1.0.0)"
restore_baseline
start_port_forward

kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
  get pods -l "app.kubernetes.io/name=${DEPLOYMENT}" -o wide
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get pdb "${DEPLOYMENT}"

health_code="$(curl -s -o "${TMP_DIR}/healthz.json" -w '%{http_code}' "http://127.0.0.1:${LOCAL_PORT}/healthz")"
echo "GET /healthz -> HTTP ${health_code}: $(cat "${TMP_DIR}/healthz.json")"

root_ok=0
for _ in $(seq 1 20); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${LOCAL_PORT}/")"
  if [[ "${code}" == "200" ]]; then
    root_ok=$((root_ok + 1))
  fi
done
echo "Baseline GET / probe -> ${root_ok}/20 HTTP 200 OK"

metrics_body="$(curl -fsS "http://127.0.0.1:${LOCAL_PORT}/metrics")"
echo "GET /metrics excerpt:"
echo "${metrics_body}" | grep -E '^payments_api_(up|requests_total)'

echo ""
echo "==> Case B: Failing Readiness Probe (FAIL_HEALTH=true)"
run_traffic_probe "${PROBE_DURATION_SEC}" "${TMP_DIR}/case_b_traffic.txt" &
TRAFFIC_PID=$!

kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
  set env "deployment/${DEPLOYMENT}" FAIL_HEALTH=true

set +e
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
  rollout status "deployment/${DEPLOYMENT}" --timeout=20s
CASE_B_ROLLOUT_EXIT=$?
set -e

wait "${TRAFFIC_PID}"
echo "Case B rollout status exit code (non-zero expected): ${CASE_B_ROLLOUT_EXIT}"
echo "Case B traffic during broken rollout: $(cat "${TMP_DIR}/case_b_traffic.txt")"
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
  get pods -l "app.kubernetes.io/name=${DEPLOYMENT}" -o wide
echo "Case B Unhealthy events:"
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
  get events --field-selector reason=Unhealthy --sort-by=.lastTimestamp | tail -n 10 || true

echo ""
echo "==> Restoring healthy baseline between Case B and Case C"
restore_baseline
start_port_forward

echo ""
echo "==> Case C: Bad Image Tag (local/payments-api:9.9.9-missing)"
run_traffic_probe "${PROBE_DURATION_SEC}" "${TMP_DIR}/case_c_traffic.txt" &
TRAFFIC_PID=$!

kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
  set image "deployment/${DEPLOYMENT}" "${DEPLOYMENT}=local/payments-api:9.9.9-missing"

set +e
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
  rollout status "deployment/${DEPLOYMENT}" --timeout=20s
CASE_C_ROLLOUT_EXIT=$?
set -e

wait "${TRAFFIC_PID}"
echo "Case C rollout status exit code (non-zero expected): ${CASE_C_ROLLOUT_EXIT}"
echo "Case C traffic during bad image rollout: $(cat "${TMP_DIR}/case_c_traffic.txt")"
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
  get pods -l "app.kubernetes.io/name=${DEPLOYMENT}" -o wide

echo ""
echo "==> Final Recovery: Restoring healthy local/payments-api:1.0.0"
START_RECOVER="$(date +%s)"
restore_baseline
END_RECOVER="$(date +%s)"
echo "Recovered to 2/2 Ready in $((END_RECOVER - START_RECOVER))s"
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
  get pods -l "app.kubernetes.io/name=${DEPLOYMENT}" -o wide
