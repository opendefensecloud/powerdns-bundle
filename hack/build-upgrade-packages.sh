#!/usr/bin/env bash
# Builds two OCM packages for the upgrade smoke test and extracts each package's
# deploy manifests ready for `kubectl apply -k`:
#
#   - baseline : a synthetic previous release built from the current sources.
#   - candidate: the upgrade target (next component version).
#
# Reference upgrade scenario (PoC):
#   - component version : 0.1.0-poc -> 0.1.1-poc
#   - pdns-auth image   : 4.9.14    -> 4.9.16   (4.9.16 is the current repo pin)
#
# Both image tags are real, pullable upstream releases, so the upgrade is a
# genuine forward image bump that triggers a pdns-auth rollout.
#
# Usage: hack/build-upgrade-packages.sh <work-dir>
# Outputs (deterministic paths under <work-dir>):
#   <work-dir>/baseline/ocm/ctf.tar   + <work-dir>/baseline/extract
#   <work-dir>/candidate/ocm/ctf.tar  + <work-dir>/candidate/extract
# When $GITHUB_ENV is set, exports BASELINE_DIR / CANDIDATE_DIR /
# BASELINE_AUTH_IMAGE / CANDIDATE_AUTH_IMAGE / BASELINE_CTF / CANDIDATE_CTF.
set -euo pipefail

COMPONENT_NAME="github.com/bwi/powerdns-ocm"
BASELINE_VERSION="0.1.0-poc"
CANDIDATE_VERSION="0.1.1-poc"
AUTH_IMAGE="powerdns/pdns-auth-49"
REPO_AUTH_TAG="4.9.16"
BASELINE_AUTH_TAG="4.9.14"
CANDIDATE_AUTH_TAG="4.9.16"

WORK="${1:?usage: build-upgrade-packages.sh <work-dir>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OCM_BIN="${OCM_BIN:-ocm}"

# Builds one package in an isolated workspace that preserves the repository
# layout (the descriptor references the deploy tree via the relative path
# `../deploy`, so `ocm/` and `deploy/` must remain siblings).
build_package() {
  local name="$1" version="$2" auth_tag="$3"
  local ws="${WORK}/${name}"
  local descriptor="${ws}/ocm/component-descriptor.yaml"

  rm -rf "$ws"
  mkdir -p "$ws"
  cp -r "${REPO_ROOT}/ocm" "${REPO_ROOT}/deploy" "$ws/"

  # Pin the authoritative image to the scenario tag across manifests + descriptor.
  # The repository ref is digest-pinned, but the upgrade scenario deliberately
  # swaps the auth version, so drop the (tag-specific) digest here and let the
  # scenario tag resolve to its own image. Other images keep their pinned digests.
  find "${ws}/deploy" -type f -exec \
    sed -i -E "s#${AUTH_IMAGE}:${REPO_AUTH_TAG}(@sha256:[0-9a-f]{64})?#${AUTH_IMAGE}:${auth_tag}#g" {} +
  sed -i -E "s#${AUTH_IMAGE}:${REPO_AUTH_TAG}(@sha256:[0-9a-f]{64})?#${AUTH_IMAGE}:${auth_tag}#g" "$descriptor"

  # Set the component version and the bundled-resource versions.
  sed -i "s/^version: ${BASELINE_VERSION}\$/version: ${version}/" "$descriptor"
  sed -i "s/version: \"${BASELINE_VERSION}\"/version: \"${version}\"/g" "$descriptor"

  ( cd "$ws" \
    && rm -f ocm/ctf.tar \
    && "$OCM_BIN" add componentversions \
         --type tar --create --file ocm/ctf.tar ocm/component-descriptor.yaml )

  local ref="${COMPONENT_NAME}:${version}"
  local out="${ws}/extract"
  rm -rf "$out"
  "$OCM_BIN" download resources --downloader ocm/dirtree \
    "${ws}/ocm/ctf.tar//${ref}" deploy-manifests -O "$out"

  test -d "${out}/base"
  # Fail fast if the extracted manifests do not carry the intended image tag.
  grep -q "${AUTH_IMAGE}:${auth_tag}" "${out}/base/authoritative/deployment.yaml"

  echo "Built ${name}: ${ref} (${AUTH_IMAGE}:${auth_tag}) -> ${out}"
}

build_package baseline "$BASELINE_VERSION" "$BASELINE_AUTH_TAG"
build_package candidate "$CANDIDATE_VERSION" "$CANDIDATE_AUTH_TAG"

if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "BASELINE_DIR=${WORK}/baseline/extract"
    echo "CANDIDATE_DIR=${WORK}/candidate/extract"
    echo "BASELINE_CTF=${WORK}/baseline/ocm/ctf.tar"
    echo "CANDIDATE_CTF=${WORK}/candidate/ocm/ctf.tar"
    echo "BASELINE_AUTH_IMAGE=${AUTH_IMAGE}:${BASELINE_AUTH_TAG}"
    echo "CANDIDATE_AUTH_IMAGE=${AUTH_IMAGE}:${CANDIDATE_AUTH_TAG}"
  } >> "$GITHUB_ENV"
fi
