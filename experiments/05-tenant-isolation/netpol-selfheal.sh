#!/usr/bin/env bash
# Follow-up to Experiment 05: the `edit` ClusterRole lets a team delete NetworkPolicies in
# its own namespaces. Delete default-deny-ingress as a payments-team developer and measure
# how long until Argo CD (idp-tenants, selfHeal: true) recreates it.
#
#   netpol-selfheal.sh <run-id>
set -euo pipefail

RUN_ID="${1:-1}"
NS="payments-team-staging"
POLICY="default-deny-ingress"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${SCRIPT_DIR}/results/netpol-selfheal-run${RUN_ID}.json"
k() { kubectl --context kind-idp-local "$@"; }

old_uid="$(k -n "${NS}" get networkpolicy "${POLICY}" -o jsonpath='{.metadata.uid}')"
start="$(python3 -c 'import time; print(time.time())')"
k --as=dev@payments.example --as-group=team:payments-team -n "${NS}" \
  delete networkpolicy "${POLICY}" --wait=false >/dev/null

restored=""
for _ in $(seq 1 600); do
  uid="$(k -n "${NS}" get networkpolicy "${POLICY}" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
  if [[ -n "${uid}" && "${uid}" != "${old_uid}" ]]; then
    restored="$(python3 -c 'import time; print(time.time())')"
    break
  fi
  sleep 0.5
done

python3 - "${start}" "${restored}" "${OUT}" <<'PY'
import json, sys
start, restored, out = sys.argv[1], sys.argv[2], sys.argv[3]
result = {
    "deleted_by": "dev@payments.example (group team:payments-team)",
    "restored": bool(restored),
    "seconds_until_recreated": round(float(restored) - float(start), 1) if restored else None,
    "timeout_s": 300,
}
open(out, "w").write(json.dumps(result, indent=2) + "\n")
print(json.dumps(result))
PY
