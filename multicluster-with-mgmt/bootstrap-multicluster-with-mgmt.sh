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

# Resolve Gloo Platform version (use env var or fetch latest)
if [ -z "${GLOO_PLATFORM_VERSION:-}" ]; then
  echo "==> GLOO_PLATFORM_VERSION not set, resolving latest..."
  helm repo add gloo-platform https://storage.googleapis.com/gloo-platform/helm-charts 2>/dev/null || true
  helm repo update gloo-platform
  GLOO_PLATFORM_VERSION=$(helm search repo gloo-platform/gloo-platform-crds --output json | jq -r '.[0].version')
  echo "  Resolved latest Gloo Platform version: ${GLOO_PLATFORM_VERSION}"
fi

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

# 1e. Create gloo-mesh namespace with ambient label in both clusters
echo "==> Creating gloo-mesh namespace..."
for ctx in "${CLUSTER1_CONTEXT}" "${CLUSTER2_CONTEXT}"; do
  kubectl --context="${ctx}" create ns gloo-mesh --dry-run=client -o yaml | kubectl --context="${ctx}" apply -f -
  kubectl --context="${ctx}" label namespace gloo-mesh "istio.io/dataplane-mode=ambient" --overwrite
done

###############################################################################
# Step 2: Install ArgoCD in cluster1
###############################################################################
echo ""
echo "============================================"
echo "Step 2: Install ArgoCD in cluster1"
echo "============================================"

kubectl --context="${CLUSTER1_CONTEXT}" create namespace argocd --dry-run=client -o yaml | kubectl --context="${CLUSTER1_CONTEXT}" apply -f -
kubectl --context="${CLUSTER1_CONTEXT}" apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

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

# Detect if cluster2 is a kind cluster by matching its API server port to a kind Docker node
CLUSTER2_KIND_NODE=""
if command -v docker &>/dev/null; then
  # Get the API server URL from kubeconfig for the cluster2 context
  CLUSTER2_KUBE_CLUSTER=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"${CLUSTER2_CONTEXT}\")].context.cluster}" 2>/dev/null || true)
  CLUSTER2_KUBE_SERVER=$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"${CLUSTER2_KUBE_CLUSTER}\")].cluster.server}" 2>/dev/null || true)
  # Extract port from the server URL (e.g., https://127.0.0.1:7002 -> 7002)
  CLUSTER2_API_PORT=$(echo "${CLUSTER2_KUBE_SERVER}" | grep -oP ':\K[0-9]+$' || true)
  if [ -n "${CLUSTER2_API_PORT}" ]; then
    # Find a kind control-plane node that has this port mapped
    CLUSTER2_KIND_NODE=$(docker ps --filter "label=io.x-k8s.kind.role=control-plane" --format '{{.Names}}' 2>/dev/null | while read -r node; do
      if docker port "${node}" 2>/dev/null | grep -q ":${CLUSTER2_API_PORT}$"; then
        echo "${node}"
        break
      fi
    done)
  fi
fi

