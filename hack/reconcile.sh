#!/usr/bin/env bash
#
# Ask the imogen agent to reconcile the community gallery against upstream
# Kubernetes releases: find versions that are missing and drive them through
# build -> validate -> promote.
#
# This is the release-watcher trigger. It posts a standing reconcile prompt to
# the agent's A2A endpoint over JSON-RPC and streams the agent's events. The
# agent does the gap analysis and runs the pipeline with its own tools, so this
# script stays thin.
#
# kagent runs the task server-side, and a single SSE connection can drop while a
# long build runs (tens of minutes). To run unattended, this script does not
# rely on one stream: when the stream ends before the task reaches a terminal
# state it resubscribes to the same task and keeps following it, until the task
# completes or an overall deadline passes.
#
# Promotion normally waits for human approval, but the watcher has no human, so
# the reconcile prompt authorizes the agent to promote validated images on its
# own (IMOGEN_RECONCILE_AUTO_PROMOTE=1, the default). Interactive runs through
# the kagent UI still hit the approval gate in the agent's system message.
# Retirement (gc-eol-images apply=true) is never automated here.
#
# Usage: hack/reconcile.sh
# Tunables (env):
#   IMOGEN_AGENT_URL          agent A2A endpoint (default in-cluster service)
#   IMOGEN_RECONCILE_FLAVORS  space or comma list of flavors (default ubuntu-2404)
#   IMOGEN_RECONCILE_MINORS   how many recent k8s minors to track (default 3)
#   IMOGEN_RECONCILE_MAX      max missing versions to build per run (default 1)
#   IMOGEN_RECONCILE_BUILD    1 to build versions missing from both galleries, 0 to
#                             only validate+promote what is already staged (default 1)
#   IMOGEN_RECONCILE_AUTO_PROMOTE  1 to promote validated images without approval
#                             (default 1), 0 to stop and ask a human before promote
#   IMOGEN_RECONCILE_TIMEOUT  overall seconds to keep following the task (default 5400)

set -euo pipefail

AGENT_URL="${IMOGEN_AGENT_URL:-http://imogen.kagent.svc.cluster.local:8080/}"
FLAVORS="${IMOGEN_RECONCILE_FLAVORS:-ubuntu-2404}"
MINORS="${IMOGEN_RECONCILE_MINORS:-3}"
MAX_PER_RUN="${IMOGEN_RECONCILE_MAX:-1}"
BUILD="${IMOGEN_RECONCILE_BUILD:-1}"
AUTO_PROMOTE="${IMOGEN_RECONCILE_AUTO_PROMOTE:-1}"
TIMEOUT="${IMOGEN_RECONCILE_TIMEOUT:-5400}"

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

if [[ "$AUTO_PROMOTE" == "1" ]]; then
  PROMOTE_STEP="3. For each in-scope version that is in staging but NOT yet in the community gallery: \
it is already built, so call validate-image on it. This reconcile runs unattended on a schedule and \
no human is available, so if validation passes you are authorized to promote it without asking for \
approval: call promote-image directly, then keep polling get-promote-status until it reports \
Succeeded before treating the version as promoted. If validation fails, do NOT promote; report the \
failure and move on. Keep polling any long-running tool on your own; do NOT end your turn while one \
is still working."
else
  PROMOTE_STEP="3. For each in-scope version that is in staging but NOT yet in the community gallery: \
it is already built, so call validate-image on it. If validation passes, request human approval and \
then call promote-image once approved (promote is the only step that needs a human). After \
promote-image, keep polling get-promote-status until it reports Succeeded before treating the version \
as promoted. Keep polling any long-running tool on your own; do NOT end your turn while one is still \
working."
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
${PROMOTE_STEP}
${BUILD_STEP}
5. If every in-scope version is already in the community gallery, say so.
6. Call gc-eol-images as a dry run (apply=false) for the community gallery to list any minors past their \
upstream end-of-life grace period. Report them as retirement candidates, but do NOT delete anything: retirement \
needs human approval, so leave apply=true for an operator.

Report a short summary of what you found and what you did."

MSG_ID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$RANDOM$RANDOM")"
RPC_ID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$RANDOM$RANDOM")"

START_PAYLOAD="$(jq -n --arg id "$RPC_ID" --arg mid "$MSG_ID" --arg text "$PROMPT" '{
  jsonrpc: "2.0",
  id: $id,
  method: "message/stream",
  params: { message: {
    role: "user",
    parts: [ { kind: "text", text: $text } ],
    messageId: $mid
  } }
}')"

