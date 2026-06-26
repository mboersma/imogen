#!/usr/bin/env bash
#
# Validate a staging gallery image by booting a node from it on the builder
# cluster and asserting it joins, runs the expected kubelet, and can run a pod.
#
# This attaches a one-node MachineDeployment to the builder workload cluster
# whose image points at the staging gallery version, waits for the node to be
# Ready, checks the kubelet version, runs a smoke pod, then tears it all down.
#
# Usage: hack/validate-image.sh <flavor> <version>
#   e.g. hack/validate-image.sh ubuntu-2404 1.34.9
#
# Set IMOGEN_VALIDATE_KEEP=1 to leave the validation node up for inspection.

set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -f "$(dirname "$0")/foundation.env" ]]; then
  # shellcheck disable=SC1091
  source "$(dirname "$0")/foundation.env"
fi

FLAVOR="${1:-}"
VERSION="${2:-}"
if [[ -z "$FLAVOR" || -z "$VERSION" ]]; then
  echo "usage: $0 <flavor> <version>" >&2
  exit 1
fi

SUBSCRIPTION_ID="${IMOGEN_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
RESOURCE_GROUP="${IMOGEN_RESOURCE_GROUP:-imogen}"
STAGING_GALLERY="${IMOGEN_STAGING_GALLERY:-imogen_staging}"
GALLERY_LOCATION="${IMOGEN_LOCATION:-westus3}"
MGMT_CLUSTER="${IMOGEN_MGMT_CLUSTER:-imogen-mgmt}"
CLUSTER="${IMOGEN_BUILDER_CLUSTER:-imogen-builder}"
BUILDER_LOCATION="${IMOGEN_BUILDER_LOCATION:-${IMOGEN_MGMT_LOCATION:-eastus2}}"
NODE_SIZE="${IMOGEN_BUILDER_NODE_SIZE:-Standard_D2s_v3}"

IMAGE_VERSION="${VERSION#v}"
K8S_VERSION="v${IMAGE_VERSION}"
IMAGE_DEFINITION="capi-${FLAVOR}"
NAME="${CLUSTER}-validate"

# The image must be replicated to the builder cluster's region. The build
# publishes to the gallery's home region, so add the builder region if missing.
echo "Checking image replication to ${BUILDER_LOCATION}"
HAVE="$(az sig image-version show -g "$RESOURCE_GROUP" -r "$STAGING_GALLERY" \
  -i "$IMAGE_DEFINITION" -e "$IMAGE_VERSION" \
  --query "publishingProfile.targetRegions[].name" -o tsv | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
WANT="$(echo "$BUILDER_LOCATION" | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
if ! grep -qx "$WANT" <<<"$HAVE"; then
  echo "Replicating ${IMAGE_DEFINITION} ${IMAGE_VERSION} to ${BUILDER_LOCATION} (a few minutes)"
  az sig image-version update -g "$RESOURCE_GROUP" -r "$STAGING_GALLERY" \
    -i "$IMAGE_DEFINITION" -e "$IMAGE_VERSION" \
    --target-regions "$GALLERY_LOCATION" "$BUILDER_LOCATION" -o none
fi

# In cluster the tool server already runs against the management cluster via its
# service account, so there is no kubeconfig context to select and clusterctl is
# not bundled in the image. Read the builder kubeconfig from the CAPI secret
# instead. On a workstation, keep using the named context and clusterctl.
WL_KUBECONFIG="$(mktemp -t imogen-validate-kubeconfig-XXXX)"
if [[ "${IMOGEN_IN_CLUSTER:-}" == "1" ]]; then
  kubectl get secret "${CLUSTER}-kubeconfig" -n "${IMOGEN_BUILDER_KUBECONFIG_NAMESPACE:-default}" \
    -o jsonpath='{.data.value}' | base64 -d > "$WL_KUBECONFIG"
else
  kubectl config use-context "$MGMT_CLUSTER" >/dev/null
  clusterctl get kubeconfig "$CLUSTER" > "$WL_KUBECONFIG"
fi

