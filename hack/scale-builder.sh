#!/usr/bin/env bash
#
# Imperatively scale the builder cluster's VMSS MachinePool.
#
# Scale to 0 when idle and up to N when a build is queued. Runs against the
# management cluster, which reconciles the underlying Azure VMSS.
#
# Usage: hack/scale-builder.sh <count>
#   e.g. hack/scale-builder.sh 0   # idle
#        hack/scale-builder.sh 2   # two build nodes

set -euo pipefail

if [[ -f "$(dirname "$0")/foundation.env" ]]; then
  # shellcheck disable=SC1091
  source "$(dirname "$0")/foundation.env"
fi

MGMT_CLUSTER="${IMOGEN_MGMT_CLUSTER:-imogen-mgmt}"
CLUSTER="${IMOGEN_BUILDER_CLUSTER:-imogen-builder}"
POOL="${IMOGEN_BUILDER_POOL:-${CLUSTER}-mp-0}"

COUNT="${1:-}"
if [[ -z "$COUNT" ]]; then
  echo "usage: $0 <count>" >&2
  exit 1
fi

kubectl config use-context "$MGMT_CLUSTER" >/dev/null
kubectl scale machinepool "$POOL" --replicas="$COUNT"
echo "Scaling $POOL to $COUNT. Watch with:"
echo "  kubectl get machinepool $POOL -w"
