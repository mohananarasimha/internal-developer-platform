#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="idp-local"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"
IMAGE_TAG="local/payments-api:1.0.0"
ARGOCD_VERSION="v2.14.2"
WITH_ARGOCD=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--with-argocd]

Bootstraps the local kind cluster (${CLUSTER_NAME}), builds and loads ${IMAGE_TAG},
applies tenant namespaces (rendered-tenants/), and provisions synthetic local placeholder Secrets.

Options:
  --with-argocd   Also install pinned Argo CD (${ARGOCD_VERSION}) and apply ApplicationSet
  -h, --help      Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-argocd)
      WITH_ARGOCD=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

for cmd in docker kind kubectl; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: Required tool '${cmd}' is not installed or not on PATH." >&2
    exit 1
  fi
done

echo "==> Checking kind cluster '${CLUSTER_NAME}'"
if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  echo "Cluster '${CLUSTER_NAME}' already exists; reusing it."
else
  kind create cluster --config "${SCRIPT_DIR}/cluster-config.yaml"
fi

kubectl config use-context "${KUBE_CONTEXT}" >/dev/null

echo "==> Building container image '${IMAGE_TAG}'"
docker build -t "${IMAGE_TAG}" "${REPO_ROOT}/apps/payments-api"

echo "==> Loading '${IMAGE_TAG}' into kind cluster '${CLUSTER_NAME}'"
kind load docker-image "${IMAGE_TAG}" --name "${CLUSTER_NAME}"

# Tenants first: service Applications use CreateNamespace=false and need these namespaces.
echo "==> Applying tenant namespaces, RBAC, quotas, and NetworkPolicies (rendered-tenants/)"
kubectl --context "${KUBE_CONTEXT}" apply -R -f "${REPO_ROOT}/rendered-tenants"

synthetic_secret() {
  local ns="$1" name="$2"
  shift 2
  kubectl --context "${KUBE_CONTEXT}" -n "${ns}" create secret generic "${name}" "$@" \
    --dry-run=client -o yaml | kubectl --context "${KUBE_CONTEXT}" apply -f -
}

echo "==> Provisioning synthetic local placeholder Secrets (never real credentials)"
for env in staging prod; do
  synthetic_secret "payments-team-${env}" payments-db-credentials \
    --from-literal=SYNTHETIC_DB_USER="local-synthetic-user" \
    --from-literal=SYNTHETIC_DB_DSN="postgres://local-placeholder:5432/payments"
  synthetic_secret "payments-team-${env}" payments-signing-keys \
    --from-literal=SYNTHETIC_SIGNING_KEY_ID="local-placeholder-key-01"
  synthetic_secret "ledger-team-${env}" ledger-db-credentials \
    --from-literal=SYNTHETIC_DB_USER="local-synthetic-ledger" \
    --from-literal=SYNTHETIC_DB_DSN="postgres://local-placeholder:5432/ledger"
done

if [[ "${WITH_ARGOCD}" == "true" ]]; then
  echo "==> Installing Argo CD (${ARGOCD_VERSION}) in namespace 'argocd'"
  kubectl --context "${KUBE_CONTEXT}" create namespace argocd --dry-run=client -o yaml \
    | kubectl --context "${KUBE_CONTEXT}" apply -f -
  kubectl --context "${KUBE_CONTEXT}" apply -n argocd \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
  echo "==> Waiting for argocd-server deployment to become ready"
  kubectl --context "${KUBE_CONTEXT}" -n argocd rollout status deployment/argocd-server --timeout=300s
  echo "==> Switching Argo CD to annotation-based resource tracking"
  kubectl --context "${KUBE_CONTEXT}" apply -f "${REPO_ROOT}/gitops/argocd/argocd-cm.yaml"
  echo "==> Applying platform tenants Application"
  kubectl --context "${KUBE_CONTEXT}" apply -f "${REPO_ROOT}/gitops/argocd/tenants-application.yaml"
  echo "==> Applying GitOps ApplicationSet"
  kubectl --context "${KUBE_CONTEXT}" apply -f "${REPO_ROOT}/gitops/argocd/applicationset.yaml"
else
  echo "==> Skipping Argo CD install (pass --with-argocd to install Argo CD ${ARGOCD_VERSION})"
fi

echo "==> Bootstrap complete for context '${KUBE_CONTEXT}'."
