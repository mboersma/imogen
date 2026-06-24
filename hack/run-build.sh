#!/usr/bin/env bash
#
# Run an image-builder Azure SIG build as a standalone container, publishing to
# the staging gallery.
#
# This is temporary. The build moves to a Kubernetes Job on the CAPZ builder
# cluster later; until then it runs as an Azure Container Instance using a
# user-assigned managed identity (no service principal secret).
#
# Usage: hack/run-build.sh <flavor> <k8s-version>
#   e.g. hack/run-build.sh ubuntu-2404 v1.34.9
#
# The container authenticates with `az login --identity`, sets
# USE_AZURE_CLI_AUTH so Packer reuses that login, then runs the
# build-azure-sig-<flavor> target. Packer creates a temporary resource group
# and build VM, so the identity needs Contributor on the subscription.

set -euo pipefail

if [[ -f "$(dirname "$0")/foundation.env" ]]; then
  # shellcheck disable=SC1091
  source "$(dirname "$0")/foundation.env"
fi

FLAVOR="${1:-}"
VERSION="${2:-}"
if [[ -z "$FLAVOR" || -z "$VERSION" ]]; then
  echo "usage: $0 <flavor> <k8s-version>" >&2
  exit 1
fi

# Strip a leading v: gallery image versions are numeric X.Y.Z.
SIG_VERSION="${VERSION#v}"
SEMVER="v${SIG_VERSION}"
SERIES="v${SIG_VERSION%.*}"

SUBSCRIPTION_ID="${IMOGEN_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
LOCATION="${IMOGEN_LOCATION:-westus3}"
RESOURCE_GROUP="${IMOGEN_RESOURCE_GROUP:-imogen}"
STAGING_GALLERY="${IMOGEN_STAGING_GALLERY:-imogen_staging}"
BUILDER_IMAGE="${IMOGEN_BUILDER_IMAGE:-registry.k8s.io/scl-image-builder/cluster-node-image-builder-amd64:v0.1.52}"
IDENTITY="${IMOGEN_BUILDER_IDENTITY:-imogen-builder}"

az account set --subscription "$SUBSCRIPTION_ID"

IDENTITY_ID="${IMOGEN_BUILDER_IDENTITY_ID:-$(az identity show -g "$RESOURCE_GROUP" -n "$IDENTITY" --query id -o tsv)}"
CLIENT_ID="${IMOGEN_BUILDER_CLIENT_ID:-$(az identity show -g "$RESOURCE_GROUP" -n "$IDENTITY" --query clientId -o tsv)}"

TARGET="build-azure-sig-${FLAVOR}"
CONTAINER_GROUP="imogen-build-${FLAVOR}-${SIG_VERSION//./-}"

# The container reuses the managed-identity login for Packer and overrides the
# gallery image version with the Kubernetes version.
COMMAND="az login --identity --client-id ${CLIENT_ID} && export USE_AZURE_CLI_AUTH=True && make ${TARGET}"

echo "Container group: $CONTAINER_GROUP"
echo "Target:          $TARGET"
echo "Gallery:         $STAGING_GALLERY"
echo "Image version:   $SIG_VERSION"
echo

az container create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CONTAINER_GROUP" \
  --image "$BUILDER_IMAGE" \
  --location "$LOCATION" \
  --os-type Linux \
  --cpu 2 --memory 4 \
  --restart-policy Never \
  --assign-identity "$IDENTITY_ID" \
  --command-line "/bin/bash -c \"$COMMAND\"" \
  --environment-variables \
    AZURE_SUBSCRIPTION_ID="$SUBSCRIPTION_ID" \
    AZURE_LOCATION="$LOCATION" \
    AZURE_CLIENT_ID="$CLIENT_ID" \
    RESOURCE_GROUP_NAME="$RESOURCE_GROUP" \
    GALLERY_NAME="$STAGING_GALLERY" \
    PACKER_FLAGS="--var sig_image_version=${SIG_VERSION} --var kubernetes_semver=${SEMVER} --var kubernetes_series=${SERIES} --var kubernetes_deb_version=${SIG_VERSION}-1.1 --var kubernetes_rpm_version=${SIG_VERSION}" \
  -o none

echo "build container $CONTAINER_GROUP started."
echo "follow logs with:"
echo "  az container logs -g $RESOURCE_GROUP -n $CONTAINER_GROUP --follow"
