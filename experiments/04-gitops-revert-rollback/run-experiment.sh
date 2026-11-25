#!/usr/bin/env bash
set -euo pipefail

# Experiment 04 helper: cluster-side setup, an observer that records Argo CD / Deployment
# state once per second while an in-cluster client measures availability, and teardown.
# Git changes to the throwaway exp04-sandbox branch and the `kubectl rollout undo` are
# performed by the operator between `observe-start` and `observe-stop` (see README).
#
# Usage:
#   run-experiment.sh setup-cluster            # namespace, synthetic Secrets, Application
#   run-experiment.sh payload <name> <blob-sha> <message>
#                                              # .work/<name>.yaml -> .work/<name>.json
#                                              # (body for PUT /repos/{repo}/contents/{path})
#   run-experiment.sh observe-start <trial>    # background sampler + availability client
#   run-experiment.sh observe-stop <trial>     # stop both, collect client log
#   run-experiment.sh teardown-cluster         # delete Application, namespace, client

KUBE_CONTEXT="kind-idp-local"
SANDBOX_NS="exp04-sandbox"
APP_NAME="exp04-sandbox"
BRANCH="exp04-sandbox"
CLIENT_NS="default"
CLIENT_POD="exp04-availability-client"
CLIENT_CM="exp04-availability-client"
CLIENT_IMAGE="local/payments-api:1.0.0"
CLIENT_RATE="${CLIENT_RATE:-10}"
CLIENT_MAX_SEC="${CLIENT_MAX_SEC:-1500}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOAD_CLIENT="${REPO_ROOT}/experiments/03-fixed-replicas-vs-hpa/load_client.py"
RESULTS_DIR="${SCRIPT_DIR}/results"
WORK_DIR="${SCRIPT_DIR}/.work"

k() { kubectl --context "${KUBE_CONTEXT}" "$@"; }

setup_cluster() {
  echo "==> Namespace ${SANDBOX_NS} (restricted PSS) + synthetic placeholder Secrets"
  cat <<EOF | k apply -f - >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: ${SANDBOX_NS}
  labels:
    idp.local/experiment: "04"
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
EOF
  k -n "${SANDBOX_NS}" create secret generic payments-db-credentials \
    --from-literal=SYNTHETIC_DB_USER="local-synthetic-user" \
    --from-literal=SYNTHETIC_DB_DSN="postgres://local-placeholder:5432/payments" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  k -n "${SANDBOX_NS}" create secret generic payments-signing-keys \
    --from-literal=SYNTHETIC_SIGNING_KEY_ID="local-placeholder-key-01" \
    --dry-run=client -o yaml | k apply -f - >/dev/null

  echo "==> Applying sandbox Application (targetRevision ${BRANCH})"
  k apply -f "${SCRIPT_DIR}/sandbox-application.yaml" >/dev/null
  for _ in $(seq 1 300); do
    local st
    st="$(k -n argocd get application "${APP_NAME}" -o jsonpath='{.status.sync.status} {.status.health.status} {.status.sync.revision}' 2>/dev/null || true)"
    if [[ "${st}" == "Synced Healthy "* ]]; then
      echo "Synced+Healthy at ${st##* }"
      k -n "${SANDBOX_NS}" get deploy,svc,hpa,pdb
      return 0
    fi
    sleep 1
  done
  echo "ERROR: ${APP_NAME} not Synced+Healthy within 300s (last: ${st:-})" >&2
  return 1
}

payload() {
  local name="$1" blob_sha="$2" message="$3"
  python3 - "${WORK_DIR}/${name}.yaml" "${WORK_DIR}/${name}.json" "${blob_sha}" "${message}" "${BRANCH}" <<'PY'
import base64, json, sys
src, dst, sha, message, branch = sys.argv[1:6]
body = {"message": message, "branch": branch, "sha": sha,
        "content": base64.b64encode(open(src, "rb").read()).decode()}
json.dump(body, open(dst, "w"))
PY
  echo "wrote ${WORK_DIR}/${name}.json"
}

sampler() {
  local out="$1"
  echo "host_epoch,sync,health,revision,op_phase,op_started,template_image,ready,updated,available,unavailable" >"${out}"
  while [[ ! -e "${WORK_DIR}/stop" ]]; do
    local a d
    a="$(k -n argocd get application "${APP_NAME}" -o jsonpath='{.status.sync.status},{.status.health.status},{.status.sync.revision},{.status.operationState.phase},{.status.operationState.startedAt}' 2>/dev/null || echo ",,,,")"
    d="$(k -n "${SANDBOX_NS}" get deploy payments-api -o jsonpath='{.spec.template.spec.containers[0].image},{.status.readyReplicas},{.status.updatedReplicas},{.status.availableReplicas},{.status.unavailableReplicas}' 2>/dev/null || echo ",,,,")"
    echo "$(date +%s),${a},${d}" | sed -E 's/,([0-9a-f]{7})[0-9a-f]{33},/,\1,/' >>"${out}"
    sleep 1
  done
}

