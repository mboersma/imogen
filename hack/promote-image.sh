#!/usr/bin/env bash
#
# Promote an image version from the staging gallery to the community gallery.
#
# Run this only after the image version has been validated and approved. The new
# community version is created from the staging version as its source, so the
# galleries must be in the same resource group.
#
# Usage: hack/promote-image.sh <flavor> <version>
#   e.g. hack/promote-image.sh ubuntu-2404 1.34.9
#
# Parameterized via IMOGEN_* env vars. See hack/foundation.env.example.

set -euo pipefail

if [[ -f "$(dirname "$0")/foundation.env" ]]; then
  # shellcheck disable=SC1091
  source "$(dirname "$0")/foundation.env"
fi

FLAVOR="${1:-}"
VERSION="${2:-}"
if [[ -z "$FLAVOR" || -z "$VERSION" ]]; then
  echo "usage: $0 <flavor> <version>" >&2
  exit 1
fi
VERSION="${VERSION#v}"

SUBSCRIPTION_ID="${IMOGEN_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
RESOURCE_GROUP="${IMOGEN_RESOURCE_GROUP:-imogen}"
STAGING_GALLERY="${IMOGEN_STAGING_GALLERY:-imogen_staging}"
COMMUNITY_GALLERY="${IMOGEN_COMMUNITY_GALLERY:-imogen_community}"

az account set --subscription "$SUBSCRIPTION_ID"

DEFINITION="capi-${FLAVOR}"
SOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Compute/galleries/${STAGING_GALLERY}/images/${DEFINITION}/versions/${VERSION}"

echo "Promoting ${DEFINITION}/${VERSION}"
echo "  from $STAGING_GALLERY"
echo "  to   $COMMUNITY_GALLERY"
echo

az sig image-version create \
  -g "$RESOURCE_GROUP" \
  --gallery-name "$COMMUNITY_GALLERY" \
  --gallery-image-definition "$DEFINITION" \
  --gallery-image-version "$VERSION" \
  --image-version "$SOURCE_ID" \
  -o none

echo "promoted ${DEFINITION}/${VERSION} to $COMMUNITY_GALLERY"
