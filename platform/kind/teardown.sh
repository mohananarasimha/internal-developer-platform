#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="idp-local"

if ! command -v kind >/dev/null 2>&1; then
  echo "ERROR: 'kind' is not installed or not on PATH." >&2
  exit 1
fi

if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  echo "==> Deleting kind cluster '${CLUSTER_NAME}'"
  kind delete cluster --name "${CLUSTER_NAME}"
else
  echo "==> kind cluster '${CLUSTER_NAME}' does not exist; nothing to delete."
fi
