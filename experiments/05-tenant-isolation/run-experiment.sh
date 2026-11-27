#!/usr/bin/env bash
# Experiment 05: shared environment namespace vs. platform-rendered tenant namespaces.
#
#   run-experiment.sh shared <run-id>    # both teams in one namespace (exp05-shared)
#   run-experiment.sh tenant <run-id>    # live Argo CD-managed <team>-staging namespaces
#   run-experiment.sh teardown           # delete exp05-shared and any leftover probe objects
#
# Every check is a real API request or real pod-to-pod traffic. RBAC checks impersonate a
# payments-team developer; mutating calls use --dry-run=server so they pass through
# authentication, authorization, and admission without persisting anything.
set -euo pipefail

MODE="${1:-}"
RUN_ID="${2:-1}"
KUBE_CONTEXT="kind-idp-local"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"
SHARED_NS="exp05-shared"
IMAGE="local/payments-api:1.0.0"
AS_PAYMENTS=(--as=dev@payments.example --as-group=team:payments-team)
NOISY_REPLICAS=10

k() { kubectl --context "${KUBE_CONTEXT}" "$@"; }

case "${MODE}" in
  shared)
    PAY_NS="${SHARED_NS}"; LEDGER_NS="${SHARED_NS}"; PAY_PROD_NS="" ;;
  tenant)
    PAY_NS="payments-team-staging"; LEDGER_NS="ledger-team-staging"; PAY_PROD_NS="payments-team-prod" ;;
  teardown)
    k delete namespace "${SHARED_NS}" --ignore-not-found --wait=true --timeout=120s
    for ns in payments-team-staging ledger-team-staging; do
      k -n "${ns}" delete deployment exp05-noisy --ignore-not-found >/dev/null
      k -n "${ns}" delete pod -l idp.local/experiment=05 --ignore-not-found >/dev/null
    done
    exit 0 ;;
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac

mkdir -p "${RESULTS_DIR}"
OUT="${RESULTS_DIR}/${MODE}-run${RUN_ID}.jsonl"
: >"${OUT}"

record() {  # category check actor target outcome detail
  python3 -c 'import json,sys; print(json.dumps(dict(zip(
    ["category","check","actor","target","outcome","detail"], sys.argv[1:]))))' "$@" >>"${OUT}"
}

setup_shared() {
  echo "==> Shared model: both teams' staging services in namespace ${SHARED_NS}"
  cat <<EOF | k apply -f - >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: ${SHARED_NS}
  labels:
    idp.local/environment: staging
    idp.local/experiment: "05"
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
EOF
  # In a shared namespace, the only namespace-scoped way to let each team deploy is to bind
  # both groups to the same namespace.
  for team in payments-team ledger-team; do
    k -n "${SHARED_NS}" create rolebinding "${team}-edit" --clusterrole=edit \
      --group="team:${team}" --dry-run=client -o yaml | k apply -f - >/dev/null
  done
  for secret in payments-db-credentials payments-signing-keys ledger-db-credentials; do
    k -n "${SHARED_NS}" create secret generic "${secret}" --from-literal=SYNTHETIC_PLACEHOLDER=local-only \
      --dry-run=client -o yaml | k apply -f - >/dev/null
  done
  for svc in payments-api ledger-api; do
    sed -E "s/^(  namespace: ).*-staging$/\1${SHARED_NS}/" \
      "${REPO_ROOT}/rendered/staging/${svc}/manifests.yaml" | k apply -f - >/dev/null
  done
  for svc in payments-api ledger-api; do
    k -n "${SHARED_NS}" rollout status "deployment/${svc}" --timeout=120s >/dev/null
    # A Service created seconds ago may not have a ready endpoint yet; probe only once it does.
    for _ in $(seq 1 30); do
      ready="$(k -n "${SHARED_NS}" get endpointslices -l "kubernetes.io/service-name=${svc}" \
        -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{"\n"}{end}' | grep -c true || true)"
      (( ready > 0 )) && break
      sleep 1
    done
  done
  sleep 2
}

# --- RBAC: what can a payments-team developer do to ledger-team's objects? -----------------
api_check() {  # check target ns -- kubectl args...
  local check="$1" target="$2" ns="$3"; shift 4
  local out rc=0
  out="$(k "${AS_PAYMENTS[@]}" -n "${ns}" "$@" 2>&1)" || rc=$?
  if [[ " $* " == *" can-i "* ]]; then
    # `auth can-i --quiet` answers through its exit code: 0 = yes, 1 = no.
    record rbac "${check}" payments-dev "${target}" "$( (( rc == 0 )) && echo ALLOWED || echo DENIED)" "SubjectAccessReview"
    return
  fi
  if (( rc == 0 )); then
    record rbac "${check}" payments-dev "${target}" ALLOWED ""
  elif grep -q "Forbidden\|forbidden" <<<"${out}"; then
    record rbac "${check}" payments-dev "${target}" DENIED "$(grep -o 'cannot [^:]*' <<<"${out}" | head -1)"
  else
    record rbac "${check}" payments-dev "${target}" ERROR "$(head -1 <<<"${out}")"
  fi
}

