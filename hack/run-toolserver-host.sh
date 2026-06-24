#!/usr/bin/env bash
#
# Run the tool server on the host for the local agent demo.
#
# The in-cluster tool server image is distroless and has no az or kubectl, so
# the Azure and builder-cluster tools only work when the binary runs on the
# host with your az login and kubeconfig. This builds and runs it over HTTP and
# allows the kind agent to reach it through host.containers.internal.
#
# Point the RemoteMCPServer at the host first:
#   kubectl -n kagent patch remotemcpserver imogen-toolserver --type merge \
#     -p '{"spec":{"url":"http://host.containers.internal:8080/"}}'
#
# Prerequisites: az login, a kubeconfig context for the management cluster, and
# hack/foundation.env (copy hack/foundation.env.example).

set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
ADDR="${IMOGEN_TOOLSERVER_ADDR:-:8080}"

if [[ -f "$DIR/hack/foundation.env" ]]; then
  # shellcheck disable=SC1091
  set -a && source "$DIR/hack/foundation.env" && set +a
fi

echo "Building the tool server"
go build -o "$DIR/bin/imogen-toolserver" "$DIR/cmd/imogen-toolserver"

echo "Serving MCP over HTTP on $ADDR (reachable as host.containers.internal)"
IMOGEN_TOOLSERVER_ADDR="$ADDR" \
  IMOGEN_TOOLSERVER_ALLOW_REMOTE_HOST=1 \
  exec "$DIR/bin/imogen-toolserver"
