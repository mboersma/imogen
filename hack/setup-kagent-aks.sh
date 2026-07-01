#!/usr/bin/env bash
#
# Deploy kagent and the imogen tool server into the AKS management cluster with
# workload identity, so the Azure-backed tools run in cluster with no secrets.
#
# This is the durable counterpart to hack/setup-kagent.sh (the local kind path).
# It:
#   - builds and pushes the az+kubectl tool server image with `az acr build`
#     (cloud side, so no local cross-architecture build),
#   - creates a user-assigned identity for the tool server, grants it the roles
#     it needs on the imogen resource group, and federates it to the tool server
#     and token-refresher service accounts,
#   - installs kagent, applies the tool server RBAC, Deployment and Service, the
#     ModelConfig, RemoteMCPServer and Agent, and a CronJob that keeps the Azure
#     OpenAI Entra token fresh with workload identity.
#
# Idempotent. Parameterized via IMOGEN_* env vars (see hack/foundation.env.example).
#
# Prerequisites: az login with Owner on the subscription (to create role
# assignments), the AKS management cluster from hack/setup-mgmt-cluster.sh, the
# Azure OpenAI account from hack/setup-openai.sh, and helm.

set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "$DIR/hack/foundation.env" ]]; then
  # shellcheck disable=SC1091
  source "$DIR/hack/foundation.env"
fi

SUBSCRIPTION_ID="${IMOGEN_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
RESOURCE_GROUP="${IMOGEN_RESOURCE_GROUP:-imogen}"
LOCATION="${IMOGEN_LOCATION:-westus3}"
MGMT_CLUSTER="${IMOGEN_MGMT_CLUSTER:-imogen-mgmt}"
MGMT_LOCATION="${IMOGEN_MGMT_LOCATION:-westus3}"
NAMESPACE=kagent

SUB_PREFIX="$(echo "$SUBSCRIPTION_ID" | tr -d '-' | cut -c1-8)"
ACR_NAME="${IMOGEN_TOOLSERVER_ACR:-imogenacr${SUB_PREFIX}}"
TS_IDENTITY="${IMOGEN_TOOLSERVER_IDENTITY:-imogen-toolserver}"
BUILD_IDENTITY="${IMOGEN_BUILDER_IDENTITY:-imogen-builder}"
IMAGE_TAG="${IMOGEN_TOOLSERVER_TAG:-$(git -C "$DIR" rev-parse --short HEAD 2>/dev/null || date +%s)}"

OPENAI_ACCOUNT="${IMOGEN_OPENAI_ACCOUNT:-imogen-openai-$(echo "$SUBSCRIPTION_ID" | cut -c1-8)}"

az account set --subscription "$SUBSCRIPTION_ID"

echo "Getting credentials for $MGMT_CLUSTER"
az aks get-credentials -g "$RESOURCE_GROUP" -n "$MGMT_CLUSTER" --overwrite-existing >/dev/null
OIDC_ISSUER="$(az aks show -g "$RESOURCE_GROUP" -n "$MGMT_CLUSTER" \
  --query oidcIssuerProfile.issuerUrl -o tsv)"

echo "Ensuring container registry $ACR_NAME"
if ! az acr show -n "$ACR_NAME" -o none 2>/dev/null; then
  az acr create -g "$RESOURCE_GROUP" -n "$ACR_NAME" --sku Basic -o none
fi
echo "Attaching $ACR_NAME to $MGMT_CLUSTER"
az aks update -g "$RESOURCE_GROUP" -n "$MGMT_CLUSTER" --attach-acr "$ACR_NAME" -o none 2>/dev/null || \
  echo "  (acr already attached)"

IMAGE="${ACR_NAME}.azurecr.io/imogen-toolserver:${IMAGE_TAG}"
echo "Building and pushing $IMAGE (linux/amd64, cloud side)"
az acr build -r "$ACR_NAME" --platform linux/amd64 -t "imogen-toolserver:${IMAGE_TAG}" "$DIR" >/dev/null

