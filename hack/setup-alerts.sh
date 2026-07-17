#!/usr/bin/env bash
#
# Wire imogen's audit log to an Azure Monitor alert so a human is notified of
# approval requests and failures without a Slack or Teams webhook.
#
# The tool server already emits every tool action as a structured JSON line to
# stderr (see internal/tools/audit.go). This script enables Container Insights
# on the management cluster so those lines land in a Log Analytics workspace,
# then creates an Action Group (email) and a scheduled-query alert that fires
# when the agent raises a level=approval notification or a tool action fails.
#
# Nothing leaves the pod: the pod just keeps logging, and the alert is evaluated
# in Azure, so there is no outbound webhook and no stored secret. This is the
# production-friendly replacement for the notify webhook when Slack and Teams
# are locked down.
#
# Idempotent. Parameterized via IMOGEN_* env vars. Set IMOGEN_ALERT_EMAIL.

set -euo pipefail

if [[ -f "$(dirname "$0")/foundation.env" ]]; then
  # shellcheck disable=SC1091
  source "$(dirname "$0")/foundation.env"
fi

SUBSCRIPTION_ID="${IMOGEN_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
RESOURCE_GROUP="${IMOGEN_RESOURCE_GROUP:-imogen}"
LOCATION="${IMOGEN_MGMT_LOCATION:-${IMOGEN_LOCATION:-westus3}}"
AKS_NAME="${IMOGEN_MGMT_CLUSTER:-imogen-mgmt}"
WORKSPACE="${IMOGEN_LOG_WORKSPACE:-imogen-logs}"
ACTION_GROUP="${IMOGEN_ALERT_ACTION_GROUP:-imogen-alerts}"
ALERT_RULE="${IMOGEN_ALERT_RULE:-imogen-approval-and-failure}"
AGENT_NAMESPACE="${IMOGEN_AGENT_NAMESPACE:-kagent}"
EVAL_FREQUENCY="${IMOGEN_ALERT_FREQUENCY:-15m}"
SEVERITY="${IMOGEN_ALERT_SEVERITY:-2}"

: "${IMOGEN_ALERT_EMAIL:?set IMOGEN_ALERT_EMAIL to the address that should receive imogen alerts}"

az account set --subscription "$SUBSCRIPTION_ID"

# 1. Log Analytics workspace to hold the container logs.
if ! az monitor log-analytics workspace show \
  -g "$RESOURCE_GROUP" -n "$WORKSPACE" -o none 2>/dev/null; then
  echo "Creating Log Analytics workspace $WORKSPACE"
  az monitor log-analytics workspace create \
    -g "$RESOURCE_GROUP" -n "$WORKSPACE" -l "$LOCATION" -o none
fi
WORKSPACE_ID="$(az monitor log-analytics workspace show \
  -g "$RESOURCE_GROUP" -n "$WORKSPACE" --query id -o tsv)"

# 2. Container Insights on the management cluster so the tool server's stderr
#    audit lines flow into ContainerLogV2. Enabled once; a no-op thereafter.
MONITOR_ENABLED="$(az aks show -g "$RESOURCE_GROUP" -n "$AKS_NAME" \
  --query "addonProfiles.omsagent.enabled" -o tsv 2>/dev/null || echo false)"
if [[ "$MONITOR_ENABLED" != "true" ]]; then
  echo "Enabling Container Insights on $AKS_NAME"
  az aks enable-addons -a monitoring \
    -g "$RESOURCE_GROUP" -n "$AKS_NAME" \
    --workspace-resource-id "$WORKSPACE_ID" -o none
else
  echo "Container Insights already enabled on $AKS_NAME"
fi

# 3. Action Group that delivers the alert by email.
echo "Ensuring action group $ACTION_GROUP delivers to $IMOGEN_ALERT_EMAIL"
az monitor action-group create \
  -g "$RESOURCE_GROUP" -n "$ACTION_GROUP" \
  --short-name imogen \
  --action email imogen-admin "$IMOGEN_ALERT_EMAIL" -o none
ACTION_GROUP_ID="$(az monitor action-group show \
  -g "$RESOURCE_GROUP" -n "$ACTION_GROUP" --query id -o tsv)"

# 4. Scheduled-query alert on the audit stream. The audit lines are JSON, one
#    per tool action, with the input arguments carried in a nested "input"
#    string, so an approval notification shows up as a notify action whose input
#    contains "approval". A failed tool action logs "success":false. Fire on
#    either. contains is used rather than has because the tokens include quotes
#    and colons.
read -r -d '' QUERY <<KQL || true
ContainerLogV2
| where PodNamespace == "${AGENT_NAMESPACE}"
| where LogMessage contains '"msg":"tool action"'
| where (LogMessage contains '"tool":"notify"' and LogMessage contains 'approval')
     or LogMessage contains '"success":false'
KQL

echo "Creating scheduled-query alert $ALERT_RULE"
az monitor scheduled-query create \
  -g "$RESOURCE_GROUP" -n "$ALERT_RULE" \
  --scopes "$WORKSPACE_ID" \
  --condition "count 'audit' > 0" \
  --condition-query audit="$QUERY" \
  --evaluation-frequency "$EVAL_FREQUENCY" \
  --window-size "$EVAL_FREQUENCY" \
  --severity "$SEVERITY" \
  --action-groups "$ACTION_GROUP_ID" \
  --description "imogen agent raised an approval request or a tool action failed" \
  -o none 2>/dev/null \
  || az monitor scheduled-query update \
    -g "$RESOURCE_GROUP" -n "$ALERT_RULE" \
    --condition "count 'audit' > 0" \
    --condition-query audit="$QUERY" \
    --evaluation-frequency "$EVAL_FREQUENCY" \
    --window-size "$EVAL_FREQUENCY" \
    --severity "$SEVERITY" \
    --action-groups "$ACTION_GROUP_ID" -o none

echo "Alerting wired: $ALERT_RULE -> $ACTION_GROUP -> $IMOGEN_ALERT_EMAIL"
echo "Container logs may take a few minutes to appear in $WORKSPACE after enablement."
