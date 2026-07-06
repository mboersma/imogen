#!/usr/bin/env bash
#
# Garbage-collect managed images (Microsoft.Compute/images) left behind by image
# builds.
#
# image-builder's Azure build creates a temporary managed image (capi-<flavor>-<ts>)
# in the staging resource group, then creates the staging gallery version from it.
# The gallery version is an independent replicated copy, so the managed image is
# only a build intermediate, but image-builder never deletes it. Every successful
# build therefore leaks one managed image (and its backing OS disk snapshot),
# which accumulates in the shared subscription.
#
# This sweep deletes those leftovers. It is deliberately conservative, mirroring
# hack/gc-build-rgs.sh: it only ever touches an image that BOTH carries our
# imogen-build tag (set by deploy/build-job.yaml's azure_tags patch, which Packer
# applies to the managed image too) AND is named like an image-builder managed
# image (capi-*), and only once it is older than a TTL well beyond any real build,
# so an image a running build is still publishing from is never disturbed.
# hack/run-build-job.sh runs it (with --apply) before each build, so leaks are
# cleaned up on the next build.
#
# It defaults to a dry run that only reports the candidates. Pass --apply (or
# IMOGEN_BUILD_IMAGE_APPLY=1) to actually delete them.
#
# Usage: hack/gc-build-images.sh [--apply]
# Tunables (env):
#   IMOGEN_BUILD_IMAGE_TTL    seconds a tagged image must age before deletion (default 10800)
#   IMOGEN_BUILD_IMAGE_APPLY  1 to delete; default 0 only reports

set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "$DIR/hack/foundation.env" ]]; then
  # shellcheck disable=SC1091
  source "$DIR/hack/foundation.env"
fi

APPLY="${IMOGEN_BUILD_IMAGE_APPLY:-0}"
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --dry-run) APPLY=0 ;;
    *) echo "unknown flag: $arg" >&2; exit 1 ;;
  esac
done

TTL="${IMOGEN_BUILD_IMAGE_TTL:-10800}"
NOW="$(date -u +%s)"
RESOURCE_GROUP="${IMOGEN_RESOURCE_GROUP:?set IMOGEN_RESOURCE_GROUP}"
SUBSCRIPTION_ID="${IMOGEN_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
az account set --subscription "$SUBSCRIPTION_ID"

# Only images carrying our imogen-build tag are even considered, scoped further
# to the image-builder managed-image name (capi-*) as defense in depth.
QUERY="[?tags.\"imogen-build\" != null && starts_with(name, 'capi-')].[name, tags.\"imogen-build-ts\", tags.build_timestamp]"

found=0
count=0
while IFS=$'\t' read -r name ts fallback_ts; do
  [[ -z "$name" ]] && continue
  found=$((found + 1))
  # Fall back to image-builder's own build_timestamp tag if ours is absent.
  [[ -z "$ts" || "$ts" == "None" ]] && ts="$fallback_ts"
  if [[ -z "$ts" || "$ts" == "None" || ! "$ts" =~ ^[0-9]+$ ]]; then
    echo "  keep $name (no usable build timestamp; not deleting unknown-age image)"
    continue
  fi
  age=$((NOW - ts))
  if [[ "$age" -lt "$TTL" ]]; then
    echo "  keep $name (age ${age}s < TTL ${TTL}s; a build may still be publishing from it)"
    continue
  fi
  count=$((count + 1))
  if [[ "$APPLY" == "1" ]]; then
    echo "  deleting $name (age ${age}s)"
    az image delete -g "$RESOURCE_GROUP" -n "$name"
  else
    echo "  would delete $name (age ${age}s)"
  fi
done < <(az image list -g "$RESOURCE_GROUP" --query "$QUERY" -o tsv)

if [[ "$found" -eq 0 ]]; then
  echo "No imogen-tagged managed images found."
  exit 0
fi

if [[ "$count" -eq 0 ]]; then
  echo "Nothing to garbage-collect."
elif [[ "$APPLY" == "1" ]]; then
  echo "Deleted $count leaked build managed image(s)."
else
  echo "$count leaked build managed image(s) would be deleted. Re-run with --apply."
fi
