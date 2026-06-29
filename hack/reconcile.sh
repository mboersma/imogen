#!/usr/bin/env bash
#
# Ask the imogen agent to reconcile the community gallery against upstream
# Kubernetes releases: find versions that are missing and drive them through
# build -> validate -> (approval) -> promote.
#
# This is the release-watcher trigger. It posts a standing reconcile prompt to
# the agent's A2A endpoint over JSON-RPC and streams the agent's events to
# stdout. The agent does the gap analysis and runs the pipeline with its own
# tools, so this script stays thin. The task continues server-side, so a human
# can later resubscribe to approve the promote step (kagent UI or tasks/resubscribe).
#
# Usage: hack/reconcile.sh
# Tunables (env):
#   IMOGEN_AGENT_URL        agent A2A endpoint (default in-cluster service)
#   IMOGEN_RECONCILE_FLAVORS  space or comma list of flavors (default ubuntu-2404)
#   IMOGEN_RECONCILE_MINORS   how many recent k8s minors to track (default 3)
#   IMOGEN_RECONCILE_MAX      max missing versions to build per run (default 1)
#   IMOGEN_RECONCILE_TIMEOUT  seconds to stream before disconnecting (default 1800)

set -euo pipefail

AGENT_URL="${IMOGEN_AGENT_URL:-http://imogen.kagent.svc.cluster.local:8080/}"
FLAVORS="${IMOGEN_RECONCILE_FLAVORS:-ubuntu-2404}"
MINORS="${IMOGEN_RECONCILE_MINORS:-3}"
MAX_PER_RUN="${IMOGEN_RECONCILE_MAX:-1}"
TIMEOUT="${IMOGEN_RECONCILE_TIMEOUT:-1800}"

FLAVORS_CSV="$(echo "$FLAVORS" | tr ', ' '\n' | sed '/^$/d' | paste -sd ', ' -)"

PROMPT="You are the imogen image reconciler. Reconcile the Azure community gallery \
against upstream Kubernetes releases for these flavors: ${FLAVORS_CSV}.

Steps:
1. Call list-k8s-releases with minorCount ${MINORS} to get the latest stable patch \
for each recent Kubernetes minor version.
2. For each flavor, call list-gallery-versions for the community stage to see which \
image versions already exist.
3. Compute the gap: upstream (flavor, version) pairs that are NOT already in the \
community gallery. Build at most ${MAX_PER_RUN} missing version(s) per flavor this run.
4. For each version you decide to build: call submit-build-job, then keep polling \
get-build-status until it reports Succeeded or Failed. Builds take a while (tens of \
minutes), so keep waiting and polling on your own. Do NOT stop to ask whether you \
should keep waiting, and do NOT end your turn while a build is still Pending or \
Running. If it Succeeded, call validate-image. If validation passes, request human \
approval and then call promote-image once approved (the only step that needs a human).
5. If the community gallery is already current, do nothing and say so.

Report a short summary of what you found and what you did."

ID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$RANDOM$RANDOM")"
MSG_ID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$RANDOM$RANDOM")"

PAYLOAD="$(jq -n --arg id "$ID" --arg mid "$MSG_ID" --arg text "$PROMPT" '{
  jsonrpc: "2.0",
  id: $id,
  method: "message/stream",
  params: { message: {
    role: "user",
    parts: [ { kind: "text", text: $text } ],
    messageId: $mid
  } }
}')"

echo "Reconciling ${FLAVORS_CSV} (minors=${MINORS}, max/run=${MAX_PER_RUN}) via ${AGENT_URL}"
curl -sN --max-time "$TIMEOUT" \
  -H 'Content-Type: application/json' \
  -H 'Accept: text/event-stream' \
  -d "$PAYLOAD" \
  "$AGENT_URL" | while IFS= read -r line; do
    case "$line" in
      data:*) echo "${line#data:}" | head -c 2000; echo ;;
    esac
  done

echo "Reconcile stream ended (the agent task may continue server-side)."
