#!/usr/bin/env bash
#
# Create the imogen Azure foundation: a resource group, a staging gallery, a
# community gallery, and image definitions for each supported flavor.
#
# Idempotent. All names and locations are parameterized via IMOGEN_* env vars
# so the dev galleries in a personal subscription can be swapped for the
# production galleries in the CNCF subscription. See hack/foundation.env.example.

set -euo pipefail

# Optionally source a local config file.
if [[ -f "$(dirname "$0")/foundation.env" ]]; then
  # shellcheck disable=SC1091
  source "$(dirname "$0")/foundation.env"
fi

# shellcheck source=hack/lib.sh
source "$(dirname "$0")/lib.sh"

SUBSCRIPTION_ID="${IMOGEN_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
LOCATION="${IMOGEN_LOCATION:-westus3}"
RESOURCE_GROUP="${IMOGEN_RESOURCE_GROUP:-imogen}"
STAGING_GALLERY="${IMOGEN_STAGING_GALLERY:-imogen_staging}"
COMMUNITY_GALLERY="${IMOGEN_COMMUNITY_GALLERY:-imogen_community}"
PUBLISHER="${IMOGEN_GALLERY_PUBLISHER:-imogen}"
OFFER="${IMOGEN_GALLERY_OFFER:-imogen}"
FLAVORS="${IMOGEN_FLAVORS:-ubuntu-2404 ubuntu-2604 azurelinux-3 windows-2022-containerd windows-2025-containerd}"
ENABLE_COMMUNITY="${IMOGEN_ENABLE_COMMUNITY:-false}"

az account set --subscription "$SUBSCRIPTION_ID"

echo "Subscription: $SUBSCRIPTION_ID"
echo "Location:     $LOCATION"
echo "Group:        $RESOURCE_GROUP"
echo "Galleries:    $STAGING_GALLERY (staging), $COMMUNITY_GALLERY (community)"
echo "Flavors:      $FLAVORS"
echo

# flavor_meta prints "<os-type> <hyperv-gen> <sku>" for a known flavor.
flavor_meta() {
  case "$1" in
  ubuntu-2404) echo "Linux V1 24_04-lts" ;;
  ubuntu-2604) echo "Linux V1 26_04-lts" ;;
  azurelinux-3) echo "Linux V1 azure-linux-3" ;;
  windows-2022-containerd) echo "Windows V1 win-2022-containerd" ;;
  windows-2025-containerd) echo "Windows V1 win-2025-containerd" ;;
  *)
    echo "unknown flavor: $1" >&2
    return 1
    ;;
  esac
}

ensure_group() {
  if ! az group show -n "$RESOURCE_GROUP" -o none 2>/dev/null; then
    az group create -n "$RESOURCE_GROUP" -l "$LOCATION" -o none
    echo "created resource group $RESOURCE_GROUP"
  fi
  imogen_protect_rg "$RESOURCE_GROUP"
}

ensure_gallery() {
  local gallery="$1"
  shift
  if ! az sig show --resource-group "$RESOURCE_GROUP" --gallery-name "$gallery" -o none 2>/dev/null; then
    az sig create --resource-group "$RESOURCE_GROUP" --gallery-name "$gallery" \
      --location "$LOCATION" "$@" -o none
    echo "created gallery $gallery"
  fi
}

ensure_image_definition() {
  local gallery="$1" flavor="$2"
  read -r ostype gen sku <<<"$(flavor_meta "$flavor")"
  local def="capi-${flavor}"
  if ! az sig image-definition show --resource-group "$RESOURCE_GROUP" \
    --gallery-name "$gallery" --gallery-image-definition "$def" -o none 2>/dev/null; then
    az sig image-definition create --resource-group "$RESOURCE_GROUP" \
      --gallery-name "$gallery" --gallery-image-definition "$def" \
      --publisher "$PUBLISHER" --offer "$OFFER" --sku "$sku" \
      --os-type "$ostype" --hyper-v-generation "$gen" --location "$LOCATION" -o none
    echo "created image definition $gallery/$def ($ostype $gen)"
  fi
}

ensure_group
ensure_gallery "$STAGING_GALLERY"

if [[ "$ENABLE_COMMUNITY" == "true" ]]; then
  : "${IMOGEN_COMMUNITY_PREFIX:?set IMOGEN_COMMUNITY_PREFIX when IMOGEN_ENABLE_COMMUNITY=true}"
  : "${IMOGEN_PUBLISHER_URI:?set IMOGEN_PUBLISHER_URI when IMOGEN_ENABLE_COMMUNITY=true}"
  : "${IMOGEN_PUBLISHER_EMAIL:?set IMOGEN_PUBLISHER_EMAIL when IMOGEN_ENABLE_COMMUNITY=true}"
  : "${IMOGEN_PUBLISHER_EULA:?set IMOGEN_PUBLISHER_EULA when IMOGEN_ENABLE_COMMUNITY=true}"
  ensure_gallery "$COMMUNITY_GALLERY" --permissions Community \
    --public-name-prefix "$IMOGEN_COMMUNITY_PREFIX" \
    --publisher-uri "$IMOGEN_PUBLISHER_URI" \
    --publisher-email "$IMOGEN_PUBLISHER_EMAIL" \
    --eula "$IMOGEN_PUBLISHER_EULA"
  az sig share enable-community --resource-group "$RESOURCE_GROUP" \
    --gallery-name "$COMMUNITY_GALLERY" -o none
  echo "enabled community sharing on $COMMUNITY_GALLERY"
else
  ensure_gallery "$COMMUNITY_GALLERY"
fi

for flavor in $FLAVORS; do
  ensure_image_definition "$STAGING_GALLERY" "$flavor"
  ensure_image_definition "$COMMUNITY_GALLERY" "$flavor"
done

echo
echo "Foundation ready in resource group $RESOURCE_GROUP."
