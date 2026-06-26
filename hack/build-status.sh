#!/usr/bin/env bash
#
# Report the state of an image-builder Job on the CAPZ builder cluster, mapping
# the Job conditions to a single word: Pending, Running, Succeeded or Failed.
#
# Usage: hack/build-status.sh <job-name>

set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -f "$DIR/hack/foundation.env" ]]; then
  # shellcheck disable=SC1091
  source "$DIR/hack/foundation.env"
fi
# shellcheck source=hack/lib.sh
source "$DIR/hack/lib.sh"

JOB="${1:-}"
if [[ -z "$JOB" ]]; then
  echo "usage: $0 <job-name>" >&2
  exit 1
fi

WL_KUBECONFIG="$(imogen_builder_kubeconfig)"
trap 'rm -f "$WL_KUBECONFIG"' EXIT

if ! kubectl --kubeconfig "$WL_KUBECONFIG" get job "$JOB" -n default -o json >/tmp/imogen-job.$$ 2>/dev/null; then
  echo "NotFound"
  exit 0
fi

SUCCEEDED="$(jq -r '.status.succeeded // 0' /tmp/imogen-job.$$)"
FAILED="$(jq -r '.status.failed // 0' /tmp/imogen-job.$$)"
ACTIVE="$(jq -r '.status.active // 0' /tmp/imogen-job.$$)"
rm -f /tmp/imogen-job.$$

if [[ "$SUCCEEDED" -gt 0 ]]; then
  echo "Succeeded"
elif [[ "$FAILED" -gt 0 ]]; then
  echo "Failed"
elif [[ "$ACTIVE" -gt 0 ]]; then
  # A Job counts a Pending pod as active, so check the pod phase to tell a
  # scheduled, running build apart from one still waiting for a worker node.
  PHASE="$(kubectl --kubeconfig "$WL_KUBECONFIG" get pods -n default \
    -l job-name="$JOB" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
  if [[ "$PHASE" == "Running" ]]; then
    echo "Running"
  else
    echo "Pending"
  fi
else
  echo "Pending"
fi
