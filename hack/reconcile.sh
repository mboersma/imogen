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
# state it resubscribes to the same task and keeps following it.
#
# One agent turn is not enough on its own: the model tends to end its turn while
# validations and builds are still running, leaving validated images unpromoted.
# Validations and builds keep running server-side (the tool server drains them),
# so this script loops: it re-posts the reconcile prompt for a fresh turn until
# list-reconcile-plan reports the community gallery is up to date, or an overall
# deadline passes. Each turn promotes whatever has finished since the last one
# and starts work on the rest; persistence lives in this loop, not in the model.
#
# Promotion normally waits for human approval, but the watcher has no human, so
# the reconcile prompt authorizes the agent to promote validated images on its
# own (IMOGEN_RECONCILE_AUTO_PROMOTE=1, the default). Interactive runs through
# the kagent UI still hit the approval gate in the agent's system message.
# Retirement is likewise automated here (IMOGEN_RECONCILE_GC_APPLY=1, the
# default): the agent deletes minors more than a year past their upstream EOL.
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
#   IMOGEN_RECONCILE_GC_APPLY 1 to delete EOL minors past the grace period without
#                             approval (default 1), 0 to only report candidates
#   IMOGEN_RECONCILE_TIMEOUT  overall seconds to keep looping (default 5400)
#   IMOGEN_RECONCILE_PASS_INTERVAL seconds to wait between agent turns so
#                             server-side validations and builds can drain (default 180)

set -euo pipefail

AGENT_URL="${IMOGEN_AGENT_URL:-http://imogen.kagent.svc.cluster.local:8080/}"
FLAVORS="${IMOGEN_RECONCILE_FLAVORS:-ubuntu-2404}"
MINORS="${IMOGEN_RECONCILE_MINORS:-3}"
MAX_PER_RUN="${IMOGEN_RECONCILE_MAX:-1}"
BUILD="${IMOGEN_RECONCILE_BUILD:-1}"
AUTO_PROMOTE="${IMOGEN_RECONCILE_AUTO_PROMOTE:-1}"
GC_APPLY="${IMOGEN_RECONCILE_GC_APPLY:-1}"
TIMEOUT="${IMOGEN_RECONCILE_TIMEOUT:-5400}"
PASS_INTERVAL="${IMOGEN_RECONCILE_PASS_INTERVAL:-180}"

FLAVORS_CSV="$(echo "$FLAVORS" | tr ', ' '\n' | sed '/^$/d' | paste -sd , - | sed 's/,/, /g')"

if [[ "$BUILD" == "1" ]]; then
  BUILD_STEP="Work items with action=build are missing from both galleries. For each (at most \
${MAX_PER_RUN} per flavor this run): first call get-build-status for its flavor and version. If a build \
for it is already Pending \
or Running from an earlier turn, leave it. Otherwise call submit-build-job for its flavor and version. \
You do NOT need to wait for the build to finish: builds run as Kubernetes Jobs server-side and take tens \
of minutes, and this reconcile runs in a loop. Once a build Succeeds the version lands in staging, so a \
later turn will see it as an action=validate-promote item and carry it through validation and promotion. \
Just make sure a build is running for each build item this turn (at most ${MAX_PER_RUN} per flavor), \
report which you started, and move on."
else
  BUILD_STEP="Do NOT submit any new builds this run. For each work item with action=build, just report \
that it needs a build."
fi

if [[ "$AUTO_PROMOTE" == "1" ]]; then
  PROMOTE_STEP="Work items with action=validate-promote are already built into staging and only need \
validation and promotion. This reconcile runs in a loop, so you do NOT have to drive every one to \
completion in this turn: a later turn will pick up whatever is still running. For each item, first call \
get-validation-status. If it reports Succeeded, the image has already validated, so promote it now: \
call promote-image and poll get-promote-status until it reports Succeeded. If it reports NotFound, call \
validate-image to start validation. If it reports Running, validation is already in progress from an \
earlier turn, so leave it. Never call promote-image while validation is Running or after it Failed: \
promote-image refuses to promote anything whose validation has not Succeeded, so promoting early just \
fails. You do not need to wait for slow validations (a Windows node join takes many \
minutes); promote everything already validated, make sure validation has been started for everything \
else, poll and promote any that finish quickly, then move on. If validation Failed, do NOT promote; \
report the failure and move on."
else
  PROMOTE_STEP="Work items with action=validate-promote are already built into staging and only need \
validation and promotion. For each: call get-validation-status; if NotFound call validate-image to start \
it, and if Succeeded call notify with level=approval to request that a human approve promoting it, but do \
NOT promote this run: no human is available to approve right now. This reconcile runs in a loop, so you \
do not need to wait for slow validations; a later turn will pick them up."
fi