if [ -n "${CLUSTER2_KIND_NODE}" ]; then
  echo "==> Detected kind cluster for cluster2 (node: ${CLUSTER2_KIND_NODE})"
  echo "  Using Docker-internal IP for ArgoCD cluster registration..."

  # Get the Docker-internal IP of cluster2's control plane node
  CLUSTER2_INTERNAL_IP=$(docker inspect "${CLUSTER2_KIND_NODE}" -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
  CLUSTER2_SERVER="https://${CLUSTER2_INTERNAL_IP}:6443"

  # Get the service account token from cluster2
  kubectl --context="${CLUSTER2_CONTEXT}" create serviceaccount argocd-manager -n kube-system --dry-run=client -o yaml | kubectl --context="${CLUSTER2_CONTEXT}" apply -f -
  kubectl --context="${CLUSTER2_CONTEXT}" apply -f - <<'RBAC'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: argocd-manager-role
rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["*"]
  - nonResourceURLs: ["*"]
    verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager-role-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: argocd-manager-role
subjects:
  - kind: ServiceAccount
    name: argocd-manager
    namespace: kube-system
RBAC

  # Create a long-lived token secret
  kubectl --context="${CLUSTER2_CONTEXT}" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
EOF

  # Wait for the token to be populated
  sleep 3
  CLUSTER2_TOKEN=$(kubectl --context="${CLUSTER2_CONTEXT}" -n kube-system get secret argocd-manager-token -o jsonpath='{.data.token}' | base64 -d)
  CLUSTER2_CA=$(kubectl --context="${CLUSTER2_CONTEXT}" -n kube-system get secret argocd-manager-token -o jsonpath='{.data.ca\.crt}')

  # Create the ArgoCD cluster secret in cluster1
  kubectl --context="${CLUSTER1_CONTEXT}" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cluster-${CLUSTER2_NAME}
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: "${CLUSTER2_NAME}"
  server: "${CLUSTER2_SERVER}"
  config: |
    {
      "bearerToken": "${CLUSTER2_TOKEN}",
      "tlsClientConfig": {
        "insecure": false,
        "caData": "${CLUSTER2_CA}"
      }
    }
EOF

else
  echo "==> Registering cluster2 via argocd CLI..."
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
fi

echo "  Cluster2 registered at: ${CLUSTER2_SERVER}"

###############################################################################
# Step 4: Substitute placeholders and apply root apps
###############################################################################
echo ""
echo "============================================"
echo "Step 4: Deploy Istio + Gloo Platform in both clusters"
echo "============================================"

echo "==> Substituting placeholders in Application manifests..."
# Replace repoURL in Git-sourced apps (root apps, eastwest, sleep, httpbin)
find "${SCRIPT_DIR}/cluster1" "${SCRIPT_DIR}/cluster2" -name '*.yaml' \
  -exec grep -l 'repoURL:' {} \; | while read -r f; do
  # Only replace repoURL in apps that use Git source (not Helm charts)
  if grep -q "chart:" "$f"; then continue; fi
  sed -i "s|repoURL: .*|repoURL: ${REPO_URL}|g" "$f"
done
# Replace targetRevision in Git-sourced apps
find "${SCRIPT_DIR}/cluster1" "${SCRIPT_DIR}/cluster2" -name '*.yaml' \
  -exec grep -l 'targetRevision:' {} \; | while read -r f; do
  # Only replace targetRevision in apps that use Git source (not Helm charts)
  if grep -q "chart:" "$f"; then continue; fi
  sed -i "s|targetRevision: .*|targetRevision: ${TARGET_REVISION}|g" "$f"
done
# Replace destination server in cluster2 apps
find "${SCRIPT_DIR}/cluster2/apps" -name '*.yaml' \
  -exec sed -i "s|server: .*|server: ${CLUSTER2_SERVER}|g" {} +

# Replace Gloo Platform version placeholder in Helm-sourced gloo-platform apps
find "${SCRIPT_DIR}/cluster1/apps" "${SCRIPT_DIR}/cluster2/apps" -name 'gloo-platform*.yaml' \
  -exec sed -i "s|targetRevision: GLOO_PLATFORM_VERSION|targetRevision: ${GLOO_PLATFORM_VERSION}|g" {} +

# Replace Gloo Mesh license key placeholder
find "${SCRIPT_DIR}/cluster1/apps" -name 'gloo-platform.yaml' \
  -exec sed -i "s|glooMeshCoreLicenseKey: GLOO_MESH_LICENSE_KEY|glooMeshCoreLicenseKey: ${GLOO_MESH_LICENSE_KEY}|g" {} +

echo "==> Pushing substituted values to git (ArgoCD reads child apps from the repo)..."
git -C "${SCRIPT_DIR}" add cluster1/ cluster2/ manifests/
git -C "${SCRIPT_DIR}" commit -m "Bootstrap: substitute placeholders with deployment values" --allow-empty || true
git -C "${SCRIPT_DIR}" push || { echo "ERROR: git push failed. ArgoCD reads apps from git, so placeholders must be committed."; exit 1; }

echo "==> Applying root applications..."
kubectl --context="${CLUSTER1_CONTEXT}" apply -f "${SCRIPT_DIR}/cluster1/root-app.yaml"
kubectl --context="${CLUSTER1_CONTEXT}" apply -f "${SCRIPT_DIR}/cluster2/root-app.yaml"

echo "==> Waiting for ArgoCD to sync and deploy istiod in cluster1..."
until kubectl --context="${CLUSTER1_CONTEXT}" get deployment/istiod -n istio-system &>/dev/null; do
  echo "  Waiting for istiod deployment to appear in cluster1..."
  sleep 10
done
kubectl --context="${CLUSTER1_CONTEXT}" wait --for=condition=available deployment/istiod -n istio-system --timeout=300s

echo "==> Waiting for ArgoCD to sync and deploy istiod in cluster2..."
until kubectl --context="${CLUSTER2_CONTEXT}" get deployment/istiod -n istio-system &>/dev/null; do
  echo "  Waiting for istiod deployment to appear in cluster2..."
  sleep 10
done
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
# Step 7: Wait for Gloo Platform components
###############################################################################
echo ""
echo "============================================"
echo "Step 7: Wait for Gloo Platform components"
echo "============================================"

echo "==> Waiting for gloo-mesh-mgmt-server in cluster1..."
until kubectl --context="${CLUSTER1_CONTEXT}" get deployment/gloo-mesh-mgmt-server -n gloo-mesh &>/dev/null; do
  echo "  Waiting for gloo-mesh-mgmt-server deployment to appear..."
  sleep 10
done
kubectl --context="${CLUSTER1_CONTEXT}" wait --for=condition=available deployment/gloo-mesh-mgmt-server -n gloo-mesh --timeout=300s
echo "  gloo-mesh-mgmt-server is ready!"

# Label telemetry-gateway service for cross-cluster visibility via Istio multicluster.
# The mgmt-server label is handled via Helm serviceOverrides; the telemetry-gateway
# uses the OTel subchart which doesn't support serviceOverrides, so we label it here.
# The ArgoCD Application has ignoreDifferences for this label to prevent reconciliation.
echo "==> Labeling gloo-telemetry-gateway for cross-cluster service discovery..."
until kubectl --context="${CLUSTER1_CONTEXT}" get svc/gloo-telemetry-gateway -n gloo-mesh &>/dev/null; do
  echo "  Waiting for gloo-telemetry-gateway service to appear..."
  sleep 5
done
kubectl --context="${CLUSTER1_CONTEXT}" label svc gloo-telemetry-gateway -n gloo-mesh "solo.io/service-scope=global" --overwrite

echo "==> Waiting for gloo-mesh-agent in cluster2..."
until kubectl --context="${CLUSTER2_CONTEXT}" get deployment/gloo-mesh-agent -n gloo-mesh &>/dev/null; do
  echo "  Waiting for gloo-mesh-agent deployment to appear..."
  sleep 10
done
kubectl --context="${CLUSTER2_CONTEXT}" wait --for=condition=available deployment/gloo-mesh-agent -n gloo-mesh --timeout=300s
echo "  gloo-mesh-agent is ready!"

###############################################################################
# Done
###############################################################################
echo ""
echo "============================================"
echo "Multicluster with management plane bootstrap complete!"
echo "============================================"
echo ""
echo "  ArgoCD UI:        kubectl port-forward svc/argocd-server -n argocd 8080:443 --context ${CLUSTER1_CONTEXT}"
echo "  Admin password:   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' --context ${CLUSTER1_CONTEXT} | base64 -d && echo"
echo "  Gloo UI:          kubectl port-forward svc/gloo-mesh-ui -n gloo-mesh 8090:8090 --context ${CLUSTER1_CONTEXT}"
echo ""
echo "  Cluster1 context: ${CLUSTER1_CONTEXT}"
echo "  Cluster2 context: ${CLUSTER2_CONTEXT}"
echo "  Cluster1 EW GW:   ${EW_GW_ADDRESS_CLUSTER1}"
echo "  Cluster2 EW GW:   ${EW_GW_ADDRESS_CLUSTER2}"
echo "  Gloo Platform:    ${GLOO_PLATFORM_VERSION}"
echo ""
echo "  Test cross-cluster connectivity:"
echo "    kubectl exec deploy/sleep -n httpbin --context ${CLUSTER1_CONTEXT} -- curl -sv http://httpbin.httpbin.mesh.internal:8000/headers"
