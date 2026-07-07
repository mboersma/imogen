#!/usr/bin/env bash
#
# Validate a staging gallery image by booting a node from it on the builder
# cluster and asserting it joins, runs the expected kubelet, and can run a pod.
#
# This attaches a one-node MachineDeployment to the builder workload cluster
# whose image points at the staging gallery version, waits for the node to be
# Ready, checks the kubelet version, runs a smoke pod, then tears it all down.
#
# Usage: hack/validate-image.sh <flavor> <version>
#   e.g. hack/validate-image.sh ubuntu-2404 1.34.9
#
# Set IMOGEN_VALIDATE_KEEP=1 to leave the validation node up for inspection.

set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -f "$(dirname "$0")/foundation.env" ]]; then
  # shellcheck disable=SC1091
  source "$(dirname "$0")/foundation.env"
fi
# shellcheck source=hack/lib.sh
source "$(dirname "$0")/lib.sh"

FLAVOR="${1:-}"
VERSION="${2:-}"
if [[ -z "$FLAVOR" || -z "$VERSION" ]]; then
  echo "usage: $0 <flavor> <version>" >&2
  exit 1
fi

SUBSCRIPTION_ID="${IMOGEN_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
RESOURCE_GROUP="${IMOGEN_RESOURCE_GROUP:-imogen}"
STAGING_GALLERY="${IMOGEN_STAGING_GALLERY:-imogen_staging}"
GALLERY_LOCATION="${IMOGEN_LOCATION:-westus3}"
CLUSTER="${IMOGEN_BUILDER_CLUSTER:-imogen-builder}"
# Namespace the CAPI objects live in on the mgmt cluster (see run-build-job.sh).
CAPI_NS="${IMOGEN_CAPI_NAMESPACE:-default}"
# Namespace for the smoke pod on the builder workload cluster. In cluster kubectl
# would otherwise inherit the tool server pod's namespace ("kagent"), which does
# not exist on the builder cluster, so pin it explicitly.
SMOKE_NS="${IMOGEN_VALIDATE_POD_NAMESPACE:-default}"
BUILDER_LOCATION="${IMOGEN_BUILDER_LOCATION:-${IMOGEN_MGMT_LOCATION:-eastus2}}"
NODE_SIZE="${IMOGEN_BUILDER_NODE_SIZE:-Standard_D2s_v3}"

IMAGE_VERSION="${VERSION#v}"
K8S_VERSION="v${IMAGE_VERSION}"
IMAGE_DEFINITION="capi-${FLAVOR}"

# Give up on a version that keeps failing validation. The validate-image tool
# retries a Failed run (a node join, especially Windows, can flake), and the
# reconcile loop re-invokes it every pass until it Succeeds, so a genuinely broken
# image would boot a fresh node forever. Count attempts in a small state file and,
# once the cap is reached, refuse fast (before booting a VM) so get-validation-status
# keeps reporting Failed and a human is asked to look instead.
VALIDATE_MAX_ATTEMPTS="${IMOGEN_VALIDATE_MAX_ATTEMPTS:-3}"
VALIDATE_STATE_DIR="${IMOGEN_VALIDATE_STATE_DIR:-${TMPDIR:-/tmp}}"
ATTEMPT_KEY="$(printf '%s' "${FLAVOR}-${IMAGE_VERSION}" | tr -c 'A-Za-z0-9._-' '-')"
ATTEMPT_FILE="${VALIDATE_STATE_DIR%/}/imogen-validate-${ATTEMPT_KEY}.attempts"
ATTEMPTS="$(cat "$ATTEMPT_FILE" 2>/dev/null || echo 0)"
[[ "$ATTEMPTS" =~ ^[0-9]+$ ]] || ATTEMPTS=0
if [[ "$ATTEMPTS" -ge "$VALIDATE_MAX_ATTEMPTS" ]]; then
  echo "Validation of ${FLAVOR} ${IMAGE_VERSION} has failed ${ATTEMPTS} time(s), at the ${VALIDATE_MAX_ATTEMPTS}-attempt cap; not retrying. A human should investigate before it is validated again." >&2
  exit 1
fi
echo $((ATTEMPTS + 1)) > "$ATTEMPT_FILE"

# Windows validation differs from Linux: it uses a Windows MachineDeployment
# template, applies a version-matched Windows kube-proxy DaemonSet (the builder
# already carries Calico HNS and the Windows cloud-node-manager), waits longer
# for the Windows networking stack to converge, and runs a HostProcess smoke pod.
case "$FLAVOR" in
windows-*)
  OS_TYPE="windows"
  TEMPLATE="$DIR/deploy/validation-machinedeployment-windows.yaml"
  NAME="${CLUSTER}-vwin"
  READY_TIMEOUT="1800s"
  NODE_WAIT_TRIES=120
  case "$FLAVOR" in
  *2025*) SMOKE_IMAGE="mcr.microsoft.com/windows/nanoserver:ltsc2025" ;;
  *) SMOKE_IMAGE="mcr.microsoft.com/windows/nanoserver:ltsc2022" ;;
  esac
  ;;
