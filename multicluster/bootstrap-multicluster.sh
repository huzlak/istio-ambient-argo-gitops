#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configurable variables
REPO_URL="${REPO_URL:?Error: REPO_URL environment variable must be set to your git repo URL}"
TARGET_REVISION="${TARGET_REVISION:-main}"
CLUSTER1_CONTEXT="${CLUSTER1_CONTEXT:?Error: CLUSTER1_CONTEXT must be set}"
CLUSTER2_CONTEXT="${CLUSTER2_CONTEXT:?Error: CLUSTER2_CONTEXT must be set}"
CLUSTER1_NAME="${CLUSTER1_NAME:-cluster1}"
CLUSTER2_NAME="${CLUSTER2_NAME:-cluster2}"
GLOO_MESH_LICENSE_KEY="${GLOO_MESH_LICENSE_KEY:?Error: GLOO_MESH_LICENSE_KEY must be set}"

###############################################################################
# Step 1: Prerequisites
###############################################################################
echo ""
echo "============================================"
echo "Step 1: Prerequisites"
echo "============================================"

# 1a. Generate shared root CA and create cacerts secrets
echo "==> Generating certificates..."
"${SCRIPT_DIR}/generate-certs.sh"

# 1b. Create license secrets in both clusters
echo "==> Creating license secrets..."
for ctx in "${CLUSTER1_CONTEXT}" "${CLUSTER2_CONTEXT}"; do
  kubectl --context="${ctx}" create ns istio-system --dry-run=client -o yaml | kubectl --context="${ctx}" apply -f -
  kubectl --context="${ctx}" create secret generic solo-istio-license \
    -n istio-system \
    --from-literal=license-key="${GLOO_MESH_LICENSE_KEY}" \
    --dry-run=client -o yaml | kubectl --context="${ctx}" apply -f -
done

# 1c. Label istio-system namespaces with network topology
echo "==> Labeling istio-system namespaces..."
kubectl --context="${CLUSTER1_CONTEXT}" label namespace istio-system "topology.istio.io/network=${CLUSTER1_NAME}" --overwrite
kubectl --context="${CLUSTER2_CONTEXT}" label namespace istio-system "topology.istio.io/network=${CLUSTER2_NAME}" --overwrite

# 1d. Install Gateway API CRDs in both clusters
echo "==> Installing Gateway API CRDs..."
kubectl --context="${CLUSTER1_CONTEXT}" apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml
kubectl --context="${CLUSTER2_CONTEXT}" apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml

###############################################################################
# Step 2: Install ArgoCD in cluster1
###############################################################################
echo ""
echo "============================================"
echo "Step 2: Install ArgoCD in cluster1"
echo "============================================"

kubectl --context="${CLUSTER1_CONTEXT}" create namespace argocd --dry-run=client -o yaml | kubectl --context="${CLUSTER1_CONTEXT}" apply -f -
kubectl --context="${CLUSTER1_CONTEXT}" apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "==> Waiting for ArgoCD to be ready..."
kubectl --context="${CLUSTER1_CONTEXT}" wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s
kubectl --context="${CLUSTER1_CONTEXT}" wait --for=condition=available deployment/argocd-repo-server -n argocd --timeout=300s

###############################################################################
# Step 3: Register cluster2 in ArgoCD
###############################################################################
echo ""
echo "============================================"
echo "Step 3: Register cluster2 in ArgoCD"
echo "============================================"

ARGOCD_PASSWORD=$(kubectl --context="${CLUSTER1_CONTEXT}" -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)

argocd login localhost:8080 \
  --username admin \
  --password "${ARGOCD_PASSWORD}" \
  --insecure \
  --port-forward \
  --port-forward-namespace argocd \
  --kube-context "${CLUSTER1_CONTEXT}"

argocd cluster add "${CLUSTER2_CONTEXT}" \
  --name "${CLUSTER2_NAME}" \
  --port-forward \
  --port-forward-namespace argocd \
  --kube-context "${CLUSTER1_CONTEXT}" \
  -y

CLUSTER2_SERVER=$(argocd cluster list \
  --port-forward \
  --port-forward-namespace argocd \
  --kube-context "${CLUSTER1_CONTEXT}" \
  -o json | jq -r ".[] | select(.name==\"${CLUSTER2_NAME}\") | .server")

echo "  Cluster2 registered at: ${CLUSTER2_SERVER}"

###############################################################################
# Step 4: Substitute placeholders and apply root apps
###############################################################################
echo ""
echo "============================================"
echo "Step 4: Deploy Istio in both clusters"
echo "============================================"

echo "==> Substituting placeholders..."
find "${SCRIPT_DIR}" -name '*.yaml' -exec sed -i "s|REPO_URL|${REPO_URL}|g" {} +
find "${SCRIPT_DIR}" -name '*.yaml' -exec sed -i "s|TARGET_REVISION|${TARGET_REVISION}|g" {} +
find "${SCRIPT_DIR}" -name '*.yaml' -exec sed -i "s|CLUSTER2_SERVER|${CLUSTER2_SERVER}|g" {} +

echo "==> Applying root applications..."
kubectl --context="${CLUSTER1_CONTEXT}" apply -f "${SCRIPT_DIR}/cluster1/root-app.yaml"
kubectl --context="${CLUSTER1_CONTEXT}" apply -f "${SCRIPT_DIR}/cluster2/root-app.yaml"

echo "==> Waiting for Istio to be ready in cluster1..."
kubectl --context="${CLUSTER1_CONTEXT}" wait --for=condition=available deployment/istiod -n istio-system --timeout=300s

echo "==> Waiting for Istio to be ready in cluster2..."
kubectl --context="${CLUSTER2_CONTEXT}" wait --for=condition=available deployment/istiod -n istio-system --timeout=300s

