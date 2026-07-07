#!/usr/bin/env bash
# Installs a pinned Prometheus Operator bundle when its CRDs are not already
# available. Intended for CI and development clusters, not production upgrades.
set -euo pipefail

KUBECTL="${KUBECTL_BIN:-kubectl}"
CURL="${CURL_BIN:-curl}"
PROMETHEUS_OPERATOR_VERSION="${PROMETHEUS_OPERATOR_VERSION:-0.91.0}"
BUNDLE_URL="https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v${PROMETHEUS_OPERATOR_VERSION}/bundle.yaml"

require() {
  if ! command -v "$1" &>/dev/null; then
    echo "ERROR: '$1' is required but not installed." >&2
    exit 1
  fi
}

require "$KUBECTL"
require "$CURL"

if "$KUBECTL" get crd servicemonitors.monitoring.coreos.com &>/dev/null \
  && "$KUBECTL" get crd prometheuses.monitoring.coreos.com &>/dev/null; then
  echo "Prometheus Operator CRDs already exist; using the cluster installation."
  exit 0
fi

bundle="$(mktemp)"
trap 'rm -f "$bundle"' EXIT

echo "Installing Prometheus Operator v${PROMETHEUS_OPERATOR_VERSION}..."
"$CURL" -fsSL "$BUNDLE_URL" -o "$bundle"
"$KUBECTL" apply --server-side -f "$bundle"

"$KUBECTL" wait crd/servicemonitors.monitoring.coreos.com \
  --for=condition=Established --timeout=120s
"$KUBECTL" wait crd/prometheuses.monitoring.coreos.com \
  --for=condition=Established --timeout=120s
"$KUBECTL" wait deployment/prometheus-operator -n default \
  --for=condition=Available --timeout=180s

echo "Prometheus Operator is ready."
