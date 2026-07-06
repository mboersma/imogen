#!/usr/bin/env bash
#
# Wire up the imogen kagent Agent on a local kind cluster.
#
# This is the local development path. It builds the tool server image, loads it
# into kind, and applies the kagent ModelConfig, RemoteMCPServer, tool server
# Deployment and Agent.
#
# This subscription disallows API-key auth on Azure OpenAI, so the ModelConfig
# authenticates with a short lived Entra ID token that this script fetches and
# injects. The token lasts about an hour; rerun this script to refresh it. On
# AKS this is replaced by workload identity.
#
# Prerequisites: a kind cluster named imogen, kagent installed in the kagent
# namespace, and `az login` with the Cognitive Services OpenAI User role on the
# Azure OpenAI account.

set -euo pipefail

CLUSTER="${IMOGEN_KIND_CLUSTER:-imogen}"
NAMESPACE=kagent
IMAGE="${IMOGEN_TOOLSERVER_IMAGE:-localhost/imogen-toolserver:dev}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"

export KIND_EXPERIMENTAL_PROVIDER="${KIND_EXPERIMENTAL_PROVIDER:-podman}"
CONTAINER_TOOL="${CONTAINER_TOOL:-podman}"

echo "Building and loading $IMAGE into kind/$CLUSTER"
"$CONTAINER_TOOL" build -t "$IMAGE" -f "$DIR/Dockerfile" "$DIR"
ARCHIVE="$(mktemp -t imogen-ts-XXXX).tar"
"$CONTAINER_TOOL" save -o "$ARCHIVE" "$IMAGE"
kind load image-archive "$ARCHIVE" --name "$CLUSTER"
rm -f "$ARCHIVE"

echo "Fetching Entra ID token for Azure OpenAI"
TOKEN="$(az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv)"
# On kind there is no workload identity, so the local ModelConfig talks to the
# real Azure OpenAI account directly and carries the token itself (unlike AKS,
# which fronts the account with the token-injecting proxy). Resolve the endpoint.
if [[ -f "$DIR/hack/foundation.env" ]]; then
  # shellcheck disable=SC1091
  source "$DIR/hack/foundation.env"
fi
SUBSCRIPTION_ID="${IMOGEN_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
OPENAI_ACCOUNT="${IMOGEN_OPENAI_ACCOUNT:-imogen-openai-$(echo "$SUBSCRIPTION_ID" | cut -c1-8)}"
AOAI_ENDPOINT="${IMOGEN_OPENAI_ENDPOINT:-https://${OPENAI_ACCOUNT}.openai.azure.com/}"

echo "Applying manifests"
kubectl apply -f "$DIR/deploy/toolserver.yaml"
kubectl apply -f "$DIR/deploy/remotemcpserver.yaml"
# The api-key is unused (Entra auth via the Authorization header) but kagent
# still wires a key secret into the agent deployment, so create a placeholder.
kubectl -n "$NAMESPACE" create secret generic imogen-aoai-key \
  --from-literal=AZUREOPENAI_API_KEY=unused \
  --dry-run=client -o yaml | kubectl apply -f -
sed "s|__AOAI_ENDPOINT__|${AOAI_ENDPOINT}|" "$DIR/deploy/modelconfig.yaml" | kubectl apply -f -
# Carry the token in defaultHeaders for the direct local path (kagent folds it
# into the agent's config-hash, which is fine on kind).
kubectl -n "$NAMESPACE" patch modelconfig imogen-aoai --type merge \
  -p "{\"spec\":{\"defaultHeaders\":{\"Authorization\":\"Bearer ${TOKEN}\"}}}"
kubectl apply -f "$DIR/deploy/agent.yaml"
# Restart the agent so it picks up the refreshed token.
kubectl -n "$NAMESPACE" rollout restart deploy/imogen 2>/dev/null || true

echo "Waiting for the tool server to be ready"
kubectl -n "$NAMESPACE" rollout status deploy/imogen-toolserver --timeout=120s

echo
echo "imogen agent applied. Chat with it through the kagent UI:"
echo "  kubectl -n $NAMESPACE port-forward svc/kagent-ui 8080:80"
echo "  open http://localhost:8080"
