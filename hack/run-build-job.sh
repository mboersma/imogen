#!/usr/bin/env bash
#
# Run an image-builder Azure SIG build as a Kubernetes Job on the CAPZ builder
# cluster, publishing to the staging gallery.
#
# This replaces hack/run-build.sh (the Azure Container Instances stopgap). The
# Job pod authenticates with the build managed identity exposed on the builder
# VMSS through IMDS (no stored secret), so the builder VMSS must have the
# imogen-builder identity assigned (hack/setup-builder-cluster.sh does this).
#
# Usage: hack/run-build-job.sh <flavor> <k8s-version>
#   e.g. hack/run-build-job.sh ubuntu-2404 v1.34.9
#
# Non-blocking: it ensures the pool has a worker, applies the Job, and returns
# the Job name. Follow it with hack/build-status.sh <job> or the get-build-status
# tool.

set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -f "$DIR/hack/foundation.env" ]]; then
  # shellcheck disable=SC1091
  source "$DIR/hack/foundation.env"
fi
# shellcheck source=hack/lib.sh
source "$DIR/hack/lib.sh"

FLAVOR="${1:-}"
VERSION="${2:-}"
if [[ -z "$FLAVOR" || -z "$VERSION" ]]; then
  echo "usage: $0 <flavor> <k8s-version>" >&2
  exit 1
fi

SIG_VERSION="${VERSION#v}"
SEMVER="v${SIG_VERSION}"
SERIES="v${SIG_VERSION%.*}"

SUBSCRIPTION_ID="${IMOGEN_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
LOCATION="${IMOGEN_LOCATION:-westus3}"
RESOURCE_GROUP="${IMOGEN_RESOURCE_GROUP:-imogen}"
STAGING_GALLERY="${IMOGEN_STAGING_GALLERY:-imogen_staging}"
BUILDER_IMAGE="${IMOGEN_BUILDER_IMAGE:-registry.k8s.io/scl-image-builder/cluster-node-image-builder-amd64:v0.1.53}"
MGMT_CLUSTER="${IMOGEN_MGMT_CLUSTER:-imogen-mgmt}"
CLUSTER="${IMOGEN_BUILDER_CLUSTER:-imogen-builder}"
IDENTITY="${IMOGEN_BUILDER_IDENTITY:-imogen-builder}"
CLIENT_ID="${IMOGEN_BUILDER_CLIENT_ID:-$(az identity show -g "$RESOURCE_GROUP" -n "$IDENTITY" --query clientId -o tsv)}"

TARGET="build-azure-sig-${FLAVOR}"
NAME="imogen-build-${FLAVOR}-${SIG_VERSION//./-}"
BUILD_TS="$(date -u +%s)"

# Every flavor pins the Kubernetes version so the gallery version label matches
# what is installed. The package variable is OS-specific: Ubuntu installs a .deb,
# Azure Linux installs an .rpm, and Windows downloads binaries by semver and needs
# neither.
PACKER_FLAGS="--var sig_image_version=${SIG_VERSION} --var kubernetes_semver=${SEMVER} --var kubernetes_series=${SERIES}"
case "$FLAVOR" in
ubuntu-*)
  # Look up the exact published deb revision instead of assuming -1.1, which breaks
  # when upstream rebuilds a patch's packages (1.36.2 shipped as -2.1). Abort if it
  # cannot be resolved rather than launching a build doomed to fail minutes later.
  if ! DEB_VERSION="$(imogen_k8s_deb_version "$SERIES" "$SIG_VERSION")"; then
    echo "Aborting: no kubelet deb revision for ${SIG_VERSION}; not submitting a build that would fail." >&2
    exit 1
  fi
  echo "Using kubernetes_deb_version=${DEB_VERSION}"
  PACKER_FLAGS="${PACKER_FLAGS} --var kubernetes_deb_version=${DEB_VERSION}"
  ;;
azurelinux-*)
  # image-builder installs kubelet-<rpm_version> from the community rpm repo; its
  # own default is the plain patch version, no revision suffix.
  echo "Using kubernetes_rpm_version=${SIG_VERSION}"
  PACKER_FLAGS="${PACKER_FLAGS} --var kubernetes_rpm_version=${SIG_VERSION}"
  ;;
windows-*)
  # A Windows node needs a matching sigwindowstools/kube-proxy HostProcess image
  # to run, so a Windows image is useless if that tag does not exist yet. Verify
  # it up front (as image-builder's own build-azure-sig workflow does) rather than
  # publishing an image that cannot later join a cluster.
  KP_IMAGE="sigwindowstools/kube-proxy"
  KP_TAG="${SEMVER}-calico-hostprocess"
  echo "Checking the Windows kube-proxy image ${KP_IMAGE}:${KP_TAG} exists"
  KP_TOKEN="$(curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${KP_IMAGE}:pull" | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])')"
  KP_STATUS="$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${KP_TOKEN}" \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
    "https://registry-1.docker.io/v2/${KP_IMAGE}/manifests/${KP_TAG}")"
  if [[ "$KP_STATUS" != "200" ]]; then
    echo "Aborting: ${KP_IMAGE}:${KP_TAG} not found (HTTP ${KP_STATUS}); not building a Windows image that could not run as a node." >&2
    exit 1
  fi
  echo "Windows kube-proxy image found"
  ;;
