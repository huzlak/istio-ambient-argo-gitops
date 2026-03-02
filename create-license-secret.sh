#!/bin/bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-cluster1}"

if [ -z "${GLOO_MESH_LICENSE_KEY:-}" ]; then
  echo "Error: GLOO_MESH_LICENSE_KEY environment variable is not set"
  exit 1
fi

echo "==> Creating istio-system namespace..."
kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace istio-system topology.istio.io/network="${CLUSTER_NAME}" --overwrite

echo "==> Creating license secret..."
kubectl create secret generic solo-istio-license \
  -n istio-system \
  --from-literal=license-key="${GLOO_MESH_LICENSE_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "License secret 'solo-istio-license' created in istio-system namespace"
