#!/usr/bin/env bash
# validate-air-gap-localization.sh — prove that air-gap localization covers
# EVERY deployed image, on BOTH deploy paths.
#
# It runs hack/localize-images.sh against a throwaway copy of the repo using a
# sentinel registry, then asserts that every rendered image reference — from the
# single-instance Kustomize overlay AND the multi-instance KRO
# ResourceGraphDefinition — points at that registry. Any image still resolving
# to a public registry (Docker Hub short names, ghcr.io, docker.io, ...) is a
# localization gap and fails the check.
#
# The work happens in a tempdir so the localization (which rewrites the KRO RGD
# in place) never touches the working tree.
#
# Usage: validate-air-gap-localization.sh

set -euo pipefail

TEST_REGISTRY="test.invalid/airgap"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v kustomize >/dev/null 2>&1; then
  echo "ERROR: required tool not found: kustomize" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/hack" "$WORK/ocm" "$WORK/deploy"
cp "$REPO_ROOT/hack/localize-images.sh" "$REPO_ROOT/hack/list-ocm-images.sh" "$WORK/hack/"
cp "$REPO_ROOT/ocm/component-descriptor.yaml" "$WORK/ocm/"
cp -R "$REPO_ROOT/deploy/." "$WORK/deploy/"

bash "$WORK/hack/localize-images.sh" --registry "$TEST_REGISTRY" >/dev/null

# Extract image references, handling both "image:" and "- image:" forms.
strip_image_lines() {
  grep -E '^[[:space:]]*-?[[:space:]]*image:[[:space:]]' \
    | sed -E 's/^[[:space:]]*-?[[:space:]]*image:[[:space:]]*//; s/["'\''"]//g; s/[[:space:]]+#.*//'
}

deployed="$(
  {
    kustomize build "$WORK/deploy/overlays/air-gap" | strip_image_lines
    strip_image_lines < "$WORK/deploy/kro/powerdns-instance-rgd.yaml"
  } | sort -u
)"

if [[ -z "$deployed" ]]; then
  echo "ERROR: no image references found to validate." >&2
  exit 1
fi

leaked="$(printf '%s\n' "$deployed" | grep -v -E "^${TEST_REGISTRY}/" || true)"

if [[ -n "$leaked" ]]; then
  echo "ERROR: images NOT localized to the private registry (would pull from a public registry in an air-gapped cluster):" >&2
  while IFS= read -r img; do
    [[ -n "$img" ]] && echo "  - $img" >&2
  done <<<"$leaked"
  echo "  -> add the image to the OCM descriptor and re-run hack/localize-images.sh; both the overlay and the KRO RGD must be covered." >&2
  exit 1
fi

count="$(printf '%s\n' "$deployed" | grep -c .)"
echo "OK: all ${count} air-gap image reference(s) point at the private registry (overlay + KRO RGD)."