echo "Ensuring tool server identity $TS_IDENTITY"
if ! az identity show -g "$RESOURCE_GROUP" -n "$TS_IDENTITY" -o none 2>/dev/null; then
  az identity create -g "$RESOURCE_GROUP" -n "$TS_IDENTITY" -l "$LOCATION" -o none
fi
TS_CLIENT_ID="$(az identity show -g "$RESOURCE_GROUP" -n "$TS_IDENTITY" --query clientId -o tsv)"
TS_PRINCIPAL_ID="$(az identity show -g "$RESOURCE_GROUP" -n "$TS_IDENTITY" --query principalId -o tsv)"

RG_SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}"
echo "Granting $TS_IDENTITY roles on $RESOURCE_GROUP"
# Contributor on the resource group covers gallery list/promote, image-version
# replication for validation, and creating the ACI build container.
az role assignment create --assignee-object-id "$TS_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal --role Contributor \
  --scope "$RG_SCOPE" -o none 2>/dev/null || echo "  (Contributor already assigned)"
# Data-plane access to the Azure OpenAI account for the token refresher.
if AOAI_SCOPE="$(az cognitiveservices account show -g "$RESOURCE_GROUP" -n "$OPENAI_ACCOUNT" --query id -o tsv 2>/dev/null)"; then
  az role assignment create --assignee-object-id "$TS_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal --role "Cognitive Services OpenAI User" \
    --scope "$AOAI_SCOPE" -o none 2>/dev/null || echo "  (OpenAI User already assigned)"
fi
# Let submit-build-job assign the build identity to the ACI build container.
if BUILD_IDENTITY_ID="$(az identity show -g "$RESOURCE_GROUP" -n "$BUILD_IDENTITY" --query id -o tsv 2>/dev/null)"; then
  az role assignment create --assignee-object-id "$TS_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal --role "Managed Identity Operator" \
    --scope "$BUILD_IDENTITY_ID" -o none 2>/dev/null || echo "  (Managed Identity Operator already assigned)"
fi

echo "Federating $TS_IDENTITY to the tool server and refresher service accounts"
for sa in imogen-toolserver imogen-aoai-refresher; do
  existing="$(az identity federated-credential show --name "$sa" \
    --identity-name "$TS_IDENTITY" -g "$RESOURCE_GROUP" --query issuer -o tsv 2>/dev/null || true)"
  if [[ "$existing" == "$OIDC_ISSUER" ]]; then
    continue
  fi
  if [[ -n "$existing" ]]; then
    # Refresh a stale credential after a cluster rebuild changes the OIDC issuer.
    az identity federated-credential delete --name "$sa" \
      --identity-name "$TS_IDENTITY" -g "$RESOURCE_GROUP" --yes -o none
  fi
  az identity federated-credential create --name "$sa" \
    --identity-name "$TS_IDENTITY" -g "$RESOURCE_GROUP" \
    --issuer "$OIDC_ISSUER" \
    --subject "system:serviceaccount:${NAMESPACE}:${sa}" \
    --audiences api://AzureADTokenExchange -o none
done

echo "Installing kagent"
helm upgrade --install kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
  -n "$NAMESPACE" --create-namespace >/dev/null
# Disable the bundled sample agents and demo MCP servers: imogen only needs its
# own agent and tool server, and the samples would otherwise saturate CPU on the
# small management cluster and leave the imogen agent pod Pending.
helm upgrade --install kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  -n "$NAMESPACE" \
  --set k8s-agent.enabled=false \
  --set kgateway-agent.enabled=false \
  --set istio-agent.enabled=false \
  --set promql-agent.enabled=false \
  --set observability-agent.enabled=false \
  --set argo-rollouts-agent.enabled=false \
  --set helm-agent.enabled=false \
  --set cilium-policy-agent.enabled=false \
  --set cilium-manager-agent.enabled=false \
  --set cilium-debug-agent.enabled=false \
  --set grafana-mcp.enabled=false \
  --set querydoc.enabled=false >/dev/null

