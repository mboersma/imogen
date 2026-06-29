#!/usr/bin/env bash
#
# Tear down the CAPZ builder workload cluster, and optionally the management
# cluster.
#
# Deleting the Cluster object lets CAPZ remove all the Azure resources it
# created (resource group, VMs, VMSS, network). When Azure has already
# deallocated the nodes, graceful deletion can stall on draining unreachable
# nodes and the control-plane pre-terminate hook, so this falls back to deleting
# the workload resource group directly and clearing leftover finalizers.
#
# Pass --mgmt to also delete the AKS management cluster.

set -euo pipefail

if [[ -f "$(dirname "$0")/foundation.env" ]]; then
  # shellcheck disable=SC1091
  source "$(dirname "$0")/foundation.env"
fi

RESOURCE_GROUP="${IMOGEN_RESOURCE_GROUP:-imogen}"
MGMT_CLUSTER="${IMOGEN_MGMT_CLUSTER:-imogen-mgmt}"
CLUSTER="${IMOGEN_BUILDER_CLUSTER:-imogen-builder}"
# The workload cluster's own Azure resource group (AZURE_RESOURCE_GROUP in
# setup-builder-cluster.sh defaults to the cluster name).
WORKLOAD_RG="${IMOGEN_BUILDER_RESOURCE_GROUP:-$CLUSTER}"
# How long to wait for graceful deletion before forcing.
GRACE_SECONDS="${IMOGEN_TEARDOWN_GRACE_SECONDS:-180}"
DELETE_MGMT=false

if [[ "${1:-}" == "--mgmt" ]]; then
  DELETE_MGMT=true
fi

# CAPI object kinds for the cluster, child-first so owners are cleared last.
CLUSTER_KINDS=(
  machine machinepool
  azuremachine azuremachinepool azuremachinetemplate
  kubeadmcontrolplane kubeadmconfig kubeadmconfigtemplate
  azurecluster cluster
)

kubectl config use-context "$MGMT_CLUSTER" >/dev/null

echo "Removing cluster-autoscaler for $CLUSTER"
kubectl -n default delete deployment,serviceaccount -l app=cluster-autoscaler --ignore-not-found >/dev/null 2>&1 || true
kubectl delete clusterrole,clusterrolebinding imogen-cluster-autoscaler --ignore-not-found >/dev/null 2>&1 || true

echo "Deleting workload cluster $CLUSTER (CAPZ removes its Azure resources)"
kubectl delete cluster "$CLUSTER" --ignore-not-found --wait=false

echo "Waiting up to ${GRACE_SECONDS}s for graceful deletion"
deadline=$((SECONDS + GRACE_SECONDS))
while kubectl get cluster "$CLUSTER" >/dev/null 2>&1; do
  if [[ "$SECONDS" -ge "$deadline" ]]; then
    echo "Graceful deletion stalled (nodes likely deallocated); forcing cleanup"
    if az group show -n "$WORKLOAD_RG" -o none 2>/dev/null; then
      echo "Deleting workload resource group $WORKLOAD_RG"
      az group delete -n "$WORKLOAD_RG" --yes --no-wait
    fi
    echo "Clearing finalizers on any leftover CAPI objects for $CLUSTER"
    for kind in "${CLUSTER_KINDS[@]}"; do
      while read -r name; do
        [[ -z "$name" ]] && continue
        kubectl patch "$kind" "$name" --type merge \
          -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
      done < <(kubectl get "$kind" -o name 2>/dev/null \
        | sed 's#.*/##' | grep -E "^${CLUSTER}(\$|-)" || true)
    done
    break
  fi
  sleep 10
done

echo "Verifying no leftover builder objects remain"
leftover=0
for kind in "${CLUSTER_KINDS[@]}"; do
  remaining="$(kubectl get "$kind" -o name 2>/dev/null \
    | sed 's#.*/##' | grep -cE "^${CLUSTER}(\$|-)" || true)"
  if [[ "$remaining" -gt 0 ]]; then
    echo "  WARNING: $remaining $kind object(s) still present" >&2
    leftover=$((leftover + remaining))
  fi
done
if [[ "$leftover" -eq 0 ]]; then
  echo "Workload cluster $CLUSTER fully removed"
fi

if [[ "$DELETE_MGMT" == true ]]; then
  echo "Deleting AKS management cluster $MGMT_CLUSTER"
  az aks delete -g "$RESOURCE_GROUP" -n "$MGMT_CLUSTER" --yes
fi

echo "Done."
