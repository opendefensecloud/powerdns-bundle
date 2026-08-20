#!/usr/bin/env bash
# validate-image-inventory.sh — verify the OCM component descriptor lists exactly
# the container images that the Kubernetes manifests deploy.
#
# The descriptor drives CVE scanning and air-gap transport: every image it lists
# is scanned and mirrored, and nothing else is. So the descriptor and the
# manifests must agree:
#   * an image deployed but absent from the descriptor ships unscanned and
#     unmirrored (a supply-chain hole);
#   * an image in the descriptor that no manifest deploys is dead weight.
# Either condition is drift and fails this check.
#
# Deployed images are collected from the single-instance base
# (kustomize build deploy) and the multi-instance ResourceGraphDefinition
# (kustomize build deploy/kro), which together cover every runtime image.
#
# Usage: validate-image-inventory.sh [descriptor]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESCRIPTOR="${1:-${REPO_ROOT}/ocm/component-descriptor.yaml}"

if ! command -v kustomize >/dev/null 2>&1; then
  echo "ERROR: required tool not found: kustomize" >&2
  exit 1
fi

# Collect image references from a rendered overlay, handling both the bare
# "image:" form and the "- image:" list-item form that kustomize emits.
collect_deployed() {
  kustomize build "$1" \
    | grep -E '^[[:space:]]*-?[[:space:]]*image:[[:space:]]' \
    | sed -E 's/^[[:space:]]*-?[[:space:]]*image:[[:space:]]*//; s/["'\''"]//g; s/[[:space:]]+#.*//'
}

deployed="$(
  {
    collect_deployed "${REPO_ROOT}/deploy"
    collect_deployed "${REPO_ROOT}/deploy/kro"
  } | sort -u
)"

declared="$(bash "${REPO_ROOT}/hack/list-ocm-images.sh" "$DESCRIPTOR" | sort -u)"

undeclared="$(comm -23 <(printf '%s\n' "$deployed") <(printf '%s\n' "$declared"))"
undeployed="$(comm -13 <(printf '%s\n' "$deployed") <(printf '%s\n' "$declared"))"

print_list() {
  while IFS= read -r img; do
    [[ -n "$img" ]] && echo "  - $img"
  done <<<"$1"
}

status=0

if [[ -n "$undeclared" ]]; then
  status=1
  echo "ERROR: images deployed by the manifests but missing from the descriptor:" >&2
  print_list "$undeclared" >&2
  echo "  -> add them to ocm/component-descriptor.yaml so they are scanned and mirrored." >&2
fi

if [[ -n "$undeployed" ]]; then
  status=1
  echo "ERROR: images declared in the descriptor but not deployed by any manifest:" >&2
  print_list "$undeployed" >&2
  echo "  -> remove the stale entry or add the manifest that uses it." >&2
fi

if [[ "$status" -eq 0 ]]; then
  count="$(printf '%s\n' "$declared" | grep -c .)"
  echo "OK: descriptor and manifests agree on ${count} container image(s)."
fi

exit "$status"
