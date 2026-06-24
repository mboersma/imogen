#!/usr/bin/env bash
#
# Remove the imogen kagent resources applied by setup-kagent.sh.
#
# This deletes the Agent, ModelConfig, RemoteMCPServer, tool server and the
# placeholder key secret. It leaves the kind cluster and the kagent install in
# place. Pass --cluster to also delete the kind cluster.

set -euo pipefail

NAMESPACE=kagent
DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER="${IMOGEN_KIND_CLUSTER:-imogen}"
DELETE_CLUSTER=false

if [[ "${1:-}" == "--cluster" ]]; then
  DELETE_CLUSTER=true
fi

export KIND_EXPERIMENTAL_PROVIDER="${KIND_EXPERIMENTAL_PROVIDER:-podman}"

echo "Deleting imogen kagent resources"
kubectl delete -f "$DIR/deploy/agent.yaml" --ignore-not-found
kubectl delete -f "$DIR/deploy/modelconfig.yaml" --ignore-not-found
kubectl delete -f "$DIR/deploy/remotemcpserver.yaml" --ignore-not-found
kubectl delete -f "$DIR/deploy/toolserver.yaml" --ignore-not-found
kubectl -n "$NAMESPACE" delete secret imogen-aoai-key --ignore-not-found

if [[ "$DELETE_CLUSTER" == true ]]; then
  echo "Deleting kind cluster $CLUSTER"
  kind delete cluster --name "$CLUSTER"
fi

echo "Done."