*)
  OS_TYPE="linux"
  TEMPLATE="$DIR/deploy/validation-machinedeployment.yaml"
  NAME="${CLUSTER}-validate"
  READY_TIMEOUT="600s"
  NODE_WAIT_TRIES=60
  SMOKE_IMAGE="registry.k8s.io/busybox:1.27"
  ;;
esac

# The image must be replicated to the builder cluster's region. The build
# publishes to the gallery's home region, so add the builder region if missing.
echo "Checking image replication to ${BUILDER_LOCATION}"
HAVE="$(az sig image-version show -g "$RESOURCE_GROUP" -r "$STAGING_GALLERY" \
  -i "$IMAGE_DEFINITION" -e "$IMAGE_VERSION" \
  --query "publishingProfile.targetRegions[].name" -o tsv | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
WANT="$(echo "$BUILDER_LOCATION" | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
if ! grep -qx "$WANT" <<<"$HAVE"; then
  echo "Replicating ${IMAGE_DEFINITION} ${IMAGE_VERSION} to ${BUILDER_LOCATION} (a few minutes)"
  az sig image-version update -g "$RESOURCE_GROUP" -r "$STAGING_GALLERY" \
    -i "$IMAGE_DEFINITION" -e "$IMAGE_VERSION" \
    --target-regions "$GALLERY_LOCATION" "$BUILDER_LOCATION" -o none
fi

# In cluster the tool server already runs against the management cluster via its
# service account; on a workstation imogen_builder_kubeconfig selects the mgmt
# context. Either way it writes a kubeconfig for the builder workload cluster.
WL_KUBECONFIG="$(imogen_builder_kubeconfig)"

cleanup() {
  if [[ "${IMOGEN_VALIDATE_KEEP:-}" == "1" ]]; then
    echo "IMOGEN_VALIDATE_KEEP set, leaving $NAME in place"
    echo "Workload kubeconfig: $WL_KUBECONFIG"
    return
  fi
  echo "Tearing down $NAME"
  kubectl --kubeconfig "$WL_KUBECONFIG" delete pod "${NAME}-smoke" -n "$SMOKE_NS" --ignore-not-found >/dev/null 2>&1 || true
  if [[ "$OS_TYPE" == "windows" ]]; then
    kubectl --kubeconfig "$WL_KUBECONFIG" delete pod "${NAME}-kubelet-kick" -n "$SMOKE_NS" --ignore-not-found >/dev/null 2>&1 || true
    kubectl --kubeconfig "$WL_KUBECONFIG" delete daemonset kube-proxy-windows -n kube-system --ignore-not-found >/dev/null 2>&1 || true
  fi
  kubectl delete machinedeployment "$NAME" -n "$CAPI_NS" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete kubeadmconfigtemplate "$NAME" -n "$CAPI_NS" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete azuremachinetemplate "$NAME" -n "$CAPI_NS" --ignore-not-found >/dev/null 2>&1 || true
  rm -f "$WL_KUBECONFIG"
}
trap cleanup EXIT

# Restart the kubelet on a Windows validation node via a HostProcess pod. This
# recovers the kubelet after Calico's HNS vSwitch creation freezes its apiserver
# connection; the image's own RestartKubelet.ps1 runs too early (right after
# kubeadm join, before the vSwitch exists) to cover that case.
windows_restart_kubelet() {
  local node="$1"
  local kp="${NAME}-kubelet-kick"
  kubectl --kubeconfig "$WL_KUBECONFIG" delete pod "$kp" -n "$SMOKE_NS" --ignore-not-found >/dev/null 2>&1 || true
  kubectl --kubeconfig "$WL_KUBECONFIG" run "$kp" -n "$SMOKE_NS" \
    --image="$SMOKE_IMAGE" --restart=Never \
    --overrides="{\"spec\":{\"nodeName\":\"${node}\",\"hostNetwork\":true,\"securityContext\":{\"windowsOptions\":{\"hostProcess\":true,\"runAsUserName\":\"NT AUTHORITY\\\\SYSTEM\"}},\"nodeSelector\":{\"kubernetes.io/os\":\"windows\"},\"tolerations\":[{\"operator\":\"Exists\"}]}}" \
    --command -- powershell -Command "if (Test-Path C:/k/RestartKubelet.ps1) { & C:/k/RestartKubelet.ps1 } else { Restart-Service kubelet }" >/dev/null 2>&1 || true
  kubectl --kubeconfig "$WL_KUBECONFIG" wait --for=jsonpath='{.status.phase}'=Succeeded \
    "pod/$kp" -n "$SMOKE_NS" --timeout=120s >/dev/null 2>&1 || true
  kubectl --kubeconfig "$WL_KUBECONFIG" delete pod "$kp" -n "$SMOKE_NS" --ignore-not-found >/dev/null 2>&1 || true
}