# jq filter that turns one SSE "data:" JSON event into human-readable lines:
# agent text, tool calls and results, and the final artifact summary.
# shellcheck disable=SC2016  # $r, $m, $author are jq variables, not shell
EVENT_FILTER='
  (.result // {}) as $r
  | ($r.status.message // {}) as $m
  | (($m.metadata // {}).kagent_author // "agent") as $author
  | (
      ($m.parts // [])[]
      | if .kind == "text" and (.text | length > 0) and $author != "user" then
          "[agent] \(.text)"
        elif .kind == "data" then
          ((.metadata // {}).kagent_type) as $mt
          | if $mt == "function_call" then
              "[tool-call] \(.data.name)(\(.data.args | tojson))"
            elif $mt == "function_response" then
              "[tool-result] \(.data.name): \(((.data.response // .data) | tojson)[0:400])"
            else empty end
        else empty end
    ),
    ( if $r.kind == "artifact-update" then
        (($r.artifact.parts // [])[] | select(.kind == "text" and (.text | length > 0)) | "[result] \(.text)")
      else empty end )
'

TASK_ID=""
TASK_STATE=""

# consume reads an SSE stream on stdin, prints events, and tracks the task id and
# latest task state in the TASK_ID / TASK_STATE globals. It runs in the current
# shell (callers use process substitution) so those globals persist.
consume() {
  local line data tid state
  while IFS= read -r line; do
    case "$line" in
      data:*) ;;
      *) continue ;;
    esac
    data="${line#data:}"
    data="${data# }"
    [[ -z "$data" ]] && continue

    tid="$(printf '%s' "$data" | jq -r '.result.taskId // .result.id // empty' 2>/dev/null || true)"
    [[ -n "$tid" ]] && TASK_ID="$tid"
    state="$(printf '%s' "$data" | jq -r '.result.status.state // empty' 2>/dev/null || true)"
    [[ -n "$state" ]] && TASK_STATE="$state"

    printf '%s' "$data" | jq -r "$EVENT_FILTER" 2>/dev/null || true

    case "$state" in
      completed|failed|canceled|rejected|input-required|auth-required) return 0 ;;
    esac
  done
}

post_message() { # $1 max-time
  curl -sN --max-time "$1" \
    -H 'Content-Type: application/json' \
    -H 'Accept: text/event-stream' \
    -d "$START_PAYLOAD" \
    "$AGENT_URL" || true
}

resubscribe() { # $1 task id, $2 max-time
  local body
  body="$(jq -n --arg tid "$1" '{jsonrpc:"2.0", id:"resub", method:"tasks/resubscribe", params:{id:$tid}}')"
  curl -sN --max-time "$2" \
    -H 'Content-Type: application/json' \
    -H 'Accept: text/event-stream' \
    -d "$body" \
    "$AGENT_URL" || true
}

echo "Reconciling ${FLAVORS_CSV} (minors=${MINORS}, max/run=${MAX_PER_RUN}, auto-promote=${AUTO_PROMOTE}) via ${AGENT_URL}"

START="$(date +%s)"
DEADLINE=$((START + TIMEOUT))
while :; do
  now="$(date +%s)"
  remaining=$((DEADLINE - now))
  if [[ "$remaining" -le 0 ]]; then
    echo "Reconcile deadline reached after ${TIMEOUT}s while task was '${TASK_STATE:-unstarted}' (it may continue server-side)."
    exit 1
  fi

  if [[ -z "$TASK_ID" ]]; then
    consume < <(post_message "$remaining")
    if [[ -z "$TASK_ID" ]]; then
      echo "No task started (the agent did not respond). Giving up."
      exit 1
    fi
  else
    echo "Stream ended while task was '${TASK_STATE}'; resubscribing to ${TASK_ID}..."
    consume < <(resubscribe "$TASK_ID" "$remaining")
  fi

  case "$TASK_STATE" in
    completed)
      echo "Reconcile complete."
      exit 0 ;;
    failed|canceled|rejected)
      echo "Reconcile task ended as '${TASK_STATE}'."
      exit 1 ;;
    input-required|auth-required)
      echo "Agent is waiting for human input ('${TASK_STATE}'); unattended run cannot proceed."
      exit 1 ;;
  esac

  sleep 2
done
