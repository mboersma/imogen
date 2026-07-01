#!/usr/bin/env bash
# Show what imogen has done, read from the toolserver's get-audit-log tool.
#
# Every MCP tool call imogen makes is recorded in an in-memory audit log. This
# script reads that log from your workstation: it port-forwards to the toolserver
# Service, speaks just enough MCP to call get-audit-log, and prints the actions
# newest last.
#
# Usage:
#   hack/audit-log.sh                 # last 50 actions
#   hack/audit-log.sh --limit 200     # last 200 actions
#   hack/audit-log.sh --tool promote-image
#   hack/audit-log.sh --changes       # only actions that change published images
#   hack/audit-log.sh --watch         # follow new actions as they happen
#   hack/audit-log.sh --json          # raw JSON events
#
# The audit log lives in the toolserver pod's memory, so it resets when the pod
# restarts. For durable history, the same events are also container logs
# (kubectl -n kagent logs deploy/imogen-toolserver) and flow to Azure Monitor.
set -euo pipefail

NAMESPACE="${IMOGEN_NAMESPACE:-kagent}"
SVC="${IMOGEN_TOOLSERVER_SVC:-imogen-toolserver}"
PORT="${IMOGEN_AUDIT_PORT:-18080}"
LIMIT=50
TOOL=""
CHANGES=0
WATCH=0
INTERVAL="${IMOGEN_AUDIT_WATCH_INTERVAL:-15}"
RAW=0

while [ $# -gt 0 ]; do
	case "$1" in
	--limit) LIMIT="$2"; shift 2 ;;
	--tool) TOOL="$2"; shift 2 ;;
	--changes) CHANGES=1; shift ;;
	--watch) WATCH=1; shift ;;
	--json) RAW=1; shift ;;
	-h | --help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

BASE="http://127.0.0.1:${PORT}/"
PF_PID=""
SID=""

cleanup() {
	[ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true
}
trap cleanup EXIT

start_pf() {
	kubectl -n "$NAMESPACE" port-forward "svc/${SVC}" "${PORT}:8080" >/dev/null 2>&1 &
	PF_PID=$!
	# Wait for the forward to accept connections.
	for _ in $(seq 1 20); do
		if curl -sf -o /dev/null "http://127.0.0.1:${PORT}/healthz" 2>/dev/null; then
			return 0
		fi
		sleep 0.25
	done
	echo "could not reach ${SVC} in namespace ${NAMESPACE}" >&2
	exit 1
}

mcp_init() {
	local hdrs
	hdrs="$(mktemp)"
	curl -s -D "$hdrs" -o /dev/null -X POST "$BASE" \
		-H 'Content-Type: application/json' \
		-H 'Accept: application/json, text/event-stream' \
		-d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"audit-log.sh","version":"0"}}}'
	SID="$(grep -i '^mcp-session-id:' "$hdrs" | awk '{print $2}' | tr -d '\r')"
	rm -f "$hdrs"
	if [ -z "$SID" ]; then
		echo "toolserver did not return an MCP session id" >&2
		exit 1
	fi
	curl -s -o /dev/null -X POST "$BASE" \
		-H 'Content-Type: application/json' \
		-H 'Accept: application/json, text/event-stream' \
		-H "Mcp-Session-Id: $SID" \
		-d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
}

# fetch_events echoes the raw events JSON array for the current filters.
fetch_events() {
	local args
	if [ -n "$TOOL" ]; then
		args="{\"limit\":${LIMIT},\"tool\":\"${TOOL}\"}"
	else
		args="{\"limit\":${LIMIT}}"
	fi
	curl -s -X POST "$BASE" \
		-H 'Content-Type: application/json' \
		-H 'Accept: application/json, text/event-stream' \
		-H "Mcp-Session-Id: $SID" \
		-d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"get-audit-log\",\"arguments\":${args}}}" \
		| sed -n 's/^data: //p'
}

# render pretty-prints events. Reads the tools/call JSON on stdin. Arg 1 is the
# minimum seq to skip (only print events with a greater seq). It always prints
# the table to stdout and writes the highest seq it saw to $SEQ_FILE so --watch
# can advance its cursor.
render() {
	CHANGES="$CHANGES" RAW="$RAW" MIN_SEQ="${1:-0}" SEQ_FILE="${SEQ_FILE:-/dev/null}" python3 -c '
import json, os, sys

changes = os.environ.get("CHANGES") == "1"
raw = os.environ.get("RAW") == "1"
min_seq = int(os.environ.get("MIN_SEQ", "0"))
seq_file = os.environ.get("SEQ_FILE", "/dev/null")

# Actions that create or delete a published (community-gallery) image.
CHANGE_TOOLS = {"promote-image", "gc-eol-images"}

def write_cursor(v):
    try:
        with open(seq_file, "w") as f:
            f.write(str(v))
    except OSError:
        pass

data = sys.stdin.read().strip()
if not data:
    write_cursor(min_seq)
    sys.exit(0)
doc = json.loads(data)
if "error" in doc:
    print("toolserver error:", doc["error"].get("message", doc["error"]))
    write_cursor(min_seq)
    sys.exit(0)
events = doc.get("result", {}).get("structuredContent", {}).get("events", [])

max_seq = min_seq
rows = []
for e in events:
    seq = e.get("seq", 0)
    if seq > max_seq:
        max_seq = seq
    if seq <= min_seq:
        continue
    tool = e.get("tool", "")
    if changes and tool not in CHANGE_TOOLS:
        continue
    rows.append(e)

if raw:
    if rows:
        print(json.dumps(rows, indent=2))
    write_cursor(max_seq)
    sys.exit(0)

def summarize_input(e):
    inp = e.get("input") or {}
    # Surface the fields that matter for image changes first.
    keys = ["flavor", "version", "apply", "graceDays", "count", "level", "message"]
    parts = []
    for k in keys:
        if k in inp:
            parts.append("%s=%s" % (k, inp[k]))
    for k, v in inp.items():
        if k not in keys:
            parts.append("%s=%s" % (k, v))
    return " ".join(parts)

for e in rows:
    seq = e.get("seq", 0)
    ts = e.get("time", "")[:19].replace("T", " ")
    tool = e.get("tool", "")
    ok = "ok  " if e.get("success") else "FAIL"
    dur = e.get("durationMs", 0)
    flag = " *PUBLISHED-IMAGE*" if tool in CHANGE_TOOLS else ""
    print("#%-4d %s  %-4s %-22s %6dms  %s%s" % (seq, ts, ok, tool, dur, summarize_input(e), flag))
    if not e.get("success") and e.get("error"):
        print("        error: %s" % e["error"])

write_cursor(max_seq)
'
}

start_pf
mcp_init

if [ "$WATCH" -eq 0 ]; then
	fetch_events | render 0
	exit 0
fi

echo "Following imogen audit log (Ctrl-C to stop). Namespace ${NAMESPACE}, service ${SVC}."
SEQ_FILE="$(mktemp)"
export SEQ_FILE
echo 0 >"$SEQ_FILE"
while true; do
	LAST="$(cat "$SEQ_FILE")"
	fetch_events | render "$LAST"
	sleep "$INTERVAL"
done
