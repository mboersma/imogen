#!/usr/bin/env bash
#
# Create the CAPZ "builder" workload cluster on the imogen management cluster.
#
# This is a small self-managed cluster with one VMSS MachinePool that runs the
# image-builder Jobs. The pool scales 0..N (see hack/scale-builder.sh). After
# the control plane comes up the script installs a CNI (Calico) and the external
# Azure cloud provider so the nodes become Ready.
#
# Auth is workload identity through the imogen-capz AzureClusterIdentity created
# by hack/setup-mgmt-cluster.sh. Run that first.
#
# Prerequisites: kubectl context pointing at the management cluster, clusterctl,
# helm, and the IMOGEN_CAPZ_CLIENT_ID of the UAMI (printed by the mgmt setup).

set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -f "$(dirname "$0")/foundation.env" ]]; then
  # shellcheck disable=SC1091
  source "$(dirname "$0")/foundation.env"
fi

# shellcheck source=hack/lib.sh
source "$(dirname "$0")/lib.sh"

SUBSCRIPTION_ID="${IMOGEN_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
TENANT_ID="${IMOGEN_TENANT_ID:-$(az account show --query tenantId -o tsv)}"
RESOURCE_GROUP="${IMOGEN_RESOURCE_GROUP:-imogen}"
LOCATION="${IMOGEN_MGMT_LOCATION:-${IMOGEN_LOCATION:-eastus2}}"
MGMT_CLUSTER="${IMOGEN_MGMT_CLUSTER:-imogen-mgmt}"
UAMI="${IMOGEN_CAPZ_IDENTITY:-imogen-capz}"
CLUSTER="${IMOGEN_BUILDER_CLUSTER:-imogen-builder}"
# The builder cluster also validates images, so its control plane must be at the
# newest Kubernetes minor in scope: a node (kubelet) may run up to two minors
# behind the control plane (kube-apiserver) but never ahead, so a control plane
# at the newest minor can validate that minor and the supported older ones from a
# single cluster. Track the newest CAPI reference image version (the community
# gallery capi-ubun2-* definitions), since the control plane boots from it.
K8S_VERSION="${IMOGEN_BUILDER_K8S_VERSION:-v1.36.2}"
# Default to broadly available v2 sizes. Some subscriptions and regions restrict
# older sizes (Standard_B2s, D2s_v3); imogen_require_sku below fails fast with the
# available sizes if these are not offered. Override via IMOGEN_BUILDER_*_SIZE.
CP_SIZE="${IMOGEN_BUILDER_CP_SIZE:-Standard_B2s_v2}"
NODE_SIZE="${IMOGEN_BUILDER_NODE_SIZE:-Standard_B2s_v2}"
WORKERS="${IMOGEN_BUILDER_WORKERS:-1}"
CALICO_VERSION="${IMOGEN_CALICO_VERSION:-v3.29.7}"
# How long the Machine controller spends draining/deleting a node before giving
# up, so teardown is not blocked by nodes Azure has already deallocated.
DRAIN_TIMEOUT_SECONDS="${IMOGEN_BUILDER_DRAIN_TIMEOUT_SECONDS:-120}"
# cluster-autoscaler scales the builder MachinePool 0..MAX_NODES on demand. The
# image matches the AKS management cluster minor.
MAX_NODES="${IMOGEN_BUILDER_MAX_NODES:-3}"
AUTOSCALER_IMAGE="${IMOGEN_AUTOSCALER_IMAGE:-registry.k8s.io/autoscaling/cluster-autoscaler:v1.34.0}"

CLIENT_ID="${IMOGEN_CAPZ_CLIENT_ID:-$(az identity show -g "$RESOURCE_GROUP" -n "$UAMI" --query clientId -o tsv)}"

kubectl config use-context "$MGMT_CLUSTER"

echo "Checking the requested VM sizes are available in $LOCATION"
imogen_require_sku "$CP_SIZE" "$LOCATION"
imogen_require_sku "$NODE_SIZE" "$LOCATION"

echo "Generating and applying the $CLUSTER workload cluster"
if kubectl get cluster "$CLUSTER" >/dev/null 2>&1; then
  echo "Cluster $CLUSTER already exists, skipping generation"
