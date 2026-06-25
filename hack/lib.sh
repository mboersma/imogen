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