echo "Validating ${IMAGE_DEFINITION} ${IMAGE_VERSION} from ${STAGING_GALLERY}"
sed \
  -e "s|__NAME__|${NAME}|g" \
  -e "s|__CLUSTER__|${CLUSTER}|g" \
  -e "s|__K8S_VERSION__|${K8S_VERSION}|g" \
  -e "s|__VM_SIZE__|${NODE_SIZE}|g" \
  -e "s|__SUBSCRIPTION_ID__|${SUBSCRIPTION_ID}|g" \
  -e "s|__RESOURCE_GROUP__|${RESOURCE_GROUP}|g" \
  -e "s|__GALLERY__|${STAGING_GALLERY}|g" \
  -e "s|__IMAGE_DEFINITION__|${IMAGE_DEFINITION}|g" \
  -e "s|__IMAGE_VERSION__|${IMAGE_VERSION}|g" \
  "$TEMPLATE" | kubectl apply -n "$CAPI_NS" -f -

# Windows nodes need a version-matched kube-proxy running as a HostProcess
# DaemonSet. It targets Windows nodes only, so it waits with zero pods until the
# validation node joins, then schedules. Torn down with the rest on exit.
if [[ "$OS_TYPE" == "windows" ]]; then
  echo "Applying Windows kube-proxy ${K8S_VERSION}"
  sed -e "s|__KUBERNETES_VERSION__|${K8S_VERSION}|g" \
    "$DIR/deploy/kube-proxy-windows.yaml" | kubectl --kubeconfig "$WL_KUBECONFIG" apply -f -
fi

echo "Waiting for the validation machine to get a node (this boots a VM)"
NODE=""
if [[ "$OS_TYPE" == "windows" ]]; then
  # The image-builder sc.exe kubelet service registers the node on the initial
  # kubeadm join, before RestartKubelet.ps1 re-creates the service with
  # cloud-provider=external, so the node never self-adds the cloud-provider
  # "uninitialized" taint. Without that taint cloud-node-manager skips the node
  # and never sets its providerID, so CAPI cannot link the node by providerID.
  # Discover the node directly on the builder cluster, then add the taint if the
  # node has no providerID; cloud-node-manager then sets providerID and clears the
  # taint, which also lets CAPI link the Machine.
  for _ in $(seq 1 "$NODE_WAIT_TRIES"); do
    NODE="$(kubectl --kubeconfig "$WL_KUBECONFIG" get nodes -l kubernetes.io/os=windows \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [[ -n "$NODE" ]] && break
    sleep 15
  done
  if [[ -z "$NODE" ]]; then
    echo "FAIL: no Windows node registered on the builder cluster" >&2
    exit 1
  fi
  echo "Node: $NODE"
  if [[ -z "$(kubectl --kubeconfig "$WL_KUBECONFIG" get node "$NODE" \
    -o jsonpath='{.spec.providerID}' 2>/dev/null || true)" ]]; then
    echo "Node has no providerID; applying cloud-provider uninitialized taint"
    kubectl --kubeconfig "$WL_KUBECONFIG" taint node "$NODE" \
      node.cloudprovider.kubernetes.io/uninitialized=true:NoSchedule --overwrite || true
  fi
else
  for _ in $(seq 1 "$NODE_WAIT_TRIES"); do
    NODE="$(kubectl get machines -l "cluster.x-k8s.io/deployment-name=${NAME}" -n "$CAPI_NS" \
      -o jsonpath='{.items[0].status.nodeRef.name}' 2>/dev/null || true)"
    [[ -n "$NODE" ]] && break
    sleep 15
  done
  if [[ -z "$NODE" ]]; then
    echo "FAIL: validation machine never registered a node" >&2
    exit 1
  fi
  echo "Node: $NODE"
fi

