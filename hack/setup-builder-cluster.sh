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

SUBSCRIPTION_ID="${IMOGEN_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
TENANT_ID="${IMOGEN_TENANT_ID:-$(az account show --query tenantId -o tsv)}"
RESOURCE_GROUP="${IMOGEN_RESOURCE_GROUP:-imogen}"
LOCATION="${IMOGEN_MGMT_LOCATION:-${IMOGEN_LOCATION:-eastus2}}"
MGMT_CLUSTER="${IMOGEN_MGMT_CLUSTER:-imogen-mgmt}"
UAMI="${IMOGEN_CAPZ_IDENTITY:-imogen-capz}"
CLUSTER="${IMOGEN_BUILDER_CLUSTER:-imogen-builder}"
K8S_VERSION="${IMOGEN_BUILDER_K8S_VERSION:-v1.34.8}"
CP_SIZE="${IMOGEN_BUILDER_CP_SIZE:-Standard_B2s}"
NODE_SIZE="${IMOGEN_BUILDER_NODE_SIZE:-Standard_D2s_v3}"
WORKERS="${IMOGEN_BUILDER_WORKERS:-1}"
CALICO_VERSION="${IMOGEN_CALICO_VERSION:-v3.29.7}"

CLIENT_ID="${IMOGEN_CAPZ_CLIENT_ID:-$(az identity show -g "$RESOURCE_GROUP" -n "$UAMI" --query clientId -o tsv)}"

kubectl config use-context "$MGMT_CLUSTER"

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

echo "Waiting for nodes to become Ready"
kubectl --kubeconfig "$WL_KUBECONFIG" wait --for=condition=Ready nodes --all --timeout=600s || \
  kubectl --kubeconfig "$WL_KUBECONFIG" get nodes

echo
echo "Builder cluster $CLUSTER is up. Workload kubeconfig: $WL_KUBECONFIG"
echo "Scale the build pool with: hack/scale-builder.sh <count>"
