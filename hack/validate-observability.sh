#!/usr/bin/env bash
# Validates that the Recursor, Authoritative Server, Operator, and Lightning
# Stream metrics endpoints are reachable through their Kubernetes Services and
# return Prometheus exposition data. Also verifies that the deployed
# ServiceMonitors are selected and all four targets are healthy in Prometheus.
# Usage: NAMESPACE=dns ./hack/validate-observability.sh
set -euo pipefail

NAMESPACE="${NAMESPACE:-dns}"
# Prometheus and its Service live in a dedicated monitoring namespace; the
# ServiceMonitors and scrape targets remain in the workload namespace above.
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
KUBECTL="${KUBECTL_BIN:-kubectl}"
CURL="${CURL_BIN:-curl}"
METRICS_TIMEOUT="${METRICS_TIMEOUT:-30}"
REC_LOCAL_PORT="${REC_LOCAL_PORT:-18082}"
AUTH_LOCAL_PORT="${AUTH_LOCAL_PORT:-18081}"
LS_LOCAL_PORT="${LS_LOCAL_PORT:-18500}"
OPERATOR_LOCAL_PORT="${OPERATOR_LOCAL_PORT:-18080}"
PROMETHEUS_LOCAL_PORT="${PROMETHEUS_LOCAL_PORT:-19090}"
PROMETHEUS_TIMEOUT="${PROMETHEUS_TIMEOUT:-120}"

PASS=0
FAIL=0
PIDS=()
TMP_DIR="$(mktemp -d)"

