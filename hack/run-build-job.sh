#!/usr/bin/env bash
#
# Run an image-builder Azure SIG build as a Kubernetes Job on the CAPZ builder
# cluster, publishing to the staging gallery.
#
# This replaces hack/run-build.sh (the Azure Container Instances stopgap). The
# Job pod authenticates with the build managed identity exposed on the builder
# VMSS through IMDS (no stored secret), so the builder VMSS must have the
# imogen-builder identity assigned (hack/setup-builder-cluster.sh does this).
#
# Usage: hack/run-build-job.sh <flavor> <k8s-version>
#   e.g. hack/run-build-job.sh ubuntu-2404 v1.34.9
#
# Non-blocking: it ensures the pool has a worker, applies the Job, and returns
# the Job name. Follow it with hack/build-status.sh <job> or the get-build-status
# tool.

set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -f "$DIR/hack/foundation.env" ]]; then
  # shellcheck disable=SC1091
  source "$DIR/hack/foundation.env"
fi
# shellcheck source=hack/lib.sh
source "$DIR/hack/lib.sh"

FLAVOR="${1:-}"
VERSION="${2:-}"
if [[ -z "$FLAVOR" || -z "$VERSION" ]]; then
  echo "usage: $0 <flavor> <k8s-version>" >&2
  exit 1
fi

SIG_VERSION="${VERSION#v}"
SEMVER="v${SIG_VERSION}"
SERIES="v${SIG_VERSION%.*}"

SUBSCRIPTION_ID="${IMOGEN_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
LOCATION="${IMOGEN_LOCATION:-westus3}"
RESOURCE_GROUP="${IMOGEN_RESOURCE_GROUP:-imogen}"
STAGING_GALLERY="${IMOGEN_STAGING_GALLERY:-imogen_staging}"
BUILDER_IMAGE="${IMOGEN_BUILDER_IMAGE:-registry.k8s.io/scl-image-builder/cluster-node-image-builder-amd64:v0.1.52}"
MGMT_CLUSTER="${IMOGEN_MGMT_CLUSTER:-imogen-mgmt}"
CLUSTER="${IMOGEN_BUILDER_CLUSTER:-imogen-builder}"
# Namespace the CAPI objects (MachinePool, etc.) live in on the mgmt cluster.
# In cluster the tool server's default namespace is its own (kagent), so the
# MachinePool operations must name the CAPI namespace explicitly.
CAPI_NS="${IMOGEN_CAPI_NAMESPACE:-default}"
IDENTITY="${IMOGEN_BUILDER_IDENTITY:-imogen-builder}"
CLIENT_ID="${IMOGEN_BUILDER_CLIENT_ID:-$(az identity show -g "$RESOURCE_GROUP" -n "$IDENTITY" --query clientId -o tsv)}"

TARGET="build-azure-sig-${FLAVOR}"
NAME="imogen-build-${FLAVOR}-${SIG_VERSION//./-}"
PACKER_FLAGS="--var sig_image_version=${SIG_VERSION} --var kubernetes_semver=${SEMVER} --var kubernetes_series=${SERIES} --var kubernetes_deb_version=${SIG_VERSION}-1.1 --var kubernetes_rpm_version=${SIG_VERSION}"

# Machine pool operations are on the management cluster; on a workstation select
# its context first (in cluster the tool server already runs against it).
if [[ "${IMOGEN_IN_CLUSTER:-}" != "1" ]]; then
  kubectl config use-context "$MGMT_CLUSTER" >/dev/null
fi

# The build pod needs a worker to schedule on, so scale the pool up to at least
# one. This does not wait; the Job pod stays Pending until the node joins.
REPLICAS="$(kubectl get machinepool "${CLUSTER}-mp-0" -n "$CAPI_NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
if [[ "${REPLICAS:-0}" -lt 1 ]]; then
  echo "Scaling builder pool ${CLUSTER}-mp-0 to 1 for the build"
  kubectl scale machinepool "${CLUSTER}-mp-0" -n "$CAPI_NS" --replicas=1 >/dev/null
fi

WL_KUBECONFIG="$(imogen_builder_kubeconfig)"
trap 'rm -f "$WL_KUBECONFIG"' EXIT

echo "Applying build Job $NAME (target $TARGET) to $CLUSTER"
sed \
  -e "s|__NAME__|${NAME}|g" \
  -e "s|__FLAVOR__|${FLAVOR}|g" \
  -e "s|__IMAGE__|${BUILDER_IMAGE}|g" \
  -e "s|__TARGET__|${TARGET}|g" \
  -e "s|__SUBSCRIPTION_ID__|${SUBSCRIPTION_ID}|g" \
  -e "s|__LOCATION__|${LOCATION}|g" \
  -e "s|__CLIENT_ID__|${CLIENT_ID}|g" \
  -e "s|__RESOURCE_GROUP__|${RESOURCE_GROUP}|g" \
  -e "s|__GALLERY__|${STAGING_GALLERY}|g" \
  -e "s|__PACKER_FLAGS__|${PACKER_FLAGS}|g" \
  "$DIR/deploy/build-job.yaml" | kubectl --kubeconfig "$WL_KUBECONFIG" apply -f - >/dev/null

echo "$NAME"
