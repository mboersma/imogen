#!/usr/bin/env bash
#
# Delete the imogen Azure foundation by removing its resource group.
# Useful for tearing down dev resources. Parameterized via IMOGEN_* env vars.

set -euo pipefail

if [[ -f "$(dirname "$0")/foundation.env" ]]; then
  # shellcheck disable=SC1091
  source "$(dirname "$0")/foundation.env"
fi

RESOURCE_GROUP="${IMOGEN_RESOURCE_GROUP:-imogen}"

if [[ -n "${IMOGEN_SUBSCRIPTION_ID:-}" ]]; then
  az account set --subscription "$IMOGEN_SUBSCRIPTION_ID"
fi

echo "Deleting resource group $RESOURCE_GROUP and everything in it."
az group delete -n "$RESOURCE_GROUP" --yes
echo "done"
