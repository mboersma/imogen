#!/usr/bin/env bash
#
# Stand up the imogen CAPZ management cluster: an AKS cluster with workload
# identity, a user-assigned identity CAPZ uses to talk to Azure, and the Cluster
# API + CAPZ controllers (clusterctl init).
#
# All cluster to Azure auth is workload identity, no stored secrets. The AKS
# OIDC issuer federates a UAMI to the capz-manager and ASO service accounts.
#
# Prerequisites: az login with Owner or User Access Administrator on the
# subscription (to grant the UAMI Contributor), plus kubectl and clusterctl.

set -euo pipefail

if [[ -f "$(dirname "$0")/foundation.env" ]]; then
  # shellcheck disable=SC1091
  source "$(dirname "$0")/foundation.env"
fi

# shellcheck source=hack/lib.sh
source "$(dirname "$0")/lib.sh"

DIR="$(cd "$(dirname "$0")/.." && pwd)"

SUBSCRIPTION_ID="${IMOGEN_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
TENANT_ID="${IMOGEN_TENANT_ID:-$(az account show --query tenantId -o tsv)}"
RESOURCE_GROUP="${IMOGEN_RESOURCE_GROUP:-imogen}"
LOCATION="${IMOGEN_MGMT_LOCATION:-${IMOGEN_LOCATION:-westus3}}"
AKS_NAME="${IMOGEN_MGMT_CLUSTER:-imogen-mgmt}"
AKS_NODE_SIZE="${IMOGEN_MGMT_NODE_SIZE:-Standard_B2s_v2}"
AKS_NODE_COUNT="${IMOGEN_MGMT_NODE_COUNT:-2}"
UAMI="${IMOGEN_CAPZ_IDENTITY:-imogen-capz}"

az account set --subscription "$SUBSCRIPTION_ID"

if ! az group show -n "$RESOURCE_GROUP" -o none 2>/dev/null; then
  echo "Creating resource group $RESOURCE_GROUP in $LOCATION"
  az group create -n "$RESOURCE_GROUP" -l "$LOCATION" -o none
fi
imogen_protect_rg "$RESOURCE_GROUP"

if ! az aks show -g "$RESOURCE_GROUP" -n "$AKS_NAME" -o none 2>/dev/null; then
  echo "Checking the requested node size is available in $LOCATION"
  imogen_require_sku "$AKS_NODE_SIZE" "$LOCATION"
  echo "Creating AKS cluster $AKS_NAME (this takes a few minutes)"
  az aks create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$AKS_NAME" \
    --location "$LOCATION" \
    --enable-oidc-issuer \
    --enable-workload-identity \
    --node-count "$AKS_NODE_COUNT" \
    --node-vm-size "$AKS_NODE_SIZE" \
    --generate-ssh-keys \
    --tier free \
    -o none
else
  echo "AKS cluster $AKS_NAME already exists"
fi

# AKS auto-creates a separate node resource group (MC_*), which the reaper sees
# as its own group, so protect it too or the reaper could delete the cluster.
NODE_RG="$(az aks show -g "$RESOURCE_GROUP" -n "$AKS_NAME" --query nodeResourceGroup -o tsv 2>/dev/null || true)"
[[ -n "$NODE_RG" ]] && imogen_protect_rg "$NODE_RG"

echo "Fetching kubeconfig for $AKS_NAME"
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --overwrite-existing
kubectl config use-context "$AKS_NAME"

OIDC_ISSUER="$(az aks show -g "$RESOURCE_GROUP" -n "$AKS_NAME" --query oidcIssuerProfile.issuerUrl -o tsv)"
echo "OIDC issuer: $OIDC_ISSUER"

if ! az identity show -g "$RESOURCE_GROUP" -n "$UAMI" -o none 2>/dev/null; then
  echo "Creating user-assigned identity $UAMI"
  az identity create -g "$RESOURCE_GROUP" -n "$UAMI" -l "$LOCATION" -o none
