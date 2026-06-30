#!/usr/bin/env bash
#
# Retire image versions whose Kubernetes minor has been out of upstream support
# for longer than a grace period (default one year).
#
# The contract is deliberately conservative: downstream projects keep testing
# against out-of-support releases and pin specific patches, so this retires whole
# minors only, never individual patches, and only once a minor is past its
# upstream end-of-life date by IMOGEN_GC_GRACE_DAYS. Per-minor EOL dates come
# from endoflife.date. This is the manual equivalent of the gc-eol-images tool.
#
# It is destructive but defaults to a dry run: it only lists the candidates.
# Pass --apply (or IMOGEN_GC_APPLY=1) to actually delete them.
#
# Usage: hack/gc-eol-images.sh [flavor] [--apply]
#   e.g. hack/gc-eol-images.sh                 # dry run, all flavors, community
#        hack/gc-eol-images.sh ubuntu-2404 --apply
#
# Tunables (env):
#   IMOGEN_GC_STAGE       staging or community gallery role (default community)
#   IMOGEN_GC_GRACE_DAYS  days past upstream EOL before retiring (default 365)
#   IMOGEN_GC_APPLY       1 to delete; default 0 only reports
#   IMOGEN_K8S_EOL_URL    per-minor EOL source (default endoflife.date)
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
GRACE_DAYS="${IMOGEN_GC_GRACE_DAYS:-365}"
EOL_URL="${IMOGEN_K8S_EOL_URL:-https://endoflife.date/api/kubernetes.json}"
if [[ "$STAGE" == "staging" ]]; then
  GALLERY="${IMOGEN_STAGING_GALLERY:-imogen_staging}"
else
  GALLERY="${IMOGEN_COMMUNITY_GALLERY:-imogen_community}"
fi

az account set --subscription "$SUBSCRIPTION_ID"

# Per-minor upstream end-of-life dates, keyed by minor ("1.33" -> "2026-06-28").
EOL_JSON="$(curl -fsSL "$EOL_URL")"
NOW_EPOCH="$(date -u +%s)"
GRACE_SECS=$((GRACE_DAYS * 86400))
echo "Retiring minors past upstream EOL by ${GRACE_DAYS}d. Gallery: $GALLERY (apply=$APPLY)"

# to_epoch converts a YYYY-MM-DD date to a Unix timestamp, on GNU or BSD date.
to_epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f "%Y-%m-%d" "$1" +%s 2>/dev/null
}

if [[ -n "$FLAVOR" ]]; then
  DEFINITIONS="capi-${FLAVOR#capi-}"
else
  DEFINITIONS="$(az sig image-definition list -g "$RESOURCE_GROUP" -r "$GALLERY" --query "[].name" -o tsv)"
fi

retire() { # definition version minor eol-date
  if [[ "$APPLY" == "1" ]]; then
    echo "  deleting $1/$2 (minor $3 EOL $4)"
    az sig image-version delete -g "$RESOURCE_GROUP" -r "$GALLERY" -i "$1" -e "$2" -o none
  else
    echo "  would delete $1/$2 (minor $3 EOL $4)"
  fi
}

TOTAL=0
for def in $DEFINITIONS; do
  VERSIONS="$(az sig image-version list -g "$RESOURCE_GROUP" -r "$GALLERY" -i "$def" --query "[].name" -o tsv)"
  [[ -z "$VERSIONS" ]] && continue

  for v in $(echo "$VERSIONS" | sort -t. -k1,1n -k2,2n -k3,3n); do
    minor="$(echo "$v" | cut -d. -f1-2)"
    eol_date="$(echo "$EOL_JSON" | jq -r --arg c "$minor" '.[] | select(.cycle==$c) | .eol | select(type=="string")')"
    [[ -z "$eol_date" ]] && continue            # unknown or still supported: keep
    eol_epoch="$(to_epoch "$eol_date")"
    [[ -z "$eol_epoch" ]] && continue
    if [[ $((NOW_EPOCH - eol_epoch)) -ge "$GRACE_SECS" ]]; then
      retire "$def" "$v" "$minor" "$eol_date"; TOTAL=$((TOTAL + 1))
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
