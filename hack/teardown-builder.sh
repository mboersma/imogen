#!/usr/bin/env bash
#
# Tear down the CAPZ builder workload cluster, and optionally the management
# cluster.
#
# Deleting the Cluster object lets CAPZ remove all the Azure resources it
# created (resource group, VMs, VMSS, network). Pass --mgmt to also delete the
# AKS management cluster.

set -euo pipefail

if [[ -f "$(dirname "$0")/foundation.env" ]]; then
  # shellcheck disable=SC1091
  source "$(dirname "$0")/foundation.env"
fi

RESOURCE_GROUP="${IMOGEN_RESOURCE_GROUP:-imogen}"
MGMT_CLUSTER="${IMOGEN_MGMT_CLUSTER:-imogen-mgmt}"
CLUSTER="${IMOGEN_BUILDER_CLUSTER:-imogen-builder}"
DELETE_MGMT=false

if [[ "${1:-}" == "--mgmt" ]]; then
  DELETE_MGMT=true
fi

kubectl config use-context "$MGMT_CLUSTER" >/dev/null

echo "Deleting workload cluster $CLUSTER (CAPZ removes its Azure resources)"
kubectl delete cluster "$CLUSTER" --ignore-not-found --wait=true

if [[ "$DELETE_MGMT" == true ]]; then
  echo "Deleting AKS management cluster $MGMT_CLUSTER"
  az aks delete -g "$RESOURCE_GROUP" -n "$MGMT_CLUSTER" --yes
fi

echo "Done."
