#!/usr/bin/env bash
#
# Create the user-assigned managed identity that the image build uses.
#
# The build runs image-builder in a container that calls `az login --identity`
# and then provisions a VM with Packer, so the identity needs Contributor on the
# subscription (it creates a temporary resource group for the build VM).
#
# Idempotent. Parameterized via IMOGEN_* env vars. Prints the identity's client
# id and resource id, which the build runner needs.

set -euo pipefail

if [[ -f "$(dirname "$0")/foundation.env" ]]; then
  # shellcheck disable=SC1091
  source "$(dirname "$0")/foundation.env"
fi

SUBSCRIPTION_ID="${IMOGEN_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
RESOURCE_GROUP="${IMOGEN_RESOURCE_GROUP:-imogen}"
LOCATION="${IMOGEN_LOCATION:-westus3}"
IDENTITY="${IMOGEN_BUILDER_IDENTITY:-imogen-builder}"

az account set --subscription "$SUBSCRIPTION_ID"

if ! az identity show -g "$RESOURCE_GROUP" -n "$IDENTITY" -o none 2>/dev/null; then
  az identity create -g "$RESOURCE_GROUP" -n "$IDENTITY" -l "$LOCATION" -o none
  echo "created managed identity $IDENTITY"
fi

PRINCIPAL_ID="$(az identity show -g "$RESOURCE_GROUP" -n "$IDENTITY" --query principalId -o tsv)"
CLIENT_ID="$(az identity show -g "$RESOURCE_GROUP" -n "$IDENTITY" --query clientId -o tsv)"
RESOURCE_ID="$(az identity show -g "$RESOURCE_GROUP" -n "$IDENTITY" --query id -o tsv)"

# Grant Contributor at subscription scope so the build can create the temporary
# resource group and VM that Packer uses. Idempotent.
if ! az role assignment list --assignee "$PRINCIPAL_ID" \
  --scope "/subscriptions/$SUBSCRIPTION_ID" --role Contributor \
  --query "[0]" -o tsv 2>/dev/null | grep -q .; then
  echo "waiting for identity to propagate before role assignment..."
  for _ in $(seq 1 12); do
    if az role assignment create --assignee-object-id "$PRINCIPAL_ID" \
      --assignee-principal-type ServicePrincipal --role Contributor \
      --scope "/subscriptions/$SUBSCRIPTION_ID" -o none 2>/dev/null; then
      echo "granted Contributor to $IDENTITY"
      break
    fi
    sleep 10
  done
fi

echo
echo "IMOGEN_BUILDER_CLIENT_ID=$CLIENT_ID"
echo "IMOGEN_BUILDER_IDENTITY_ID=$RESOURCE_ID"
