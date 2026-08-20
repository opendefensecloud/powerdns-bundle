#!/usr/bin/env bash
# Validates LMDB persistence and recovery for the Authoritative Server.
# Tests that zone data survives a pod restart and reports resource consumption.
# Usage: NAMESPACE=dns ./hack/validate-lmdb.sh [--cleanup]
set -euo pipefail

NAMESPACE="${NAMESPACE:-dns}"
KUBECTL="${KUBECTL_BIN:-kubectl}"
CLEANUP=false
RESTART_TIMEOUT="${RESTART_TIMEOUT:-120}"
METRICS_TIMEOUT="${METRICS_TIMEOUT:-90}"
RECONCILE_TIMEOUT="${RECONCILE_TIMEOUT:-90}"
TEST_ZONE="lmdb-validate.example.com"
PDNS_API_KEY="${PDNS_API_KEY:-changeme}"
LMDB_FILE="/var/lib/powerdns/pdns.lmdb"

for arg in "$@"; do
  [[ "$arg" == "--cleanup" ]] && CLEANUP=true
done

PASS=0
FAIL=0

check() {
  local desc="$1"; shift
  if "$@" &>/dev/null; then
    echo "  PASS  $desc"
    ((PASS++)) || true
  else
    echo "  FAIL  $desc"
    ((FAIL++)) || true
  fi
}

check_output() {
  local desc="$1" cmd
  shift
  cmd="$1"
  if eval "$cmd" &>/dev/null; then
    echo "  PASS  $desc"
    ((PASS++)) || true
  else
    echo "  FAIL  $desc"
    ((FAIL++)) || true
  fi
}

wait_for_pod_metrics() {
  local selector="$1"
  local output

  for _ in $(seq 1 "$METRICS_TIMEOUT"); do
    if output="$("$KUBECTL" top pod -n "$NAMESPACE" -l "$selector" --no-headers 2>&1)" \
        && [[ -n "$output" && "$output" != "No resources found"* ]]; then
      return 0
    fi
    sleep 1
  done

  [[ -n "${output:-}" ]] && printf '%s\n' "$output"
  return 1
}

# Returns 0 if the given pod's Authoritative server currently serves the test zone (i.e. it
# is present in the LMDB backend). Prefers pdnsutil; falls back to the HTTP API via curl/wget
# if pdnsutil is absent from the image. Returns 2 if no probe tool is available.
zone_in_auth() {
  local pod="$1"
  if "$KUBECTL" exec "$pod" -n "$NAMESPACE" -c pdns-auth -- sh -c "command -v pdnsutil" &>/dev/null; then
    "$KUBECTL" exec "$pod" -n "$NAMESPACE" -c pdns-auth -- pdnsutil list-zone "$TEST_ZONE" &>/dev/null
  elif "$KUBECTL" exec "$pod" -n "$NAMESPACE" -c pdns-auth -- sh -c "command -v curl" &>/dev/null; then
    "$KUBECTL" exec "$pod" -n "$NAMESPACE" -c pdns-auth -- \
      curl -sf "http://localhost:8081/api/v1/servers/localhost/zones/${TEST_ZONE}" \
      -H "X-API-Key: ${PDNS_API_KEY}" &>/dev/null
  elif "$KUBECTL" exec "$pod" -n "$NAMESPACE" -c pdns-auth -- sh -c "command -v wget" &>/dev/null; then
    "$KUBECTL" exec "$pod" -n "$NAMESPACE" -c pdns-auth -- \
      wget -qO- --header "X-API-Key: ${PDNS_API_KEY}" \
      "http://localhost:8081/api/v1/servers/localhost/zones/${TEST_ZONE}" &>/dev/null
  else
    return 2
  fi
}

# Polls zone_in_auth on the given pod until the zone is served or the timeout (seconds) elapses.
wait_zone_served() {
  local pod="$1" timeout="$2"
  for _ in $(seq 1 "$timeout"); do
    if zone_in_auth "$pod"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

echo "=== LMDB Persistence and Recovery Validation ==="
echo

echo "--- 1. Authoritative Server running ---"
check "Deployment pdns-auth available" \
  "$KUBECTL" wait deployment/pdns-auth -n "$NAMESPACE" --for=condition=Available --timeout=60s

AUTH_POD=$("$KUBECTL" get pod -n "$NAMESPACE" -l app.kubernetes.io/name=pdns-auth \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -z "$AUTH_POD" ]]; then
  echo "  FAIL  Could not find pdns-auth pod — aborting"
  exit 1
fi

echo
echo "--- 2. LMDB data directory accessible ---"
check_output "PVC mounted at /var/lib/powerdns in pdns-auth container" \
  "$KUBECTL exec $AUTH_POD -n $NAMESPACE -c pdns-auth -- ls /var/lib/powerdns"

echo
echo "--- 3. Zone created and reconciled into LMDB before restart ---"
"$KUBECTL" apply -f - &>/dev/null <<EOF
apiVersion: dns.cav.enablers.ob/v1alpha2
kind: Zone
metadata:
  name: ${TEST_ZONE}
  namespace: ${NAMESPACE}
spec:
  kind: Native
  nameservers:
    - ns1.example.com
EOF
check "Zone ${TEST_ZONE} created before restart" \
  "$KUBECTL" get zone "$TEST_ZONE" -n "$NAMESPACE"