cleanup() {
  if [[ "${IMOGEN_VALIDATE_KEEP:-}" == "1" ]]; then
    echo "IMOGEN_VALIDATE_KEEP set, leaving $NAME in place"
    echo "Workload kubeconfig: $WL_KUBECONFIG"
    return
  fi
  echo "Tearing down $NAME"
  kubectl --kubeconfig "$WL_KUBECONFIG" delete pod "${NAME}-smoke" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete machinedeployment "$NAME" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete kubeadmconfigtemplate "$NAME" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete azuremachinetemplate "$NAME" --ignore-not-found >/dev/null 2>&1 || true
  rm -f "$WL_KUBECONFIG"
}
trap cleanup EXIT

echo "Validating ${IMAGE_DEFINITION} ${IMAGE_VERSION} from ${STAGING_GALLERY}"
sed \
  -e "s|__NAME__|${NAME}|g" \
  -e "s|__CLUSTER__|${CLUSTER}|g" \
  -e "s|__K8S_VERSION__|${K8S_VERSION}|g" \
  -e "s|__VM_SIZE__|${NODE_SIZE}|g" \
  -e "s|__SUBSCRIPTION_ID__|${SUBSCRIPTION_ID}|g" \
  -e "s|__RESOURCE_GROUP__|${RESOURCE_GROUP}|g" \
  -e "s|__GALLERY__|${STAGING_GALLERY}|g" \
  -e "s|__IMAGE_DEFINITION__|${IMAGE_DEFINITION}|g" \
  -e "s|__IMAGE_VERSION__|${IMAGE_VERSION}|g" \
  "$DIR/deploy/validation-machinedeployment.yaml" | kubectl apply -f -

echo "Waiting for the validation machine to get a node (this boots a VM)"
NODE=""
for _ in $(seq 1 60); do
  NODE="$(kubectl get machines -l "cluster.x-k8s.io/deployment-name=${NAME}" \
    -o jsonpath='{.items[0].status.nodeRef.name}' 2>/dev/null || true)"
  [[ -n "$NODE" ]] && break
  sleep 15
done
if [[ -z "$NODE" ]]; then
  echo "FAIL: validation machine never registered a node" >&2
  exit 1
fi
echo "Node: $NODE"

echo "Waiting for $NODE to be Ready"
if ! kubectl --kubeconfig "$WL_KUBECONFIG" wait --for=condition=Ready "node/${NODE}" --timeout=600s; then
  echo "FAIL: $NODE did not become Ready" >&2
  exit 1
fi

KUBELET="$(kubectl --kubeconfig "$WL_KUBECONFIG" get node "$NODE" -o jsonpath='{.status.nodeInfo.kubeletVersion}')"
RUNTIME="$(kubectl --kubeconfig "$WL_KUBECONFIG" get node "$NODE" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}')"
echo "kubelet:  $KUBELET (expected $K8S_VERSION)"
echo "runtime:  $RUNTIME"
if [[ "$KUBELET" != "$K8S_VERSION" ]]; then
  echo "FAIL: kubelet version $KUBELET does not match expected $K8S_VERSION" >&2
  exit 1
fi
if [[ "$RUNTIME" != containerd://* ]]; then
  echo "FAIL: unexpected container runtime $RUNTIME" >&2
  exit 1
fi

echo "Running a smoke pod on $NODE"
# hostNetwork so the smoke does not wait on the CNI initializing on the fresh
# node; we are validating the image's kubelet and containerd, not pod networking.
kubectl --kubeconfig "$WL_KUBECONFIG" run "${NAME}-smoke" \
  --image=registry.k8s.io/busybox:1.27 --restart=Never \
  --overrides="{\"spec\":{\"nodeName\":\"${NODE}\",\"hostNetwork\":true,\"tolerations\":[{\"operator\":\"Exists\"}]}}" \
  --command -- /bin/sh -c 'echo smoke-ok'
if ! kubectl --kubeconfig "$WL_KUBECONFIG" wait --for=jsonpath='{.status.phase}'=Succeeded \
  "pod/${NAME}-smoke" --timeout=120s; then
  echo "FAIL: smoke pod did not succeed" >&2
  kubectl --kubeconfig "$WL_KUBECONFIG" describe pod "${NAME}-smoke" >&2 || true
  exit 1
fi

echo
echo "PASS: ${IMAGE_DEFINITION} ${IMAGE_VERSION} booted, ran kubelet ${KUBELET}, and scheduled a pod."