fi
CLIENT_ID="$(az identity show -g "$RESOURCE_GROUP" -n "$UAMI" --query clientId -o tsv)"
PRINCIPAL_ID="$(az identity show -g "$RESOURCE_GROUP" -n "$UAMI" --query principalId -o tsv)"

echo "Granting $UAMI Contributor on the subscription"
az role assignment create \
  --assignee-object-id "$PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role Contributor \
  --scope "/subscriptions/${SUBSCRIPTION_ID}" \
  -o none 2>/dev/null || echo "  (role assignment already exists)"

# Federate the UAMI to the capz-manager and ASO service accounts so the
# controllers authenticate to Azure with projected tokens, no secrets.
create_fed_cred() {
  local name="$1" subject="$2"
  local existing
  existing="$(az identity federated-credential show --name "$name" \
    --identity-name "$UAMI" -g "$RESOURCE_GROUP" --query issuer -o tsv 2>/dev/null || true)"
  if [[ "$existing" == "$OIDC_ISSUER" ]]; then
    echo "Federated credential $name already up to date"
    return
  fi
  if [[ -n "$existing" ]]; then
    # The OIDC issuer changes when the cluster is recreated, so refresh a stale
    # credential rather than leaving it pointing at the deleted cluster.
    echo "Updating federated credential $name (issuer changed)"
    az identity federated-credential delete \
      --name "$name" --identity-name "$UAMI" -g "$RESOURCE_GROUP" --yes -o none
  else
    echo "Creating federated credential $name"
  fi
  az identity federated-credential create \
    --name "$name" \
    --identity-name "$UAMI" \
    --resource-group "$RESOURCE_GROUP" \
    --issuer "$OIDC_ISSUER" \
    --subject "$subject" \
    --audience api://AzureADTokenExchange \
    -o none
}
create_fed_cred imogen-capz-manager "system:serviceaccount:capz-system:capz-manager"
create_fed_cred imogen-aso "system:serviceaccount:capz-system:azureserviceoperator-default"

echo "Initializing Cluster API + CAPZ"
export AZURE_SUBSCRIPTION_ID="$SUBSCRIPTION_ID"
export EXP_MACHINE_POOL=true
if ! kubectl get deploy -n capz-system capz-controller-manager >/dev/null 2>&1; then
  clusterctl init --infrastructure azure
else
  echo "CAPZ already initialized"
fi

echo "Wiring workload identity into the CAPZ and ASO controllers"
kubectl annotate serviceaccount capz-manager -n capz-system \
  "azure.workload.identity/client-id=${CLIENT_ID}" --overwrite
kubectl annotate serviceaccount azureserviceoperator-default -n capz-system \
  "azure.workload.identity/client-id=${CLIENT_ID}" --overwrite
# The webhook only injects the token for pods labelled use=true, so label the
# controller pod templates and restart them to pick up the projected token.
kubectl patch deployment capz-controller-manager -n capz-system --type merge \
  -p '{"spec":{"template":{"metadata":{"labels":{"azure.workload.identity/use":"true"}}}}}'
kubectl patch deployment azureserviceoperator-controller-manager -n capz-system --type merge \
  -p '{"spec":{"template":{"metadata":{"labels":{"azure.workload.identity/use":"true"}}}}}'
kubectl rollout restart deployment capz-controller-manager azureserviceoperator-controller-manager -n capz-system
kubectl rollout status deployment capz-controller-manager -n capz-system --timeout=180s

echo "Creating the AzureClusterIdentity"
sed -e "s|__CLIENT_ID__|${CLIENT_ID}|" -e "s|__TENANT_ID__|${TENANT_ID}|" \
  "$DIR/deploy/azure-cluster-identity.yaml" | kubectl apply -f -

echo
echo "Management cluster ready. UAMI client id: ${CLIENT_ID}"
echo "Next: hack/setup-builder-cluster.sh to create the builder workload cluster."