echo "Waiting for $NODE to be Ready"
if [[ "$OS_TYPE" == "windows" ]]; then
  # When Calico creates the HNS vSwitch the kubelet's apiserver connection
  # freezes and its node heartbeat stops advancing, leaving the node NotReady
  # ("cni plugin not initialized"). The image's RestartKubelet.ps1 already ran
  # right after join, too early to help. Detect the frozen kubelet (heartbeat no
  # longer advancing) and restart it again until the node goes Ready.
  ready=""
  kicks=0
  prev_hb=""
  stale=0
  deadline=$(( $(date +%s) + ${READY_TIMEOUT%s} ))
  while [[ $(date +%s) -lt $deadline ]]; do
    if [[ "$(kubectl --kubeconfig "$WL_KUBECONFIG" get node "$NODE" \
      -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null)" == "True" ]]; then
      ready=1
      break
    fi
    hb="$(kubectl --kubeconfig "$WL_KUBECONFIG" get node "$NODE" \
      -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.lastHeartbeatTime}{end}' 2>/dev/null || true)"
    if [[ -n "$hb" && "$hb" == "$prev_hb" ]]; then
      stale=$(( stale + 1 ))
    else
      stale=0
      prev_hb="$hb"
    fi
    # ~90s (6 * 15s) without the heartbeat advancing means the kubelet is frozen.
    if [[ $stale -ge 6 && $kicks -lt 8 ]]; then
      echo "kubelet heartbeat frozen on $NODE; restarting kubelet"
      windows_restart_kubelet "$NODE"
      kicks=$(( kicks + 1 ))
      stale=0
      prev_hb=""
    fi
    sleep 15
  done
  if [[ -z "$ready" ]]; then
    echo "FAIL: $NODE did not become Ready" >&2
    exit 1
  fi
elif ! kubectl --kubeconfig "$WL_KUBECONFIG" wait --for=condition=Ready "node/${NODE}" --timeout="$READY_TIMEOUT"; then
  echo "FAIL: $NODE did not become Ready" >&2
  exit 1
fi

KUBELET="$(kubectl --kubeconfig "$WL_KUBECONFIG" get node "$NODE" -o jsonpath='{.status.nodeInfo.kubeletVersion}')"
RUNTIME="$(kubectl --kubeconfig "$WL_KUBECONFIG" get node "$NODE" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}')"
echo "kubelet:  $KUBELET (expected $K8S_VERSION)"
echo "runtime:  $RUNTIME"
if [[ "$KUBELET" != "$K8S_VERSION" ]]; then
  echo "FAIL: kubelet version $KUBELET does not match expected $K8S_VERSION" >&2
  exit 1
fi
if [[ "$RUNTIME" != containerd://* ]]; then
  echo "FAIL: unexpected container runtime $RUNTIME" >&2
  exit 1
fi

echo "Running a smoke pod on $NODE"
# hostNetwork so the smoke does not wait on the CNI on the fresh node; we are
# validating the image's kubelet and container runtime, not pod networking. On
# Windows this is a HostProcess pod (the Windows analog of hostNetwork), which
# runs the command directly on the host.
if [[ "$OS_TYPE" == "windows" ]]; then
  kubectl --kubeconfig "$WL_KUBECONFIG" run "${NAME}-smoke" -n "$SMOKE_NS" \
    --image="$SMOKE_IMAGE" --restart=Never \
    --overrides="{\"spec\":{\"nodeName\":\"${NODE}\",\"hostNetwork\":true,\"securityContext\":{\"windowsOptions\":{\"hostProcess\":true,\"runAsUserName\":\"NT AUTHORITY\\\\SYSTEM\"}},\"nodeSelector\":{\"kubernetes.io/os\":\"windows\"},\"tolerations\":[{\"operator\":\"Exists\"}]}}" \
    --command -- cmd /c echo smoke-ok
else
  kubectl --kubeconfig "$WL_KUBECONFIG" run "${NAME}-smoke" -n "$SMOKE_NS" \
    --image="$SMOKE_IMAGE" --restart=Never \
    --overrides="{\"spec\":{\"nodeName\":\"${NODE}\",\"hostNetwork\":true,\"tolerations\":[{\"operator\":\"Exists\"}]}}" \
    --command -- /bin/sh -c 'echo smoke-ok'
fi
if ! kubectl --kubeconfig "$WL_KUBECONFIG" wait --for=jsonpath='{.status.phase}'=Succeeded \
  "pod/${NAME}-smoke" -n "$SMOKE_NS" --timeout=180s; then
  echo "FAIL: smoke pod did not succeed" >&2
  kubectl --kubeconfig "$WL_KUBECONFIG" describe pod "${NAME}-smoke" -n "$SMOKE_NS" >&2 || true
  exit 1
fi

echo
# Validation passed, so clear the failure counter: a later re-validation of this
# version (after a rebuild) starts fresh rather than inheriting old failures.
rm -f "$ATTEMPT_FILE"
echo "PASS: ${IMAGE_DEFINITION} ${IMAGE_VERSION} booted, ran kubelet ${KUBELET}, and scheduled a pod."
