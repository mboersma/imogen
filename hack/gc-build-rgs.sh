#!/usr/bin/env bash
#
# Garbage-collect temporary Packer resource groups left behind by image builds.
#
# A normal image build runs in a Packer-created temporary resource group
# (pkr-Resource-Group-<random>) that Packer deletes itself on success or on a
# graceful failure. But a hard failure (the build pod killed, the node
# deallocated, an activeDeadline timeout) can kill Packer before it cleans up,
# leaking the group and its VM, disk and network.
#
# This sweep deletes those leaked groups. It is deliberately conservative for a
# shared subscription: it only ever touches a group that BOTH carries our
# imogen-build tag (set by deploy/build-job.yaml) AND is named like a Packer temp
# group, and only once it is older than a TTL well beyond any real build, so a
# running build is never disturbed. hack/run-build-job.sh runs it (with --apply)
# before each build, so leaks are cleaned up on the next build.
#
# It defaults to a dry run that only reports the candidates. Pass --apply (or
# IMOGEN_BUILD_RG_APPLY=1) to actually delete them.
#
# Usage: hack/gc-build-rgs.sh [--apply]
# Tunables (env):
#   IMOGEN_BUILD_RG_TTL    seconds a tagged group must age before deletion (default 10800)
#   IMOGEN_BUILD_RG_APPLY  1 to delete; default 0 only reports

set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "$DIR/hack/foundation.env" ]]; then
  # shellcheck disable=SC1091
  source "$DIR/hack/foundation.env"
fi

APPLY="${IMOGEN_BUILD_RG_APPLY:-0}"
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --dry-run) APPLY=0 ;;
    *) echo "unknown flag: $arg" >&2; exit 1 ;;
  esac
done

TTL="${IMOGEN_BUILD_RG_TTL:-10800}"
SUBSCRIPTION_ID="${IMOGEN_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
az account set --subscription "$SUBSCRIPTION_ID"

# Only groups carrying our imogen-build tag are even considered, scoped further
# to the Packer temp-group name as defense in depth.
QUERY="[?tags.\"imogen-build\" != null && starts_with(name, 'pkr-Resource-Group-')].[name, tags.\"imogen-build-ts\", tags.build_timestamp]"

found=0
count=0
while IFS=$'\t' read -r name ts fallback_ts; do
  [[ -z "$name" ]] && continue
  found=$((found + 1))
  # Fall back to image-builder's own build_timestamp tag if ours is absent.
  [[ -z "$ts" || "$ts" == "None" ]] && ts="$fallback_ts"
  if [[ -z "$ts" || "$ts" == "None" || ! "$ts" =~ ^[0-9]+$ ]]; then
    echo "  keep $name (no usable build timestamp; not deleting unknown-age group)"
    continue
  fi
  age=$((NOW - ts))
  if [[ "$age" -lt "$TTL" ]]; then
    echo "  keep $name (age ${age}s < TTL ${TTL}s; a build may be running)"
    continue
  fi
  count=$((count + 1))
  if [[ "$APPLY" == "1" ]]; then
    echo "  deleting $name (age ${age}s)"
    az group delete -n "$name" --yes --no-wait
  else
    echo "  would delete $name (age ${age}s)"
  fi
done < <(az group list --query "$QUERY" -o tsv)

if [[ "$found" -eq 0 ]]; then
  echo "No imogen-tagged Packer resource groups found."
  exit 0
fi

if [[ "$count" -eq 0 ]]; then
  echo "Nothing to garbage-collect."
elif [[ "$APPLY" == "1" ]]; then
  echo "Started deletion of $count leaked build resource group(s)."
else
  echo "$count leaked build resource group(s) would be deleted. Re-run with --apply."
fi
