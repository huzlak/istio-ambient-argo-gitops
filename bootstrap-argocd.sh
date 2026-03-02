#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configurable variables
CLUSTER_NAME="${CLUSTER_NAME:-cluster1}"
REPO_URL="${REPO_URL:?Error: REPO_URL environment variable must be set to your git repo URL}"
TARGET_REVISION="${TARGET_REVISION:-main}"

echo "==> Installing Gateway API CRDs..."
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml

echo "==> Installing ArgoCD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "==> Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s
kubectl wait --for=condition=available deployment/argocd-repo-server -n argocd --timeout=300s

echo "==> Updating repo URL in Application manifests..."
# Replace placeholder REPO_URL in all Application YAMLs
find "${SCRIPT_DIR}" -name '*.yaml' -exec sed -i "s|REPO_URL|${REPO_URL}|g" {} +
find "${SCRIPT_DIR}" -name '*.yaml' -exec sed -i "s|CLUSTER_NAME|${CLUSTER_NAME}|g" {} +
find "${SCRIPT_DIR}" -name '*.yaml' -exec sed -i "s|TARGET_REVISION|${TARGET_REVISION}|g" {} +

echo "==> Applying root application..."
kubectl apply -f "${SCRIPT_DIR}/singlecluster/root-app.yaml"

echo ""
echo "Bootstrap complete!"
echo "  ArgoCD UI:        kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  Admin password:   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
echo "  Cluster name:     ${CLUSTER_NAME}"
echo "  Repo URL:         ${REPO_URL}"