else
  AZURE_SUBSCRIPTION_ID="$SUBSCRIPTION_ID" \
  AZURE_TENANT_ID="$TENANT_ID" \
  AZURE_LOCATION="$LOCATION" \
  AZURE_CONTROL_PLANE_MACHINE_TYPE="$CP_SIZE" \
  AZURE_NODE_MACHINE_TYPE="$NODE_SIZE" \
  AZURE_CLIENT_ID_USER_ASSIGNED_IDENTITY="$CLIENT_ID" \
  AZURE_RESOURCE_GROUP="$CLUSTER" \
  CLUSTER_IDENTITY_NAME="$UAMI" \
  CLUSTER_NAME="$CLUSTER" \
  KUBERNETES_VERSION="$K8S_VERSION" \
  WORKER_MACHINE_COUNT="$WORKERS" \
  CI_RG="$RESOURCE_GROUP" \
  USER_IDENTITY="$UAMI" \
    clusterctl generate cluster "$CLUSTER" --infrastructure azure --flavor machinepool \
    | kubectl apply -f -
fi

# Bound node drain/deletion so teardown is not blocked by nodes Azure has
# deallocated. Patched on the live objects (served v1beta2) so it works whatever
# apiVersion the flavor template generated, and on re-runs of an existing cluster.
echo "Setting node drain/deletion timeouts (${DRAIN_TIMEOUT_SECONDS}s)"
kubectl patch "kubeadmcontrolplane/${CLUSTER}-control-plane" --type merge -p \
  "{\"spec\":{\"machineTemplate\":{\"spec\":{\"deletion\":{\"nodeDrainTimeoutSeconds\":${DRAIN_TIMEOUT_SECONDS},\"nodeVolumeDetachTimeoutSeconds\":${DRAIN_TIMEOUT_SECONDS}}}}}}"
kubectl patch "machinepool/${CLUSTER}-mp-0" --type merge -p \
  "{\"spec\":{\"template\":{\"spec\":{\"deletion\":{\"nodeDrainTimeoutSeconds\":${DRAIN_TIMEOUT_SECONDS},\"nodeVolumeDetachTimeoutSeconds\":${DRAIN_TIMEOUT_SECONDS}}}}}}"

# Annotate the MachinePool for cluster-autoscaler: min/max group size and, since
# the pool can sit at zero, the node capacity so the autoscaler can size a pod
# against a node that does not exist yet. Capacity comes from the VM SKU unless
# overridden.
NODE_CPU="${IMOGEN_BUILDER_NODE_CPU:-}"
NODE_MEM_MIB="${IMOGEN_BUILDER_NODE_MEMORY_MIB:-}"
if [[ -z "$NODE_CPU" || -z "$NODE_MEM_MIB" ]]; then
  CAPS_JSON="$(az vm list-skus -l "$LOCATION" --size "$NODE_SIZE" \
    --query "[?name=='${NODE_SIZE}'].capabilities[]" -o json)"
  NODE_CPU="${NODE_CPU:-$(echo "$CAPS_JSON" | python3 -c 'import sys,json; c={x["name"]:x["value"] for x in json.load(sys.stdin)}; print(c["vCPUs"])')}"
  NODE_MEM_MIB="${NODE_MEM_MIB:-$(echo "$CAPS_JSON" | python3 -c 'import sys,json; c={x["name"]:x["value"] for x in json.load(sys.stdin)}; print(int(float(c["MemoryGB"])*1024))')}"
fi
echo "Annotating ${CLUSTER}-mp-0 for autoscaling (0..${MAX_NODES}, ${NODE_CPU} vCPU / ${NODE_MEM_MIB}Mi)"
kubectl annotate "machinepool/${CLUSTER}-mp-0" --overwrite \
  cluster.x-k8s.io/cluster-api-autoscaler-node-group-min-size="0" \
  cluster.x-k8s.io/cluster-api-autoscaler-node-group-max-size="${MAX_NODES}" \
  capacity.cluster-autoscaler.kubernetes.io/cpu="${NODE_CPU}" \
  capacity.cluster-autoscaler.kubernetes.io/memory="${NODE_MEM_MIB}Mi"

echo "Waiting for the control plane to initialize (a few minutes)"
if ! kubectl wait --for=condition=Initialized "kubeadmcontrolplane/${CLUSTER}-control-plane" --timeout=900s; then
  echo "Control plane did not initialize in time. Check 'kubectl get cluster,azurecluster,kubeadmcontrolplane'." >&2
  exit 1
