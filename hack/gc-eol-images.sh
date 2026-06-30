#!/usr/bin/env bash
#
# Retire end-of-life and superseded image versions from a gallery.
#
# A version is end of life when its Kubernetes minor is older than the most
# recent MINORS minors upstream. Within an in-scope minor, any patch below the
# highest patch present is superseded. This is the same policy the gc-eol-images
# MCP tool applies; this script is the manual operator equivalent.
#
# It is destructive but defaults to a dry run: it only lists the candidates.
# Pass --apply (or IMOGEN_GC_APPLY=1) to actually delete them.
#
# Usage: hack/gc-eol-images.sh [flavor] [--apply]
#   e.g. hack/gc-eol-images.sh                 # dry run, all flavors, community
#        hack/gc-eol-images.sh ubuntu-2404 --apply
#
# Tunables (env):
#   IMOGEN_GC_STAGE    staging or community gallery role (default community)
#   IMOGEN_GC_MINORS   how many recent k8s minors stay in scope (default 3)
#   IMOGEN_GC_APPLY    1 to delete; default 0 only reports
#
# Parameterized via IMOGEN_* env vars. See hack/foundation.env.example.

set -euo pipefail

if [[ -f "$(dirname "$0")/foundation.env" ]]; then
  # shellcheck disable=SC1091
  source "$(dirname "$0")/foundation.env"
fi

FLAVOR=""
APPLY="${IMOGEN_GC_APPLY:-0}"
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --dry-run) APPLY=0 ;;
    -*) echo "unknown flag: $arg" >&2; exit 1 ;;
    *) FLAVOR="$arg" ;;
  esac
done

SUBSCRIPTION_ID="${IMOGEN_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
RESOURCE_GROUP="${IMOGEN_RESOURCE_GROUP:-imogen}"
STAGE="${IMOGEN_GC_STAGE:-community}"
MINORS="${IMOGEN_GC_MINORS:-3}"
if [[ "$STAGE" == "staging" ]]; then
  GALLERY="${IMOGEN_STAGING_GALLERY:-imogen_staging}"
else
  GALLERY="${IMOGEN_COMMUNITY_GALLERY:-imogen_community}"
fi

az account set --subscription "$SUBSCRIPTION_ID"

# Determine the oldest in-scope minor from upstream stable releases. Anything
# older than this minor is end of life.
LATEST="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
LATEST_MINOR="$(echo "${LATEST#v}" | cut -d. -f2)"
OLDEST_MINOR=$((LATEST_MINOR - MINORS + 1))
echo "In scope: 1.${OLDEST_MINOR}..1.${LATEST_MINOR} ($MINORS minors). Gallery: $GALLERY (apply=$APPLY)"

if [[ -n "$FLAVOR" ]]; then
  DEFINITIONS="capi-${FLAVOR#capi-}"
else
  DEFINITIONS="$(az sig image-definition list -g "$RESOURCE_GROUP" -r "$GALLERY" --query "[].name" -o tsv)"
fi

retire() { # definition version reason
  if [[ "$APPLY" == "1" ]]; then
    echo "  deleting $1/$2 ($3)"
    az sig image-version delete -g "$RESOURCE_GROUP" -r "$GALLERY" -i "$1" -e "$2" -o none
  else
    echo "  would delete $1/$2 ($3)"
  fi
}

TOTAL=0
for def in $DEFINITIONS; do
  VERSIONS="$(az sig image-version list -g "$RESOURCE_GROUP" -r "$GALLERY" -i "$def" --query "[].name" -o tsv)"
  [[ -z "$VERSIONS" ]] && continue
  SORTED="$(echo "$VERSIONS" | sort -t. -k1,1n -k2,2n -k3,3n)"

  for v in $SORTED; do
    minor="$(echo "$v" | cut -d. -f2)"; patch="$(echo "$v" | cut -d. -f3)"
    if [[ "$minor" -lt "$OLDEST_MINOR" ]]; then
      retire "$def" "$v" eol-minor; TOTAL=$((TOTAL + 1)); continue
    fi
    # Highest patch present for this minor, so superseded patches can be retired.
    maxpatch="$(echo "$SORTED" | awk -F. -v m="$minor" '$2==m {print $3}' | sort -n | tail -1)"
    if [[ "$patch" -lt "$maxpatch" ]]; then
      retire "$def" "$v" superseded-patch; TOTAL=$((TOTAL + 1))
    fi
  done
done

if [[ "$TOTAL" == "0" ]]; then
  echo "Nothing to retire."
elif [[ "$APPLY" == "1" ]]; then
  echo "Retired $TOTAL version(s) from $GALLERY."
else
  echo "$TOTAL version(s) would be retired. Re-run with --apply to delete them."
fi
