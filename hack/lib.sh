#!/usr/bin/env bash
#
# Shared helpers sourced by the imogen setup scripts.

# imogen_require_sku <vm-size> <location>
#
# Fail fast when a VM size is not offered or is restricted for the subscription
# in a location, instead of letting AKS or CAPZ fail later with an opaque
# SkuNotAvailable. Prints a sample of available small sizes to help pick one.
imogen_require_sku() {
  local sku="$1" loc="$2" json reasons
  json="$(az vm list-skus --location "$loc" --resource-type virtualMachines \
    --query "[?name=='${sku}'] | [0]" -o json 2>/dev/null)"
  if [[ -z "$json" || "$json" == "null" ]]; then
    echo "ERROR: VM size '${sku}' is not offered in ${loc}." >&2
    _imogen_suggest_skus "$loc"
    return 1
  fi
  reasons="$(printf '%s' "$json" | jq -r '.restrictions[]?.reasonCode' 2>/dev/null | sort -u | paste -sd, -)"
  if [[ -n "$reasons" ]]; then
    echo "ERROR: VM size '${sku}' is restricted in ${loc} (${reasons})." >&2
    _imogen_suggest_skus "$loc"
    return 1
  fi
}

_imogen_suggest_skus() {
  local loc="$1"
  echo "Available small sizes in ${loc} (sample):" >&2
  az vm list-skus --location "$loc" --resource-type virtualMachines -o json 2>/dev/null \
    | jq -r '.[] | select((.restrictions | length) == 0) | .name' 2>/dev/null \
    | grep -iE '^Standard_(B2|B4|D2|D4)[a-z]*s' | sort -u | head -12 | sed 's/^/  /' >&2 || true
}

# imogen_protect_rg <resource-group>
#
# Tag a persistent resource group so the CNCF subscription's cleanup reaper skips
# it. The galleries, ACR, identities and OpenAI account are not reconstructible
# from scripts (published community images especially), so the foundation RG must
# never be reaped. Merges the tag so it does not clobber tags Azure adds, and is
# idempotent so re-running a setup script keeps the RG protected.
imogen_protect_rg() {
  local rg="$1" id
  local key="${IMOGEN_PERSIST_TAG_KEY:-DO-NOT-DELETE}"
  local val="${IMOGEN_PERSIST_TAG_VALUE:-UpstreamInfra}"
  id="$(az group show -n "$rg" --query id -o tsv 2>/dev/null)" || return 0
  [[ -z "$id" ]] && return 0
  az tag update --resource-id "$id" --operation Merge --tags "${key}=${val}" -o none
  echo "tagged resource group ${rg} ${key}=${val}"
}

# imogen_builder_kubeconfig
#
# Write a kubeconfig for the builder workload cluster to a new temp file and echo
# its path. In cluster (IMOGEN_IN_CLUSTER=1) the tool server reads the CAPI
# kubeconfig secret directly, since clusterctl is not bundled and there is no
# named context. On a workstation it uses clusterctl against the mgmt context.
imogen_builder_kubeconfig() {
  local cluster="${IMOGEN_BUILDER_CLUSTER:-imogen-builder}"
  local ns="${IMOGEN_BUILDER_KUBECONFIG_NAMESPACE:-default}"
  local out
  out="$(mktemp -t imogen-builder-kubeconfig-XXXX)"
  if [[ "${IMOGEN_IN_CLUSTER:-}" == "1" ]]; then
    kubectl get secret "${cluster}-kubeconfig" -n "$ns" \
      -o jsonpath='{.data.value}' | base64 -d > "$out"
  else
    kubectl config use-context "${IMOGEN_MGMT_CLUSTER:-imogen-mgmt}" >/dev/null
    clusterctl get kubeconfig "$cluster" > "$out"
  fi
  echo "$out"
}

# imogen_k8s_deb_version <series> <patch>
#
# Echo the exact Kubernetes .deb package version (such as 1.36.2-2.1) published
# for a patch release, read from the community apt repo index. The Debian package
# revision is usually -1.1, but the release team occasionally rebuilds packages
# and bumps it (1.36.2 shipped as -2.1), so hardcoding -1.1 makes those builds
# fail with "no available installation candidate". Retries the lookup a few times
# to ride out a transient network blip, then fails (non-zero, message on stderr)
# rather than guessing a revision that would only break the build minutes later.
imogen_k8s_deb_version() {
  local series="$1" patch="$2" url found attempt
  url="https://pkgs.k8s.io/core:/stable:/${series}/deb/Packages.gz"
  for attempt in 1 2 3; do
    found="$(curl -fsSL "$url" 2>/dev/null | gunzip -c 2>/dev/null \
      | awk '/^Package: kubelet$/{k=1;next} /^Package: /{k=0} k&&/^Version:/{print $2}' \
      | grep -E "^${patch//./\\.}-" | sort -V | tail -1)"
    if [[ -n "$found" ]]; then
      echo "$found"
      return 0
    fi
    [[ "$attempt" -lt 3 ]] && sleep $((attempt * 3))
  done
  echo "imogen_k8s_deb_version: could not resolve a kubelet deb revision for ${patch} in series ${series} from ${url}" >&2
  return 1
}
