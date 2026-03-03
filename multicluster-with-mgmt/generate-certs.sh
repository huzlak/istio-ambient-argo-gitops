#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configurable variables
ISTIO_VERSION="${ISTIO_VERSION:-1.28.4}"
CLUSTER1_NAME="${CLUSTER1_NAME:-cluster1}"
CLUSTER2_NAME="${CLUSTER2_NAME:-cluster2}"
CLUSTER1_CONTEXT="${CLUSTER1_CONTEXT:?Error: CLUSTER1_CONTEXT must be set}"
CLUSTER2_CONTEXT="${CLUSTER2_CONTEXT:?Error: CLUSTER2_CONTEXT must be set}"

WORK_DIR="${SCRIPT_DIR}/_certs_workdir"

echo "==> Downloading Istio ${ISTIO_VERSION} for cert tools..."
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

if [ ! -d "istio-${ISTIO_VERSION}" ]; then
  curl -sL https://istio.io/downloadIstio | ISTIO_VERSION="${ISTIO_VERSION}" sh -
fi

mkdir -p certs
cd certs

echo "==> Generating root CA..."
make -f ../istio-${ISTIO_VERSION}/tools/certs/Makefile.selfsigned.mk root-ca

echo "==> Generating intermediate CA for ${CLUSTER1_NAME}..."
make -f ../istio-${ISTIO_VERSION}/tools/certs/Makefile.selfsigned.mk "${CLUSTER1_NAME}-cacerts"

echo "==> Generating intermediate CA for ${CLUSTER2_NAME}..."
make -f ../istio-${ISTIO_VERSION}/tools/certs/Makefile.selfsigned.mk "${CLUSTER2_NAME}-cacerts"

create_cacerts_secret() {
  local context=$1
  local cluster=$2
  echo "==> Creating cacerts secret in ${cluster} (context: ${context})..."
  kubectl --context="${context}" create ns istio-system --dry-run=client -o yaml | kubectl --context="${context}" apply -f -
  kubectl --context="${context}" create secret generic cacerts -n istio-system \
    --from-file="${cluster}/ca-cert.pem" \
    --from-file="${cluster}/ca-key.pem" \
    --from-file="${cluster}/root-cert.pem" \
    --from-file="${cluster}/cert-chain.pem" \
    --dry-run=client -o yaml | kubectl --context="${context}" apply -f -
}

create_cacerts_secret "${CLUSTER1_CONTEXT}" "${CLUSTER1_NAME}"
create_cacerts_secret "${CLUSTER2_CONTEXT}" "${CLUSTER2_NAME}"

echo "==> Cleaning up work directory..."
cd "${SCRIPT_DIR}"
rm -rf "${WORK_DIR}"

echo "==> Certificate generation complete."
