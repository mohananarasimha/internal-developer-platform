#!/usr/bin/env bash
set -euo pipefail

# Installs pinned Kubernetes metrics-server on local kind cluster (idp-local).
#
# Why --kubelet-insecure-tls is patched ONLY for local kind:
# kind kubelets use self-signed serving certificates that are not signed by the
# cluster CA, causing metrics-server TLS verification to fail with x509 errors.
# In production clusters, NEVER use --kubelet-insecure-tls; instead enable
# kubelet serving certificate rotation (serverTLSBootstrap: true) signed by a
# cluster-trusted CA.

CLUSTER_NAME="idp-local"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"
METRICS_SERVER_VERSION="v0.7.2"
MANIFEST_URL="https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"

for cmd in kubectl; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: Required tool '${cmd}' is not installed." >&2
    exit 1
  fi
done

echo "==> Applying pinned metrics-server ${METRICS_SERVER_VERSION} to '${KUBE_CONTEXT}'"
kubectl --context "${KUBE_CONTEXT}" apply -f "${MANIFEST_URL}"

echo "==> Patching metrics-server with --kubelet-insecure-tls (kind-only workaround)"
CURRENT_ARGS="$(kubectl --context "${KUBE_CONTEXT}" -n kube-system get deployment metrics-server \
  -o jsonpath='{.spec.template.spec.containers[0].args[*]}')"

if [[ "${CURRENT_ARGS}" != *"--kubelet-insecure-tls"* ]]; then
  kubectl --context "${KUBE_CONTEXT}" -n kube-system patch deployment metrics-server \
    --type=json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
fi

echo "==> Waiting for metrics-server rollout"
kubectl --context "${KUBE_CONTEXT}" -n kube-system rollout status deployment/metrics-server --timeout=180s

echo "==> Verifying metrics.k8s.io API responds"
for _ in $(seq 1 30); do
  if kubectl --context "${KUBE_CONTEXT}" top nodes >/dev/null 2>&1; then
    kubectl --context "${KUBE_CONTEXT}" top nodes
    echo "==> metrics-server ${METRICS_SERVER_VERSION} is ready on '${KUBE_CONTEXT}'."
    exit 0
  fi
  sleep 2
done

echo "ERROR: metrics-server did not return node metrics within 60s." >&2
exit 1