cleanup() {
  local pid
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

require() {
  if ! command -v "$1" &>/dev/null; then
    echo "ERROR: '$1' is required but not installed." >&2
    exit 1
  fi
}

check_metrics() {
  local component="$1"
  local service="$2"
  local local_port="$3"
  local service_port="$4"
  local expected_pattern="$5"
  local output_file="${TMP_DIR}/${component}.metrics"
  local log_file="${TMP_DIR}/${component}.port-forward.log"
  local pid=""

  echo
  echo "--- ${component} ---"

  if ! "$KUBECTL" get service "$service" -n "$NAMESPACE" &>/dev/null; then
    echo "  FAIL  Service/${service} exists"
    ((FAIL++)) || true
    return
  fi
  echo "  PASS  Service/${service} exists"
  ((PASS++)) || true

  "$KUBECTL" port-forward -n "$NAMESPACE" "service/${service}" \
    "${local_port}:${service_port}" >"$log_file" 2>&1 &
  pid=$!
  PIDS+=("$pid")

  for _ in $(seq 1 "$METRICS_TIMEOUT"); do
    if "$CURL" -fsS --connect-timeout 2 --max-time 5 \
      "http://127.0.0.1:${local_port}/metrics" -o "$output_file" 2>/dev/null; then
      break
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 1
  done

  if [[ ! -s "$output_file" ]]; then
    echo "  FAIL  /metrics is reachable through Service/${service}"
    sed 's/^/    /' "$log_file" >&2 || true
    ((FAIL++)) || true
    return
  fi
  echo "  PASS  /metrics is reachable through Service/${service}"
  ((PASS++)) || true

  if grep -q '^# HELP ' "$output_file" && grep -Eq "$expected_pattern" "$output_file"; then
    echo "  PASS  endpoint returns described Prometheus metric families"
    ((PASS++)) || true
  else
    echo "  FAIL  endpoint output lacks expected Prometheus metric families"
    ((FAIL++)) || true
  fi
}

check_prometheus_scrapes() {
  local service_monitor
  local log_file="${TMP_DIR}/prometheus.port-forward.log"
  local targets_file="${TMP_DIR}/prometheus-targets.json"
  local status_file="${TMP_DIR}/prometheus-targets.txt"
  local pid=""

  echo
  echo "--- Prometheus ServiceMonitor discovery ---"

  for service_monitor in pdns-recursor pdns-authoritative pdns-operator; do
    if "$KUBECTL" get servicemonitor "$service_monitor" -n "$NAMESPACE" &>/dev/null; then
      echo "  PASS  ServiceMonitor/${service_monitor} exists"
      ((PASS++)) || true
    else
      echo "  FAIL  ServiceMonitor/${service_monitor} exists"
      ((FAIL++)) || true
      return
    fi
  done

  if ! "$KUBECTL" get prometheus powerdns-ci -n "$MONITORING_NAMESPACE" &>/dev/null; then
    echo "  FAIL  Prometheus/powerdns-ci exists"
    ((FAIL++)) || true
    return
  fi
  echo "  PASS  Prometheus/powerdns-ci exists"
  ((PASS++)) || true

  if ! "$KUBECTL" get service powerdns-prometheus -n "$MONITORING_NAMESPACE" &>/dev/null; then
    echo "  FAIL  Service/powerdns-prometheus exists"
    ((FAIL++)) || true
    return
  fi
  echo "  PASS  Service/powerdns-prometheus exists"
  ((PASS++)) || true

  "$KUBECTL" port-forward -n "$MONITORING_NAMESPACE" service/powerdns-prometheus \
    "${PROMETHEUS_LOCAL_PORT}:9090" >"$log_file" 2>&1 &
  pid=$!
  PIDS+=("$pid")

  for _ in $(seq 1 "$PROMETHEUS_TIMEOUT"); do
    if "$CURL" -fsS --connect-timeout 2 --max-time 5 \
      "http://127.0.0.1:${PROMETHEUS_LOCAL_PORT}/-/healthy" >/dev/null 2>&1; then
      break
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 1
  done

  if ! "$CURL" -fsS --connect-timeout 2 --max-time 5 \
    "http://127.0.0.1:${PROMETHEUS_LOCAL_PORT}/-/healthy" >/dev/null 2>&1; then
    echo "  FAIL  Prometheus HTTP API is healthy"
    sed 's/^/    /' "$log_file" >&2 || true
    ((FAIL++)) || true
    return
  fi
  echo "  PASS  Prometheus HTTP API is healthy"
  ((PASS++)) || true

  for _ in $(seq 1 "$PROMETHEUS_TIMEOUT"); do
    if "$CURL" -fsS --connect-timeout 2 --max-time 5 \
      "http://127.0.0.1:${PROMETHEUS_LOCAL_PORT}/api/v1/targets" \
      -o "$targets_file" 2>/dev/null; then
      if python3 - "$targets_file" >"$status_file" <<'PY'
import json
import re
import sys

# Keyed by (service, port): the pdns-auth Service exposes two scrape targets
# (the PowerDNS API and the Lightning Stream sidecar), so keying by service
# name alone would silently record only whichever target was listed last.
expected = {
    ("pdns-recursor", "8082"),
    ("pdns-auth", "8081"),
    ("pdns-auth", "8500"),
    ("pdns-operator-metrics", "8080"),
}
with open(sys.argv[1], encoding="utf-8") as stream:
    payload = json.load(stream)

found = {}
for target in payload.get("data", {}).get("activeTargets", []):
    labels = target.get("labels", {})
    discovered = target.get("discoveredLabels", {})
    service = labels.get("service") or discovered.get("__meta_kubernetes_service_name")
    match = re.search(r":(\d+)/", target.get("scrapeUrl", ""))
    port = match.group(1) if match else ""
    if (service, port) in expected:
        found[(service, port)] = target.get("health", "unknown")

for service, port in sorted(expected):
    print(f"{service}:{port}={found.get((service, port), 'missing')}")

sys.exit(0 if all(found.get(key) == "up" for key in expected) else 1)
PY
      then
        break
      fi
    fi
    sleep 1
  done

  if [[ -s "$status_file" ]] \
    && ! grep -Eq '=(missing|down|unknown)$' "$status_file"; then
    echo "  PASS  Prometheus reports all PowerDNS targets healthy"
    sed 's/^/    /' "$status_file"
    ((PASS++)) || true
  else
    echo "  FAIL  Prometheus did not report every PowerDNS target as healthy"
    sed 's/^/    /' "$status_file" >&2 || true
    ((FAIL++)) || true
  fi
}

require "$KUBECTL"
require "$CURL"
require python3

echo "=== Observability Validation ==="
echo "  Namespace: ${NAMESPACE}"
echo "  Monitoring namespace: ${MONITORING_NAMESPACE}"

check_metrics "Recursor" "pdns-recursor" "$REC_LOCAL_PORT" 8082 \
  '^(pdns_recursor_|# TYPE pdns_recursor_)'
check_metrics "Authoritative Server" "pdns-auth" "$AUTH_LOCAL_PORT" 8081 \
  '^(pdns_auth_|# TYPE pdns_auth_)'
check_metrics "Lightning Stream" "pdns-auth" "$LS_LOCAL_PORT" 8500 \
  '^(lightningstream_|# TYPE lightningstream_)'
check_metrics "Operator" "pdns-operator-metrics" "$OPERATOR_LOCAL_PORT" 8080 \
  '^(controller_runtime_|workqueue_|process_|go_|# TYPE (controller_runtime_|workqueue_|process_|go_))'
check_prometheus_scrapes

echo
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
