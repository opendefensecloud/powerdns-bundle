#!/usr/bin/env bash
# Verifies the source-level observability contract in the base, KRO, and
# optional Prometheus Operator manifests.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

check_pattern() {
  local description="$1"
  local pattern="$2"
  local file="$3"

  if grep -Eq -- "$pattern" "${ROOT_DIR}/${file}"; then
    echo "  PASS  ${description}"
    ((PASS++)) || true
  else
    echo "  FAIL  ${description} (${file})"
    ((FAIL++)) || true
  fi
}

check_count() {
  local description="$1"
  local pattern="$2"
  local expected="$3"
  local file="$4"
  local actual

  actual="$(grep -Ec -- "$pattern" "${ROOT_DIR}/${file}" || true)"
  if [[ "$actual" -eq "$expected" ]]; then
    echo "  PASS  ${description}"
    ((PASS++)) || true
  else
    echo "  FAIL  ${description}: expected ${expected}, found ${actual} (${file})"
    ((FAIL++)) || true
  fi
}

echo "=== Observability Manifest Validation ==="

echo
echo "--- Recursor metrics endpoint ---"
check_pattern "base Recursor enables the webserver" \
  '^[[:space:]]+webserver=yes$' deploy/base/recursor/configmap.yaml
check_pattern "base Recursor binds metrics port 8082" \
  '^[[:space:]]+webserver-port=8082$' deploy/base/recursor/configmap.yaml
check_pattern "base Recursor Service exposes the metrics port" \
  '^[[:space:]]+- name: metrics$' deploy/base/recursor/service.yaml
check_pattern "KRO Recursor binds metrics port 8082" \
  '^[[:space:]]+webserver-port=8082$' deploy/kro/powerdns-instance-rgd.yaml

echo
echo "--- Authoritative and Operator metrics Services ---"
check_pattern "Authoritative Service advertises /metrics" \
  '^[[:space:]]+prometheus.io/path: /metrics$' deploy/base/authoritative/service.yaml
check_pattern "Operator metrics Service is included by Kustomize" \
  '^[[:space:]]+- service.yaml$' deploy/base/operator/kustomization.yaml
check_pattern "Operator Service targets the controller-runtime metrics port" \
  '^[[:space:]]+targetPort: metrics$' deploy/base/operator/service.yaml
check_pattern "KRO includes the Operator metrics Service" \
  '^[[:space:]]+- id: serviceOperatorMetrics$' deploy/kro/powerdns-instance-rgd.yaml

echo
echo "--- Lightning Stream sync metrics ---"
# The sync sidecar fails silently (stalled replication, full PVC), so its
# metrics endpoint must stay wired end to end: config -> Service -> scrape.
check_count "both Auth Services expose the Lightning Stream metrics port" \
  '^[[:space:]]+- name: ls-metrics$' 1 deploy/base/authoritative/service.yaml
check_pattern "KRO Auth Service exposes the Lightning Stream metrics port" \
  '^[[:space:]]+targetPort: ls-metrics$' deploy/kro/powerdns-instance-rgd.yaml
check_pattern "Authoritative ServiceMonitor scrapes the sync sidecar" \
  '^[[:space:]]+- port: ls-metrics$' deploy/overlays/monitoring/service-monitors.yaml
check_pattern "NetworkPolicy admits monitoring to the sync metrics port" \
  '^[[:space:]]+port: 8500$' deploy/base/network-policies/auth.yaml
check_pattern "live validation scrapes the sync sidecar endpoint" \
  'check_metrics "Lightning Stream"' hack/validate-observability.sh

echo
echo "--- Prometheus discovery ---"
check_count "Authoritative Service enables annotation-based discovery" \
  '^[[:space:]]+prometheus.io/scrape: "true"$' 1 deploy/base/authoritative/service.yaml
# This aggregate catches accidental removal from any source without depending
# on rendered output.
base_scrape_count="$(
  grep -hEc '^[[:space:]]+prometheus.io/scrape: "true"$' \
    "${ROOT_DIR}/deploy/base/authoritative/service.yaml" \
    "${ROOT_DIR}/deploy/base/recursor/service.yaml" \
    "${ROOT_DIR}/deploy/base/operator/service.yaml" \
    | awk '{sum += $1} END {print sum + 0}'
)"
if [[ "$base_scrape_count" -eq 3 ]]; then
  echo "  PASS  all three base Services enable annotation-based discovery"
  ((PASS++)) || true
else
  echo "  FAIL  expected three base scrape annotations, found ${base_scrape_count}"
  ((FAIL++)) || true
fi
check_count "KRO Services contain three scrape annotations" \
  '^[[:space:]]+prometheus.io/scrape: "true"$' 3 deploy/kro/powerdns-instance-rgd.yaml
check_count "monitoring overlay defines three ServiceMonitors" \
  '^kind: ServiceMonitor$' 3 deploy/overlays/monitoring/service-monitors.yaml
check_pattern "CI fixture defines a Prometheus instance" \
  '^kind: Prometheus$' hack/ci/prometheus.yaml
check_pattern "CI Prometheus selects PowerDNS ServiceMonitors" \
  '^[[:space:]]+app.kubernetes.io/part-of: powerdns$' hack/ci/prometheus.yaml
check_pattern "CI deploys the packaged ServiceMonitors" \
  'kubectl apply -f.*service-monitors.yaml' .github/workflows/ci.yml
check_pattern "live validation queries Prometheus target health" \
  '/api/v1/targets' hack/validate-observability.sh

echo
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