if [[ "$GC_APPLY" == "1" ]]; then
  GC_STEP="Call gc-eol-images with apply=true for the community gallery to retire (delete) any minors \
whose upstream end-of-life date is more than the grace period (about a year) in the past. This runs \
unattended and the policy authorizes deleting minors that far out of support without asking, so delete \
them and report exactly which versions you removed. A minor still supported, within the grace window, or \
with no known EOL date is never a candidate, so if there are none say so."
else
  GC_STEP="Call gc-eol-images as a dry run (apply=false) for the community gallery to list any minors past \
their upstream end-of-life grace period. Report them as retirement candidates, but do NOT delete anything: \
retirement needs human approval, so leave apply=true for an operator."
fi

PROMPT="You are the imogen image reconciler. Reconcile the Azure community gallery \
against upstream Kubernetes releases for these flavors: ${FLAVORS_CSV}.

A version reaches the community gallery in two stages: it is built into the staging gallery, then \
validated and promoted to the community gallery. So a version already in staging has been built and \
only needs validation and promotion.

Steps:
1. Call list-reconcile-plan with flavors [${FLAVORS_CSV}] and minorCount ${MINORS}. It does the gap \
analysis for you and returns an explicit work list: each item has a flavor, a version, and an action of \
either build or validate-promote. Trust this list completely; do NOT recompute the gap yourself or skip \
items. If it returns upToDate true (an empty work list), every in-scope version is already in the \
community gallery, so skip to step 4 and say so. Any work item marked blocked true has already exhausted \
its build or validation retry cap: do NOT build, validate, or promote it this run, since retrying it \
would only fail again. Skip every blocked item and collect them for the notify in step 6.
2. ${PROMOTE_STEP}
3. ${BUILD_STEP}
4. ${GC_STEP}
5. This reconcile runs in a loop until the community gallery matches upstream, so you do NOT have to \
finish every work item in this one turn. Make as much progress as you can: promote every version that \
has already validated, make sure validation has been started for every version that still needs it, and \
make sure a build is running for every build item (up to the per-flavor limit). Anything still validating, \
building, or promoting when you finish will be picked up by a later turn, so you may end your turn once \
you have started or advanced every item. Do NOT sit idle polling a slow validation or build to \
completion; end the turn and let the loop re-invoke you.
6. Finally, call notify once with a short summary of what you found and did this run (level=info). Your \
summary must describe only what the tools actually confirmed: never say a version was built, validated, \
promoted, or deleted unless the corresponding tool confirmed it for that version this run. If a step did \
not finish or is still in progress, say so plainly rather than assuming success. If there are any blocked \
work items, or anything else needs a human, such as a step you could not complete, also call \
notify with level=approval naming exactly which versions are blocked and why, and what you need.

Report a short summary of what you found and what you did."

# build_payload emits a message/stream JSON-RPC request with a fresh messageId,
# so each loop pass starts a new agent task rather than resuming the last one.
build_payload() {
  local mid rpc
  mid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$RANDOM$RANDOM")"
  rpc="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$RANDOM$RANDOM")"
  jq -n --arg id "$rpc" --arg mid "$mid" --arg text "$PROMPT" '{
    jsonrpc: "2.0",
    id: $id,
    method: "message/stream",
    params: { message: {
      role: "user",
      parts: [ { kind: "text", text: $text } ],
      messageId: $mid
    } }
  }'
}

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
UP_TO_DATE=""
STUCK=""

