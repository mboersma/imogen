#!/usr/bin/env bash
#
# Create the Azure OpenAI resource the imogen agent uses, deploy a chat model,
# and grant the signed-in user data-plane access.
#
# This subscription disallows API-key (local) auth on Cognitive Services, so the
# account is created with disableLocalAuth and the agent authenticates with
# Entra ID. The account is created through an ARM template because the CLI
# cannot set disableLocalAuth at create time.
#
# Idempotent. Parameterized via IMOGEN_* env vars.

set -euo pipefail

if [[ -f "$(dirname "$0")/foundation.env" ]]; then
  # shellcheck disable=SC1091
  source "$(dirname "$0")/foundation.env"
fi

SUBSCRIPTION_ID="${IMOGEN_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
RESOURCE_GROUP="${IMOGEN_RESOURCE_GROUP:-imogen}"
LOCATION="${IMOGEN_OPENAI_LOCATION:-eastus2}"
ACCOUNT="${IMOGEN_OPENAI_ACCOUNT:-imogen-openai-$(echo "$SUBSCRIPTION_ID" | cut -c1-8)}"
DEPLOYMENT="${IMOGEN_OPENAI_DEPLOYMENT:-gpt-4.1-mini}"
MODEL="${IMOGEN_OPENAI_MODEL:-gpt-4.1-mini}"
MODEL_VERSION="${IMOGEN_OPENAI_MODEL_VERSION:-2025-04-14}"
CAPACITY="${IMOGEN_OPENAI_CAPACITY:-200}"

az account set --subscription "$SUBSCRIPTION_ID"

TEMPLATE="$(mktemp -t imogen-aoai-XXXX).json"
cat >"$TEMPLATE" <<'JSON'
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "name": {"type": "string"},
    "location": {"type": "string"}
  },
  "resources": [
    {
      "type": "Microsoft.CognitiveServices/accounts",
      "apiVersion": "2024-10-01",
      "name": "[parameters('name')]",
      "location": "[parameters('location')]",
      "kind": "OpenAI",
      "sku": {"name": "S0"},
      "identity": {"type": "SystemAssigned"},
      "properties": {
        "customSubDomainName": "[parameters('name')]",
        "disableLocalAuth": true,
        "publicNetworkAccess": "Enabled"
      }
    }
  ],
  "outputs": {
    "endpoint": {"type": "string", "value": "[reference(parameters('name')).endpoint]"}
  }
}
JSON

echo "Creating Azure OpenAI account $ACCOUNT in $LOCATION"
ENDPOINT="$(az deployment group create -g "$RESOURCE_GROUP" -n imogen-aoai \
  --template-file "$TEMPLATE" \
  --parameters name="$ACCOUNT" location="$LOCATION" \
  --query "properties.outputs.endpoint.value" -o tsv)"
rm -f "$TEMPLATE"

echo "Deploying model $DEPLOYMENT ($MODEL $MODEL_VERSION)"
if ! az cognitiveservices account deployment show -g "$RESOURCE_GROUP" -n "$ACCOUNT" \
  --deployment-name "$DEPLOYMENT" -o none 2>/dev/null; then
  az cognitiveservices account deployment create -g "$RESOURCE_GROUP" -n "$ACCOUNT" \
    --deployment-name "$DEPLOYMENT" \
    --model-name "$MODEL" --model-version "$MODEL_VERSION" --model-format OpenAI \
    --sku-name GlobalStandard --sku-capacity "$CAPACITY" -o none
fi

echo "Granting Cognitive Services OpenAI User to the signed-in user"
ME="$(az ad signed-in-user show --query id -o tsv)"
SCOPE="$(az cognitiveservices account show -g "$RESOURCE_GROUP" -n "$ACCOUNT" --query id -o tsv)"
az role assignment create --assignee-object-id "$ME" --assignee-principal-type User \
  --role "Cognitive Services OpenAI User" --scope "$SCOPE" -o none 2>/dev/null || true

echo
echo "Azure OpenAI ready."
echo "  endpoint:   $ENDPOINT"
echo "  deployment: $DEPLOYMENT"
echo "Set these in deploy/modelconfig.yaml if they differ from the defaults."
