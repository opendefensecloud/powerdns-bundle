#!/usr/bin/env bash
# Prints container image references declared in the OCM component descriptor.

set -euo pipefail

DESCRIPTOR="${1:-ocm/component-descriptor.yaml}"

if [[ ! -f "$DESCRIPTOR" ]]; then
  echo "ERROR: component descriptor not found: $DESCRIPTOR" >&2
  exit 1
fi

awk '
  /^[[:space:]]*imageReference:[[:space:]]*/ {
    value=$0
    sub(/^[[:space:]]*imageReference:[[:space:]]*/, "", value)
    sub(/[[:space:]]+#.*/, "", value)
    gsub(/^["'\''"]|["'\''"]$/, "", value)
    if (value != "" && value != "TBD") {
      print value
    }
  }
' "$DESCRIPTOR" | sort -u
