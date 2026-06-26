#!/usr/bin/env bash
#
# Entrypoint for the in-cluster imogen tool server image.
#
# The tool server shells out to az and kubectl. In AKS it authenticates to Azure
# with workload identity: the Azure Workload Identity webhook projects a
# federated token into AZURE_FEDERATED_TOKEN_FILE and sets AZURE_CLIENT_ID and
# AZURE_TENANT_ID. az has no native workload-identity mode, so we log in with the
# federated token here and refresh it in the background, since the projected
# token rotates and az's own cache expires after about an hour.
#
# When those variables are absent (local kind, no workload identity) we skip the
# login and only the network-only tools work, which matches the prior behavior.

set -euo pipefail

az_login() {
  az login --service-principal \
    --username "$AZURE_CLIENT_ID" \
    --tenant "$AZURE_TENANT_ID" \
    --federated-token "$(cat "$AZURE_FEDERATED_TOKEN_FILE")" \
    --output none
  if [[ -n "${IMOGEN_SUBSCRIPTION_ID:-}" ]]; then
    az account set --subscription "$IMOGEN_SUBSCRIPTION_ID" --output none || true
  fi
}

if [[ -n "${AZURE_FEDERATED_TOKEN_FILE:-}" && -f "${AZURE_FEDERATED_TOKEN_FILE}" ]]; then
  echo "Logging in to Azure with workload identity (client $AZURE_CLIENT_ID)"
  az_login
  # Keep the az token cache fresh; the projected federated token rotates.
  (
    while true; do
      sleep "${IMOGEN_AZ_RELOGIN_SECONDS:-1800}"
      az_login || echo "az relogin failed, will retry" >&2
    done
  ) &
else
  echo "No workload identity present; az is not logged in (network-only tools)"
fi

exec imogen-toolserver "$@"