esac

# Machine pool operations are on the management cluster; on a workstation select
# its context first (in cluster the tool server already runs against it).
if [[ "${IMOGEN_IN_CLUSTER:-}" != "1" ]]; then
  kubectl config use-context "$MGMT_CLUSTER" >/dev/null
fi

# The build pod requests CPU and memory but has nowhere to run when the pool is
# at zero, so it stays Pending and cluster-autoscaler scales the MachinePool up
# to give it a node (see deploy/cluster-autoscaler.yaml). The autoscaler scales
# back to zero once the build finishes. Use hack/scale-builder.sh to override
# manually if the autoscaler is not running.

WL_KUBECONFIG="$(imogen_builder_kubeconfig)"
trap 'rm -f "$WL_KUBECONFIG"' EXIT

# Inspect any existing Job for this exact flavor and version so a reconcile loop
# that re-invokes submit-build-job every pass neither clobbers an in-flight build
# nor rebuilds a broken image forever.
EXISTING="$(kubectl --kubeconfig "$WL_KUBECONFIG" get job "$NAME" -o json 2>/dev/null || true)"
ACTIVE=0
FAILED=0
ATTEMPT=0
if [[ -n "$EXISTING" ]]; then
  ACTIVE="$(printf '%s' "$EXISTING" | jq -r '.status.active // 0')"
  FAILED="$(printf '%s' "$EXISTING" | jq -r '.status.failed // 0')"
  ATTEMPT="$(printf '%s' "$EXISTING" | jq -r '.metadata.annotations["imogen.build/attempt"] // "0"')"
fi

# A build already running (or pending a node) from an earlier turn is left alone:
# replace --force below would delete the in-flight Job and restart the build from
# scratch, so it would never finish. .status.active counts pending and running
# pods, so this also covers a build still waiting for the autoscaler.
if [[ "${ACTIVE:-0}" =~ ^[0-9]+$ && "${ACTIVE:-0}" -gt 0 ]]; then
  echo "Build Job $NAME is already active; leaving it running" >&2
  echo "$NAME"
  exit 0
fi

# A previous attempt for this exact version failed. Retry a bounded number of
# times, since a build can flake on transient Azure capacity, but once the cap is
# reached stop recreating the Job: leave it Failed so get-build-status keeps
# reporting Failed and a human is asked to look, instead of rebuilding a broken
# image every reconcile pass for hours.
MAX_ATTEMPTS="${IMOGEN_BUILD_MAX_ATTEMPTS:-3}"
if [[ "${FAILED:-0}" =~ ^[0-9]+$ && "${FAILED:-0}" -gt 0 && "${ATTEMPT:-0}" -ge "$MAX_ATTEMPTS" ]]; then
  echo "Build Job $NAME has failed on ${ATTEMPT} attempt(s), at the ${MAX_ATTEMPTS}-attempt cap; not rebuilding. A human should investigate before it is retried." >&2
  echo "$NAME"
  exit 1
fi
BUILD_ATTEMPT=$((ATTEMPT + 1))

# Sweep any temporary build resource groups leaked by an earlier hard failure
# before starting a new build. Age-guarded and imogen-scoped, so it never touches
# a running build or another tenant's Packer groups.
"$DIR/hack/gc-build-rgs.sh" --apply || echo "warning: build-rg sweep failed, continuing" >&2

# Sweep managed images left behind by earlier successful builds. Same age and
# tag guards, so an image a running build is still publishing from is untouched.
"$DIR/hack/gc-build-images.sh" --apply || echo "warning: build-image sweep failed, continuing" >&2

echo "Applying build Job $NAME (target $TARGET) to $CLUSTER"
# A Job spec is immutable, so re-running a build for the same flavor and version
# (after an earlier failure, or to rebuild and replace an image) would fail
# "field is immutable" on a plain apply. Force-recreate so the build always starts
# fresh; replace --force deletes any prior Job of this name and recreates it in one
# step, and still creates the Job when none exists.
sed \
  -e "s|__NAME__|${NAME}|g" \
  -e "s|__FLAVOR__|${FLAVOR}|g" \
  -e "s|__IMAGE__|${BUILDER_IMAGE}|g" \
  -e "s|__TARGET__|${TARGET}|g" \
  -e "s|__SUBSCRIPTION_ID__|${SUBSCRIPTION_ID}|g" \
  -e "s|__LOCATION__|${LOCATION}|g" \
  -e "s|__CLIENT_ID__|${CLIENT_ID}|g" \
  -e "s|__RESOURCE_GROUP__|${RESOURCE_GROUP}|g" \
  -e "s|__GALLERY__|${STAGING_GALLERY}|g" \
  -e "s|__PACKER_FLAGS__|${PACKER_FLAGS}|g" \
  -e "s|__BUILD_TAG__|${NAME}|g" \
  -e "s|__BUILD_TS__|${BUILD_TS}|g" \
  -e "s|__BUILD_ATTEMPT__|${BUILD_ATTEMPT}|g" \
  "$DIR/deploy/build-job.yaml" | kubectl --kubeconfig "$WL_KUBECONFIG" replace --force -f - >/dev/null

echo "$NAME"