run_rbac() {
  echo "==> RBAC checks (impersonating dev@payments.example, group team:payments-team)"
  api_check "read own secret" "${PAY_NS}/payments-db-credentials" "${PAY_NS}" -- \
    get secret payments-db-credentials -o name
  api_check "read other team's secret" "${LEDGER_NS}/ledger-db-credentials" "${LEDGER_NS}" -- \
    get secret ledger-db-credentials -o name
  api_check "scale other team's deployment" "${LEDGER_NS}/ledger-api" "${LEDGER_NS}" -- \
    scale deployment ledger-api --replicas=0 --dry-run=server
  api_check "delete other team's deployment" "${LEDGER_NS}/ledger-api" "${LEDGER_NS}" -- \
    delete deployment ledger-api --dry-run=server
  api_check "exec into other team's pod" "${LEDGER_NS}/pods/exec" "${LEDGER_NS}" -- \
    auth can-i create pods/exec --quiet
}

# --- Network: can pods in one team's namespace reach another team's Service? ---------------
probe_manifest() {  # pod url
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
  labels: {idp.local/experiment: "05"}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 10001, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: probe
      image: ${IMAGE}
      imagePullPolicy: Never
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: ["ALL"]}
      command:
        - python3
        - -c
        - |
          import urllib.request
          try:
              urllib.request.urlopen("$2", timeout=3)
              print("REACHABLE")
          except Exception as exc:
              reason = getattr(exc, "reason", exc)
              print("BLOCKED", type(exc).__name__ + ":" + str(reason).replace(" ", "_")[:80])
EOF
}

probe() {  # check from_ns url
  local check="$1" from_ns="$2" url="$3" pod="exp05-probe-${RANDOM}" out=""
  probe_manifest "${pod}" "${url}" | k -n "${from_ns}" apply -f - >/dev/null
  if k -n "${from_ns}" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${pod}" \
      --timeout=60s >/dev/null 2>&1; then
    out="$(k -n "${from_ns}" logs "${pod}" 2>/dev/null | tail -1)"
  fi
  k -n "${from_ns}" delete pod "${pod}" --wait=false >/dev/null 2>&1 || true
  record network "${check}" "pod in ${from_ns}" "${url}" "$(awk '{print $1}' <<<"${out:-ERROR}")" \
    "$(awk '{print $2}' <<<"${out}")"
}

run_network() {
  echo "==> Network checks (in-cluster HTTP GET /healthz, 3 s timeout)"
  probe "same team, same namespace" "${PAY_NS}" "http://payments-api.${PAY_NS}.svc.cluster.local/healthz"
  probe "payments -> ledger (not allowed by ledger-team)" "${PAY_NS}" \
    "http://ledger-api.${LEDGER_NS}.svc.cluster.local/healthz"
  probe "ledger -> payments (allowed peer of payments-team)" "${LEDGER_NS}" \
    "http://payments-api.${PAY_NS}.svc.cluster.local/healthz"
  if [[ -n "${PAY_PROD_NS}" ]]; then
    probe "ledger staging -> payments prod (cross-environment)" "${LEDGER_NS}" \
      "http://payments-api.${PAY_PROD_NS}.svc.cluster.local/healthz"
  fi
}

# --- Quota: a runaway deployment by payments-team --------------------------------------------
run_quota() {
  echo "==> Quota check: payments-dev creates a ${NOISY_REPLICAS}-replica deployment in ${PAY_NS}"
  k -n "${PAY_NS}" delete deployment exp05-noisy --ignore-not-found --wait=true >/dev/null
  cat <<EOF | k "${AS_PAYMENTS[@]}" -n "${PAY_NS}" apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: exp05-noisy
  labels: {idp.local/experiment: "05"}
spec:
  replicas: ${NOISY_REPLICAS}
  selector: {matchLabels: {app: exp05-noisy}}
  template:
    metadata:
      labels: {app: exp05-noisy, idp.local/experiment: "05"}
    spec:
      automountServiceAccountToken: false
      securityContext: {runAsNonRoot: true, runAsUser: 10001, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: noisy
          image: ${IMAGE}
          imagePullPolicy: Never
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits: {cpu: 250m, memory: 256Mi}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: ["ALL"]}
EOF
  sleep 20
  local created denied_msg
  created="$(k -n "${PAY_NS}" get pods -l app=exp05-noisy --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  denied_msg="$(k -n "${PAY_NS}" get events --field-selector reason=FailedCreate \
    -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null | grep exp05-noisy | grep -o 'exceeded quota.*' | tail -1 || true)"
  record quota "runaway ${NOISY_REPLICAS}-replica deployment" payments-dev "${PAY_NS}" \
    "${created}/${NOISY_REPLICAS} pods created" "${denied_msg}"
  k -n "${PAY_NS}" delete deployment exp05-noisy --wait=true >/dev/null
}

if [[ "${MODE}" == "shared" ]]; then setup_shared; fi
run_rbac
run_network
run_quota
if [[ "${MODE}" == "shared" ]]; then
  k delete namespace "${SHARED_NS}" --wait=true --timeout=120s >/dev/null
fi

python3 - "${OUT}" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
print(f"\n{'category':<8} {'check':<50} {'outcome':<24} detail")
for r in rows:
    print(f"{r['category']:<8} {r['check']:<50} {r['outcome']:<24} {r['detail']}")
PY
echo "==> Results: ${OUT}"