echo "Creating the imogen-config ConfigMap"
BUILD_CLIENT_ID="${IMOGEN_BUILDER_CLIENT_ID:-$(az identity show -g "$RESOURCE_GROUP" -n "$BUILD_IDENTITY" --query clientId -o tsv 2>/dev/null || true)}"
kubectl create configmap imogen-config -n "$NAMESPACE" \
  --from-literal=IMOGEN_SUBSCRIPTION_ID="$SUBSCRIPTION_ID" \
  --from-literal=IMOGEN_RESOURCE_GROUP="$RESOURCE_GROUP" \
  --from-literal=IMOGEN_LOCATION="$LOCATION" \
  --from-literal=IMOGEN_STAGING_GALLERY="${IMOGEN_STAGING_GALLERY:-imogen_staging}" \
  --from-literal=IMOGEN_COMMUNITY_GALLERY="${IMOGEN_COMMUNITY_GALLERY:-imogen_community}" \
  --from-literal=IMOGEN_BUILDER_IMAGE="${IMOGEN_BUILDER_IMAGE:-registry.k8s.io/scl-image-builder/cluster-node-image-builder-amd64:v0.1.53}" \
  --from-literal=IMOGEN_BUILDER_CLIENT_ID="$BUILD_CLIENT_ID" \
  --from-literal=IMOGEN_BUILDER_CLUSTER="${IMOGEN_BUILDER_CLUSTER:-imogen-builder}" \
  --from-literal=IMOGEN_BUILDER_LOCATION="${IMOGEN_BUILDER_LOCATION:-$MGMT_LOCATION}" \
  --from-literal=IMOGEN_BUILDER_NODE_SIZE="${IMOGEN_BUILDER_NODE_SIZE:-Standard_B2s_v2}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Applying the tool server"
sed "s|__CLIENT_ID__|${TS_CLIENT_ID}|" "$DIR/deploy/toolserver-rbac.yaml" | kubectl apply -f -
sed "s|__TOOLSERVER_IMAGE__|${IMAGE}|" "$DIR/deploy/toolserver-aks.yaml" | kubectl apply -f -
kubectl apply -f "$DIR/deploy/remotemcpserver.yaml"

echo "Applying the agent and Azure OpenAI ModelConfig"
# The api-key is unused (Entra auth via the Bearer default header) but kagent
# still wires a key secret into the agent deployment, so create a placeholder.
kubectl -n "$NAMESPACE" create secret generic imogen-aoai-key \
  --from-literal=AZUREOPENAI_API_KEY=unused \
  --dry-run=client -o yaml | kubectl apply -f -
echo "Fetching an initial Azure OpenAI token"
TOKEN="$(az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv)"
sed "s|__AZURE_AD_TOKEN__|${TOKEN}|" "$DIR/deploy/modelconfig.yaml" | kubectl apply -f -
kubectl apply -f "$DIR/deploy/agent.yaml"
sed -e "s|__TOOLSERVER_IMAGE__|${IMAGE}|" -e "s|__CLIENT_ID__|${TS_CLIENT_ID}|" \
  "$DIR/deploy/aoai-token-refresher.yaml" | kubectl apply -f -
sed "s|__TOOLSERVER_IMAGE__|${IMAGE}|" "$DIR/deploy/release-watcher.yaml" | kubectl apply -f -

echo "Waiting for the tool server to be ready"
kubectl -n "$NAMESPACE" rollout status deploy/imogen-toolserver --timeout=180s

echo
echo "imogen deployed to $MGMT_CLUSTER with workload identity."
echo "  tool server image: $IMAGE"
echo "  identity:          $TS_IDENTITY ($TS_CLIENT_ID)"
echo "Chat with the agent through the kagent UI:"
echo "  kubectl -n $NAMESPACE port-forward svc/kagent-ui 8080:80"
echo "  open http://localhost:8080"