###############################################################################
# Step 5: Wait for east-west gateway IPs
###############################################################################
echo ""
echo "============================================"
echo "Step 5: Wait for east-west gateway IPs"
echo "============================================"

echo "==> Waiting for cluster1 east-west gateway IP..."
EW_GW_ADDRESS_CLUSTER1=""
while [ -z "${EW_GW_ADDRESS_CLUSTER1}" ]; do
  EW_GW_ADDRESS_CLUSTER1=$(kubectl --context="${CLUSTER1_CONTEXT}" get svc -n istio-eastwest istio-eastwest \
    -o jsonpath="{.status.loadBalancer.ingress[0].ip}" 2>/dev/null || true)
  if [ -z "${EW_GW_ADDRESS_CLUSTER1}" ]; then
    EW_GW_ADDRESS_CLUSTER1=$(kubectl --context="${CLUSTER1_CONTEXT}" get svc -n istio-eastwest istio-eastwest \
      -o jsonpath="{.status.loadBalancer.ingress[0].hostname}" 2>/dev/null || true)
  fi
  if [ -z "${EW_GW_ADDRESS_CLUSTER1}" ]; then
    echo "  Waiting for cluster1 EW gateway IP..."
    sleep 10
  fi
done
echo "  Cluster1 EW gateway: ${EW_GW_ADDRESS_CLUSTER1}"

echo "==> Waiting for cluster2 east-west gateway IP..."
EW_GW_ADDRESS_CLUSTER2=""
while [ -z "${EW_GW_ADDRESS_CLUSTER2}" ]; do
  EW_GW_ADDRESS_CLUSTER2=$(kubectl --context="${CLUSTER2_CONTEXT}" get svc -n istio-eastwest istio-eastwest \
    -o jsonpath="{.status.loadBalancer.ingress[0].ip}" 2>/dev/null || true)
  if [ -z "${EW_GW_ADDRESS_CLUSTER2}" ]; then
    EW_GW_ADDRESS_CLUSTER2=$(kubectl --context="${CLUSTER2_CONTEXT}" get svc -n istio-eastwest istio-eastwest \
      -o jsonpath="{.status.loadBalancer.ingress[0].hostname}" 2>/dev/null || true)
  fi
  if [ -z "${EW_GW_ADDRESS_CLUSTER2}" ]; then
    echo "  Waiting for cluster2 EW gateway IP..."
    sleep 10
  fi
done
echo "  Cluster2 EW gateway: ${EW_GW_ADDRESS_CLUSTER2}"

###############################################################################
# Step 6: Deploy peering gateways
###############################################################################
echo ""
echo "============================================"
echo "Step 6: Deploy peering gateways"
echo "============================================"

# Determine address type (IP vs Hostname)
CLUSTER1_ADDRESS_TYPE="IPAddress"
if ! [[ "${EW_GW_ADDRESS_CLUSTER1}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  CLUSTER1_ADDRESS_TYPE="Hostname"
fi

CLUSTER2_ADDRESS_TYPE="IPAddress"
if ! [[ "${EW_GW_ADDRESS_CLUSTER2}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  CLUSTER2_ADDRESS_TYPE="Hostname"
fi

echo "==> Populating remote gateway manifests with EW IPs..."
# cluster1's remote gateway points to cluster2's EW address
sed -i "s|EW_GW_ADDRESS_CLUSTER2|${EW_GW_ADDRESS_CLUSTER2}|g" "${SCRIPT_DIR}/manifests/peering/cluster1/remote-gateway.yaml"
sed -i "s|type: IPAddress|type: ${CLUSTER2_ADDRESS_TYPE}|g" "${SCRIPT_DIR}/manifests/peering/cluster1/remote-gateway.yaml"

# cluster2's remote gateway points to cluster1's EW address
sed -i "s|EW_GW_ADDRESS_CLUSTER1|${EW_GW_ADDRESS_CLUSTER1}|g" "${SCRIPT_DIR}/manifests/peering/cluster2/remote-gateway.yaml"
sed -i "s|type: IPAddress|type: ${CLUSTER1_ADDRESS_TYPE}|g" "${SCRIPT_DIR}/manifests/peering/cluster2/remote-gateway.yaml"

echo "==> Applying peering remote gateways..."
kubectl --context="${CLUSTER1_CONTEXT}" apply -f "${SCRIPT_DIR}/manifests/peering/cluster1/remote-gateway.yaml"
kubectl --context="${CLUSTER2_CONTEXT}" apply -f "${SCRIPT_DIR}/manifests/peering/cluster2/remote-gateway.yaml"

###############################################################################
# Done
###############################################################################
echo ""
echo "============================================"
echo "Multicluster bootstrap complete!"
echo "============================================"
echo ""
echo "  ArgoCD UI:        kubectl port-forward svc/argocd-server -n argocd 8080:443 --context ${CLUSTER1_CONTEXT}"
echo "  Admin password:   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' --context ${CLUSTER1_CONTEXT} | base64 -d && echo"
echo ""
echo "  Cluster1 context: ${CLUSTER1_CONTEXT}"
echo "  Cluster2 context: ${CLUSTER2_CONTEXT}"
echo "  Cluster1 EW GW:   ${EW_GW_ADDRESS_CLUSTER1}"
echo "  Cluster2 EW GW:   ${EW_GW_ADDRESS_CLUSTER2}"
echo ""
echo "  Test cross-cluster connectivity:"
echo "    kubectl exec deploy/sleep -n httpbin --context ${CLUSTER1_CONTEXT} -- curl -sv http://httpbin.httpbin.svc.cluster.local:8000/headers"