# consume reads an SSE stream on stdin, prints events, and tracks the task id and
# latest task state in the TASK_ID / TASK_STATE globals. It also captures the
# upToDate flag from a list-reconcile-plan tool result into UP_TO_DATE, which the
# outer loop uses to decide when the gallery is fully reconciled. It runs in the
# current shell (callers use process substitution) so those globals persist.
consume() {
  local line data tid state plan
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

    # The plan tool result carries upToDate and stuck; both arrive inside an
    # escaped JSON string, so match the fields textually rather than parsing the
    # nested JSON.
    if printf '%s' "$data" | grep -q 'list-reconcile-plan'; then
      plan="$(printf '%s' "$data" | grep -oE 'upToDate[^,}]*' | head -1 || true)"
      case "$plan" in
        *true*) UP_TO_DATE=true ;;
        *false*) UP_TO_DATE=false ;;
      esac
      plan="$(printf '%s' "$data" | grep -oE 'stuck[^,}]*' | head -1 || true)"
      case "$plan" in
        *true*) STUCK=true ;;
        *false*) STUCK=false ;;
      esac
    fi

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
    -d "$(build_payload)" \
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
PASS=0

# follow_task runs one agent turn to a terminal state: it posts the reconcile
# prompt, then resubscribes to the same task if the stream drops mid-run, until
# the task reaches a terminal state or the deadline passes. It leaves the outcome
# in TASK_STATE and any plan verdict in UP_TO_DATE.
follow_task() {
  TASK_ID=""
  TASK_STATE=""
  while :; do
    local now remaining
    now="$(date +%s)"
    remaining=$((DEADLINE - now))
    [[ "$remaining" -le 0 ]] && return 0

    if [[ -z "$TASK_ID" ]]; then
      consume < <(post_message "$remaining")
      if [[ -z "$TASK_ID" ]]; then
        echo "No task started (the agent did not respond)."
        return 1
      fi
    else
      echo "Stream ended while task was '${TASK_STATE}'; resubscribing to ${TASK_ID}..."
      consume < <(resubscribe "$TASK_ID" "$remaining")
    fi

    case "$TASK_STATE" in
      completed|failed|canceled|rejected|input-required|auth-required) return 0 ;;
    esac
    sleep 2
  done
}

while :; do
  now="$(date +%s)"
  if [[ $((DEADLINE - now)) -le 0 ]]; then
    echo "Reconcile deadline reached after ${TIMEOUT}s; last plan upToDate='${UP_TO_DATE:-unknown}' (work may continue server-side)."
    exit 1
  fi

  PASS=$((PASS + 1))
  UP_TO_DATE=""
  STUCK=""
  echo "=== reconcile pass ${PASS} ==="
  follow_task

  case "$TASK_STATE" in
    input-required|auth-required)
      echo "Agent is waiting for human input ('${TASK_STATE}'); unattended run cannot proceed."
      exit 1 ;;
  esac

  if [[ "$UP_TO_DATE" == "true" ]]; then
    echo "Reconcile complete: the community gallery is up to date after ${PASS} pass(es)."
    exit 0
  fi

  # Every outstanding item has exhausted its build or validation retry cap, so
  # another pass would only retry broken work until the deadline. Give up and let
  # the agent's run leave a level=approval notification for a human.
  if [[ "$STUCK" == "true" ]]; then
    echo "Reconcile stuck after ${PASS} pass(es): every outstanding image is blocked at its retry cap; a human must investigate."
    exit 1
  fi

  # Not up to date yet (the turn ended, or failed, with work still outstanding).
  # Builds and validations keep draining server-side, so wait a bit to let them
  # make progress, then run another turn to promote what has finished.
  if [[ "$TASK_STATE" != "completed" ]]; then
    echo "Pass ${PASS} ended as '${TASK_STATE:-no-response}'; will retry."
  fi
  now="$(date +%s)"
  if [[ $((DEADLINE - now)) -le 0 ]]; then
    echo "Reconcile deadline reached after ${TIMEOUT}s; last plan upToDate='${UP_TO_DATE:-unknown}' (work may continue server-side)."
    exit 1
  fi
  echo "Waiting ${PASS_INTERVAL}s for in-flight validations and builds to drain before the next pass..."
  sleep "$PASS_INTERVAL"
done
