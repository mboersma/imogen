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
#   IMOGEN_RECONCILE_BUILD    1 to build versions missing from both galleries, 0 to
#                             only validate+promote what is already staged (default 1)
#   IMOGEN_RECONCILE_TIMEOUT  seconds to stream before disconnecting (default 1800)

set -euo pipefail

AGENT_URL="${IMOGEN_AGENT_URL:-http://imogen.kagent.svc.cluster.local:8080/}"
FLAVORS="${IMOGEN_RECONCILE_FLAVORS:-ubuntu-2404}"
MINORS="${IMOGEN_RECONCILE_MINORS:-3}"
MAX_PER_RUN="${IMOGEN_RECONCILE_MAX:-1}"
BUILD="${IMOGEN_RECONCILE_BUILD:-1}"
TIMEOUT="${IMOGEN_RECONCILE_TIMEOUT:-1800}"

FLAVORS_CSV="$(echo "$FLAVORS" | tr ', ' '\n' | sed '/^$/d' | paste -sd ', ' -)"

if [[ "$BUILD" == "1" ]]; then
  BUILD_STEP="4. For each in-scope version missing from BOTH galleries: call submit-build-job (at \
most ${MAX_PER_RUN} per flavor this run), then keep polling get-build-status until it reports \
Succeeded or Failed. Builds take tens of minutes, so keep waiting and polling on your own. Do NOT \
stop to ask whether you should keep waiting, and do NOT end your turn while a build is Pending or \
Running. When it Succeeds the new version is in staging, so handle it like step 3."
else
  BUILD_STEP="4. Do NOT submit any new builds this run. If an in-scope version is missing from both \
galleries, just report that it needs a build."
fi

PROMPT="You are the imogen image reconciler. Reconcile the Azure community gallery \
against upstream Kubernetes releases for these flavors: ${FLAVORS_CSV}.

A version reaches the community gallery in two stages: it is built into the staging gallery, then \
validated and promoted to the community gallery. So a version already in staging has been built and \
only needs validation and promotion.

Steps:
1. Call list-k8s-releases with minorCount ${MINORS} to get the latest stable patch \
for each recent Kubernetes minor version. These are the in-scope versions.
2. For each flavor, call list-gallery-versions for BOTH the staging and the community stage to see \
which image versions exist in each.
3. For each in-scope version that is in staging but NOT yet in the community gallery: it is already \
built, so call validate-image on it. If validation passes, request human approval and then call \
promote-image once approved (promote is the only step that needs a human). Keep polling any \
long-running tool on your own; do NOT end your turn while one is still working.
${BUILD_STEP}
5. If every in-scope version is already in the community gallery, do nothing and say so.

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