fi

WL_KUBECONFIG="$(mktemp -t imogen-builder-kubeconfig-XXXX)"
clusterctl get kubeconfig "$CLUSTER" > "$WL_KUBECONFIG"
echo "Workload kubeconfig written to $WL_KUBECONFIG"

echo "Installing Calico CNI"
helm repo add projectcalico https://docs.tigera.io/calico/charts >/dev/null 2>&1 || true
helm repo update projectcalico >/dev/null
helm --kubeconfig "$WL_KUBECONFIG" upgrade --install calico projectcalico/tigera-operator \
  --version "$CALICO_VERSION" \
  -f "$DIR/deploy/calico-values.yaml" \
  --namespace tigera-operator --create-namespace

echo "Installing the external Azure cloud provider"
helm --kubeconfig "$WL_KUBECONFIG" upgrade --install cloud-provider-azure \
  --repo https://raw.githubusercontent.com/kubernetes-sigs/cloud-provider-azure/master/helm/repo cloud-provider-azure \
  --set infra.clusterName="$CLUSTER" \
  --set "cloudControllerManager.clusterCIDR=192.168.0.0/16"

echo "Waiting for nodes to become Ready (control plane + $WORKERS worker(s))"
EXPECTED_NODES=$((1 + WORKERS))
deadline=$((SECONDS + 600))
while true; do
  ready="$(kubectl --kubeconfig "$WL_KUBECONFIG" get nodes \
    -o jsonpath='{range .items[*]}{range @.status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' 2>/dev/null \
    | grep -c '^True' || true)"
  if [[ "$ready" -ge "$EXPECTED_NODES" ]]; then
    echo "All $EXPECTED_NODES node(s) Ready"
    break
  fi
  if [[ "$SECONDS" -ge "$deadline" ]]; then
    echo "Only $ready/$EXPECTED_NODES node(s) Ready after timeout:" >&2
    kubectl --kubeconfig "$WL_KUBECONFIG" get nodes >&2
    break
  fi
  sleep 15
done

# Assign the build managed identity to the worker VMSS so image-builder Jobs can
# authenticate with it through IMDS (no stored secret). Best effort: the build
# identity comes from hack/setup-build-identity.sh. The assignment is additive,
# so it does not disturb other identities on the VMSS.
BUILD_IDENTITY="${IMOGEN_BUILDER_IDENTITY:-imogen-builder}"
if BUILD_IDENTITY_ID="$(az identity show -g "$RESOURCE_GROUP" -n "$BUILD_IDENTITY" --query id -o tsv 2>/dev/null)"; then
  echo "Assigning the build identity $BUILD_IDENTITY to the worker VMSS"
  az vmss identity assign -g "$CLUSTER" -n "${CLUSTER}-mp-0" \
    --identities "$BUILD_IDENTITY_ID" -o none 2>/dev/null || \
    echo "  (could not assign; scale the pool up once, then rerun)"
else
  echo "Build identity $BUILD_IDENTITY not found; run hack/setup-build-identity.sh before building"
fi

# Deploy cluster-autoscaler on the management cluster. It watches the builder
# workload cluster through the CAPI-generated admin kubeconfig secret and scales
# the MachinePool 0..MAX_NODES from pending build pods. Re-applying is idempotent;
# restart it so it re-reads the kubeconfig if the cluster was recreated.
KUBECONFIG_SECRET="${CLUSTER}-kubeconfig"
echo "Deploying cluster-autoscaler (image $AUTOSCALER_IMAGE)"
sed \
  -e "s|__NS__|default|g" \
  -e "s|__CLUSTER__|${CLUSTER}|g" \
  -e "s|__AUTOSCALER_IMAGE__|${AUTOSCALER_IMAGE}|g" \
  -e "s|__KUBECONFIG_SECRET__|${KUBECONFIG_SECRET}|g" \
  "$DIR/deploy/cluster-autoscaler.yaml" | kubectl apply -f -
kubectl -n default rollout restart deploy/cluster-autoscaler >/dev/null 2>&1 || true

echo
echo "Builder cluster $CLUSTER is up. Workload kubeconfig: $WL_KUBECONFIG"
echo "cluster-autoscaler scales ${CLUSTER}-mp-0 0..${MAX_NODES} on demand."
echo "Scale the build pool manually with: hack/scale-builder.sh <count>"