start_client() {
  k -n "${CLIENT_NS}" delete pod "${CLIENT_POD}" --ignore-not-found --wait=true >/dev/null
  k -n "${CLIENT_NS}" create configmap "${CLIENT_CM}" --from-file="load_client.py=${LOAD_CLIENT}" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  cat <<EOF | k -n "${CLIENT_NS}" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${CLIENT_POD}
  labels:
    app.kubernetes.io/name: exp04-availability-client
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
        - {name: TARGET_URL, value: "http://payments-api.${SANDBOX_NS}.svc.cluster.local/"}
        - {name: RATE_RPS, value: "${CLIENT_RATE}"}
        - {name: DURATION_SEC, value: "${CLIENT_MAX_SEC}"}
        - {name: INTERVAL_SEC, value: "10"}
        - {name: TIMEOUT_SEC, value: "2"}
        - {name: STOP_FILE, value: "/tmp/stop"}
      resources:
        requests: {cpu: 100m, memory: 64Mi}
        limits: {memory: 256Mi}
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
        - {name: tmp, mountPath: /tmp}
  volumes:
    - name: client
      configMap:
        name: ${CLIENT_CM}
    - name: tmp
      emptyDir: {}
EOF
  k -n "${CLIENT_NS}" wait --for=condition=Ready "pod/${CLIENT_POD}" --timeout=60s >/dev/null
}

observe_start() {
  local n="$1"
  mkdir -p "${RESULTS_DIR}" "${WORK_DIR}"
  rm -f "${WORK_DIR}/stop"
  start_client
  nohup bash -c "$(declare -f k sampler); KUBE_CONTEXT='${KUBE_CONTEXT}' APP_NAME='${APP_NAME}' SANDBOX_NS='${SANDBOX_NS}' WORK_DIR='${WORK_DIR}' sampler '${RESULTS_DIR}/trial${n}-timeline.csv'" \
    >/dev/null 2>&1 &
  echo "observer started at $(date +%s) (client ${CLIENT_RATE} req/s -> payments-api.${SANDBOX_NS})"
}

observe_stop() {
  local n="$1"
  touch "${WORK_DIR}/stop"
  k -n "${CLIENT_NS}" exec "${CLIENT_POD}" -- touch /tmp/stop
  for _ in $(seq 1 60); do
    local phase
    phase="$(k -n "${CLIENT_NS}" get pod "${CLIENT_POD}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "${phase}" == "Succeeded" || "${phase}" == "Failed" ]] && break
    sleep 1
  done
  k -n "${CLIENT_NS}" logs "${CLIENT_POD}" >"${RESULTS_DIR}/trial${n}-client.log"
  k -n "${CLIENT_NS}" delete pod "${CLIENT_POD}" --ignore-not-found --wait=true >/dev/null
  k -n "${CLIENT_NS}" delete configmap "${CLIENT_CM}" --ignore-not-found >/dev/null
  grep -E '^(LOAD_START|LOAD_END|SUMMARY)' "${RESULTS_DIR}/trial${n}-client.log"
}

teardown_cluster() {
  touch "${WORK_DIR}/stop" 2>/dev/null || true
  k -n argocd delete application "${APP_NAME}" --ignore-not-found --wait=true --timeout=120s
  k delete namespace "${SANDBOX_NS}" --ignore-not-found --wait=true --timeout=180s
  k -n "${CLIENT_NS}" delete pod "${CLIENT_POD}" --ignore-not-found >/dev/null
  k -n "${CLIENT_NS}" delete configmap "${CLIENT_CM}" --ignore-not-found >/dev/null
  rm -rf "${WORK_DIR}"
  echo "==> Cluster-side teardown complete"
}

case "${1:-}" in
  setup-cluster) setup_cluster ;;
  payload) payload "$2" "$3" "$4" ;;
  observe-start) observe_start "$2" ;;
  observe-stop) observe_stop "$2" ;;
  teardown-cluster) teardown_cluster ;;
  *) sed -n '4,16p' "$0"; exit 1 ;;
esac