# The persistence test is only meaningful once the operator has reconciled the zone into the
# Authoritative server (and thus written it to the LMDB file on the PVC). A blind sleep here
# is racy: if the zone is not yet in LMDB when the pod is deleted, it cannot survive the
# restart and the assertion below fails intermittently. Poll until the running pod actually
# serves the zone before triggering the restart.
echo "  Waiting for the zone to be served from LMDB (timeout: ${RECONCILE_TIMEOUT}s)…"
ZONE_READY=false
if wait_zone_served "$AUTH_POD" "$RECONCILE_TIMEOUT"; then
  echo "  PASS  Zone ${TEST_ZONE} reconciled into Auth server before restart"
  ((PASS++)) || true
  ZONE_READY=true
else
  echo "  FAIL  Zone ${TEST_ZONE} not served by Auth server within ${RECONCILE_TIMEOUT}s — skipping restart test"
  ((FAIL++)) || true
fi

echo
echo "--- 4. Pod restart — LMDB persistence test ---"
NEW_POD=""
if [[ "$ZONE_READY" == "true" ]]; then
  echo "  Deleting pdns-auth pod to trigger Recreate restart…"
  "$KUBECTL" delete pod -n "$NAMESPACE" -l app.kubernetes.io/name=pdns-auth --wait=false &>/dev/null || true
  # Wait for the original pod to be fully gone before checking Deployment availability. Without
  # this, the readiness check below can pass against the still-terminating pre-restart pod and
  # NEW_POD can capture that old pod, running the LMDB persistence checks against the wrong pod.
  "$KUBECTL" wait "pod/${AUTH_POD}" -n "$NAMESPACE" --for=delete --timeout="${RESTART_TIMEOUT}s" &>/dev/null || true
  echo "  Waiting for Deployment to recover (timeout: ${RESTART_TIMEOUT}s)…"
  "$KUBECTL" wait deployment/pdns-auth -n "$NAMESPACE" \
    --for=condition=Available --timeout="${RESTART_TIMEOUT}s" &>/dev/null || true

  check "Deployment pdns-auth available after pod restart" \
    "$KUBECTL" wait deployment/pdns-auth -n "$NAMESPACE" --for=condition=Available --timeout=30s

  NEW_POD=$("$KUBECTL" get pod -n "$NAMESPACE" -l app.kubernetes.io/name=pdns-auth \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -n "$NEW_POD" ]]; then
    check_output "LMDB database file present on PVC after restart (${LMDB_FILE})" \
      "$KUBECTL exec $NEW_POD -n $NAMESPACE -c pdns-auth -- ls $LMDB_FILE"

    # The restarted Auth server must load and serve the zone from the persisted LMDB file.
    # Bounded polling absorbs the brief window between Deployment-Available and the PowerDNS
    # process having fully loaded its backend, so this is deterministic rather than racy.
    echo "  Waiting for the restarted Auth server to serve the zone from LMDB (timeout: ${RESTART_TIMEOUT}s)…"
    if wait_zone_served "$NEW_POD" "$RESTART_TIMEOUT"; then
      echo "  PASS  Zone ${TEST_ZONE} served by Auth server from LMDB after restart"
      ((PASS++)) || true
    else
      echo "  FAIL  Zone ${TEST_ZONE} not served by Auth server from LMDB after restart"
      ((FAIL++)) || true
    fi
  fi

  check "Zone ${TEST_ZONE} CR present in Kubernetes after restart" \
    "$KUBECTL" get zone "$TEST_ZONE" -n "$NAMESPACE"
fi

echo
echo "--- 5. LMDB resource consumption ---"
PROBE_POD="${NEW_POD:-$AUTH_POD}"

echo "  CPU / memory (kubectl top):"
echo "  Waiting up to ${METRICS_TIMEOUT}s for pdns-auth pod metrics..."
if wait_for_pod_metrics app.kubernetes.io/name=pdns-auth; then
  # wait_for_pod_metrics already confirmed metrics are available; this re-query is
  # only for display. Guard it with || true so a transient metrics-server blip
  # between the two calls cannot trip set -e/pipefail and abort the suite before the
  # PASS line is printed.
  "$KUBECTL" top pod -n "$NAMESPACE" -l app.kubernetes.io/name=pdns-auth 2>/dev/null | sed 's/^/    /' || true
  echo "  PASS  kubectl top reports CPU and memory for pdns-auth"
  ((PASS++)) || true
else
  echo "  FAIL  metrics-server did not report pdns-auth CPU/memory within ${METRICS_TIMEOUT}s"
  ((FAIL++)) || true
fi

if [[ -n "$PROBE_POD" ]]; then
  echo "  Disk — LMDB file size:"
  "$KUBECTL" exec "$PROBE_POD" -n "$NAMESPACE" -c pdns-auth -- \
    du -sh "$LMDB_FILE" 2>/dev/null | sed 's/^/    /' || echo "    (unavailable)"
  check_output "LMDB file size is reportable" \
    "$KUBECTL exec $PROBE_POD -n $NAMESPACE -c pdns-auth -- du -sh $LMDB_FILE"

  echo "  Disk — PVC usage:"
  "$KUBECTL" exec "$PROBE_POD" -n "$NAMESPACE" -c pdns-auth -- \
    df -h /var/lib/powerdns 2>/dev/null | sed 's/^/    /' || echo "    (unavailable)"
  check_output "PVC usage is reportable" \
    "$KUBECTL exec $PROBE_POD -n $NAMESPACE -c pdns-auth -- df -h /var/lib/powerdns"
else
  echo "  FAIL  No recovered pdns-auth pod found — cannot validate disk consumption"
  ((FAIL++)) || true
fi

echo
if [[ "$CLEANUP" == "true" ]]; then
  echo "--- Cleanup ---"
  $KUBECTL delete zone "$TEST_ZONE" -n "$NAMESPACE" --ignore-not-found &>/dev/null
  echo "  Done."
  echo
fi

echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
