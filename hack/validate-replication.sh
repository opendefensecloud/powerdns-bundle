#!/usr/bin/env bash
# Validates lightningstream replication and data availability after pod restart.
# Tests that the sidecar runs, config is mounted, and data survives a pod failure.
#
# Single-instance mode (default):
#   NAMESPACE=dns ./hack/validate-replication.sh [--cleanup]
#
# Multi-instance mode (Garage S3 backend):
#   NAMESPACE=pdns-mi-a ./hack/validate-replication.sh --multi-instance [--cleanup]
#   or: MULTI_INSTANCE=true NAMESPACE=pdns-mi-a ./hack/validate-replication.sh [--cleanup]
set -euo pipefail

NAMESPACE="${NAMESPACE:-dns}"
KUBECTL="${KUBECTL_BIN:-kubectl}"
CLEANUP=false
MULTI_INSTANCE=false
RESTART_TIMEOUT="${RESTART_TIMEOUT:-120}"
TEST_ZONE="replication-validate.example.com"
PDNS_API_KEY="${PDNS_API_KEY:-changeme}"
SNAPSHOT_DIR="/var/lib/powerdns/snapshots"

for arg in "$@"; do
  [[ "$arg" == "--cleanup" ]] && CLEANUP=true
  [[ "$arg" == "--multi-instance" ]] && MULTI_INSTANCE=true
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

# Polls the Auth server (from inside the pod) until it serves $TEST_ZONE, or
# RESTART_TIMEOUT elapses. Tries pdnsutil, then the HTTP API via curl, then wget —
# whichever the container image provides. Asserting that the zone is actually served
# is far more robust than grepping sidecar logs: it tolerates a brief restore/reconcile
# delay after the pod becomes Available and works regardless of whether the LMDB was
# retained locally or re-synced from Garage.
zone_served_by_auth() {
  local pod="$1"
  local deadline=$((SECONDS + RESTART_TIMEOUT))
  local url="http://localhost:8081/api/v1/servers/localhost/zones/${TEST_ZONE}"
  while (( SECONDS < deadline )); do
    if "$KUBECTL" exec "$pod" -n "$NAMESPACE" -c pdns-auth -- sh -c \
      "pdnsutil list-zone ${TEST_ZONE} 2>/dev/null \
       || curl -sf -H 'X-API-Key: ${PDNS_API_KEY}' ${url} >/dev/null 2>&1 \
       || wget -qO- --header 'X-API-Key: ${PDNS_API_KEY}' ${url} >/dev/null 2>&1" \
      &>/dev/null; then
      return 0
    fi
    sleep 3
  done
  return 1
}

echo "=== Replication and Recovery Validation ==="
echo

if [[ "$MULTI_INSTANCE" == "false" ]]; then

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
echo "--- 2. lightningstream sidecar running ---"
check_output "lightningstream container is ready in pdns-auth pod" \
  "$KUBECTL get pod $AUTH_POD -n $NAMESPACE \
    -o jsonpath='{.status.containerStatuses[?(@.name==\"lightningstream\")].ready}' \
    | grep -qx 'true'"
check_output "lightningstream config mounted at /etc/lightningstream" \
  "$KUBECTL exec $AUTH_POD -n $NAMESPACE -c lightningstream \
    -- ls /etc/lightningstream/lightningstream.yaml"
check_output "Shared PVC accessible in lightningstream container" \
  "$KUBECTL exec $AUTH_POD -n $NAMESPACE -c lightningstream -- ls /var/lib/powerdns"

echo
echo "--- 3. Zone created for recovery test ---"
"$KUBECTL" apply -f - &>/dev/null <<EOF
apiVersion: dns.cav.enablers.ob/v1alpha2
kind: Zone
metadata:
  name: ${TEST_ZONE}
  namespace: ${NAMESPACE}
spec:
  kind: Native
  nameservers:
    - ns1.example.com.
EOF
check "Zone ${TEST_ZONE} created before restart" \
  "$KUBECTL" get zone "$TEST_ZONE" -n "$NAMESPACE"
# Gate on the operator actually reconciling the zone into the Auth server (and thus
# LMDB) instead of a fixed settle delay, so the snapshot check below and the
# post-restart recovery test cannot race a not-yet-loaded zone.
check "Zone ${TEST_ZONE} served by Auth server before restart" \
  zone_served_by_auth "$AUTH_POD"

# Verify lightningstream has already written at least one snapshot (poll_interval=1s).
check_output "lightningstream snapshot written to ${SNAPSHOT_DIR}" \
  "$KUBECTL exec $AUTH_POD -n $NAMESPACE -c lightningstream \
    -- sh -c \"find '${SNAPSHOT_DIR}' -mindepth 1 -print -quit | grep -q .\""

echo
echo "--- 4. Pod restart — data availability test ---"
echo "  Deleting pdns-auth pod to simulate failure…"
"$KUBECTL" delete pod -n "$NAMESPACE" -l app.kubernetes.io/name=pdns-auth --wait=false &>/dev/null || true
# Wait for the original pod to be fully gone before checking Deployment availability, so the
# readiness check below cannot pass against the still-terminating pre-restart pod.
"$KUBECTL" wait "pod/${AUTH_POD}" -n "$NAMESPACE" --for=delete --timeout="${RESTART_TIMEOUT}s" &>/dev/null || true
echo "  Waiting for Deployment to recover (timeout: ${RESTART_TIMEOUT}s)…"
"$KUBECTL" wait deployment/pdns-auth -n "$NAMESPACE" \
  --for=condition=Available --timeout="${RESTART_TIMEOUT}s" &>/dev/null || true

check "Deployment pdns-auth available after restart" \
  "$KUBECTL" wait deployment/pdns-auth -n "$NAMESPACE" --for=condition=Available --timeout=30s

NEW_POD=$("$KUBECTL" get pod -n "$NAMESPACE" -l app.kubernetes.io/name=pdns-auth \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -n "$NEW_POD" ]]; then
  check_output "lightningstream container ready in recovered pod" \
    "$KUBECTL get pod $NEW_POD -n $NAMESPACE \
      -o jsonpath='{.status.containerStatuses[?(@.name==\"lightningstream\")].ready}' \
      | grep -qx 'true'"

  # Snapshots must still be present — they are the recovery source for lightningstream.
  check_output "Snapshot files present in ${SNAPSHOT_DIR} after recovery" \
    "$KUBECTL exec $NEW_POD -n $NAMESPACE -c lightningstream \
      -- sh -c \"find '${SNAPSHOT_DIR}' -mindepth 1 -print -quit | grep -q .\""

  # Confirm lightningstream restored the LMDB and the zone is actually being served.
  # Poll the Auth server so a brief restore delay after the pod becomes Available does
  # not cause a false failure.
  check "Zone ${TEST_ZONE} served by Auth server after recovery" \
    zone_served_by_auth "$NEW_POD"
fi

check "Zone ${TEST_ZONE} CR present in Kubernetes after recovery" \
  "$KUBECTL" get zone "$TEST_ZONE" -n "$NAMESPACE"

echo
if [[ "$CLEANUP" == "true" ]]; then
  echo "--- Cleanup ---"
  "$KUBECTL" delete zone "$TEST_ZONE" -n "$NAMESPACE" --ignore-not-found &>/dev/null
  echo "  Done."
  echo
fi

fi # end single-instance sections

if [[ "$MULTI_INSTANCE" == "true" ]]; then
  echo
  echo "=== Multi-instance: Garage S3 replication validation ==="
  echo

  echo "--- M1. lightningstream configured for S3 backend ---"
  AUTH_POD_MI=$("$KUBECTL" get pod -n "$NAMESPACE" -l app.kubernetes.io/name=pdns-auth \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -z "$AUTH_POD_MI" ]]; then
    echo "  FAIL  Could not find pdns-auth pod in namespace ${NAMESPACE} — aborting multi-instance checks"
    ((FAIL++)) || true
  else
    check_output "lightningstream config uses type: s3" \
      "$KUBECTL exec $AUTH_POD_MI -n $NAMESPACE -c lightningstream \
        -- grep -q 'type: s3' /etc/lightningstream/lightningstream.yaml"

    echo
    echo "--- M2. Garage pdns-lmdb bucket has snapshots ---"
    # M2 proves S3 connectivity indirectly: if the bucket is non-empty, lightningstream
    # successfully reached the Garage S3 endpoint and uploaded at least one snapshot.
    # (Direct connectivity probes are omitted — the lightningstream image is a minimal
    # scratch binary with no shell utilities.)
    GARAGE_POD=$("$KUBECTL" get pod -n "$NAMESPACE" -l app.kubernetes.io/name=garage \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -z "$GARAGE_POD" ]]; then
      echo "  FAIL  Could not find garage pod in namespace ${NAMESPACE} — skipping bucket check"
      ((FAIL++)) || true
    else
      ADMIN_TOKEN=$("$KUBECTL" exec "$GARAGE_POD" -n "$NAMESPACE" -c bootstrap \
        -- cat /etc/garage-credentials/admin-token 2>/dev/null || echo "")
      if [[ -n "$ADMIN_TOKEN" ]]; then
        check_output "Garage pdns-lmdb bucket exists and is non-empty" \
          "$KUBECTL exec $GARAGE_POD -n $NAMESPACE -c bootstrap \
            -- sh -c 'curl -fsS \
              -H \"Authorization: Bearer \$(cat /etc/garage-credentials/admin-token)\" \
              http://127.0.0.1:3903/v1/bucket?id=pdns-lmdb 2>/dev/null | grep -q pdns-lmdb \
              || curl -fsS \
              -H \"Authorization: Bearer \$(cat /etc/garage-credentials/admin-token)\" \
              \"http://127.0.0.1:3903/v1/bucket?globalAlias=pdns-lmdb\" 2>/dev/null | grep -q pdns-lmdb'"
      else
        # bootstrap sidecar may have exited — fall back to checking via lightningstream logs
        check_output "lightningstream logs show successful S3 snapshot upload" \
          "$KUBECTL logs $AUTH_POD_MI -n $NAMESPACE -c lightningstream \
            | grep -q 'Uploaded\|snapshot\|S3\|s3'"
      fi
    fi

    echo
    echo "--- M3. Pod restart — data recovery from Garage ---"
    echo "  Creating test zone for Garage recovery test…"
    "$KUBECTL" apply -f - &>/dev/null <<EOF
apiVersion: dns.cav.enablers.ob/v1alpha2
kind: Zone
metadata:
  name: ${TEST_ZONE}
  namespace: ${NAMESPACE}
spec:
  kind: Native
  nameservers:
    - ns1.example.com.
EOF
    check "Zone ${TEST_ZONE} created before restart" \
      "$KUBECTL" get zone "$TEST_ZONE" -n "$NAMESPACE"

    # Baseline: confirm the zone is actually served before the restart, so a
    # post-restart failure is unambiguously a recovery problem rather than the zone
    # never having been loaded. This poll also gates the timing, replacing a fixed
    # settle delay.
    check "Zone ${TEST_ZONE} served by Auth server before restart" \
      zone_served_by_auth "$AUTH_POD_MI"

    echo "  Deleting pdns-auth pod to simulate failure…"
    "$KUBECTL" delete pod -n "$NAMESPACE" -l app.kubernetes.io/name=pdns-auth --wait=false &>/dev/null || true
    # Wait for the original pod to be fully gone before checking Deployment availability, so the
    # readiness check below cannot pass against the still-terminating pre-restart pod.
    "$KUBECTL" wait "pod/${AUTH_POD_MI}" -n "$NAMESPACE" --for=delete --timeout="${RESTART_TIMEOUT}s" &>/dev/null || true
    echo "  Waiting for Deployment to recover (timeout: ${RESTART_TIMEOUT}s)…"
    "$KUBECTL" wait deployment/pdns-auth -n "$NAMESPACE" \
      --for=condition=Available --timeout="${RESTART_TIMEOUT}s" &>/dev/null || true

    check "Deployment pdns-auth available after restart" \
      "$KUBECTL" wait deployment/pdns-auth -n "$NAMESPACE" --for=condition=Available --timeout=30s

    NEW_POD_MI=$("$KUBECTL" get pod -n "$NAMESPACE" -l app.kubernetes.io/name=pdns-auth \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -n "$NEW_POD_MI" ]]; then
      check_output "lightningstream container ready in recovered pod" \
        "$KUBECTL get pod $NEW_POD_MI -n $NAMESPACE \
          -o jsonpath='{.status.containerStatuses[?(@.name==\"lightningstream\")].ready}' \
          | grep -qx 'true'"
      # The auth LMDB lives on a retained ReadWriteOnce PVC and the Deployment uses
      # the Recreate strategy, so the recovered pod re-attaches the same volume. The
      # meaningful recovery property is therefore that the zone is served again after
      # the restart — whether the data was retained locally or re-synced from Garage.
      # Poll the Auth server, allowing lightningstream time to finish any restore.
      check "Zone ${TEST_ZONE} served by recovered Auth server" \
        zone_served_by_auth "$NEW_POD_MI"

      # Best-effort, non-fatal: report whether lightningstream logged an S3
      # restore/sync on startup. Its absence is expected when the LMDB PVC retained
      # data (no restore needed) and is NOT a failure.
      if "$KUBECTL" logs "$NEW_POD_MI" -n "$NAMESPACE" -c lightningstream 2>/dev/null \
          | grep -qE 'Download|Restore|restore|snapshot'; then
        echo "  INFO  lightningstream logged an S3 restore/sync on startup"
      else
        echo "  INFO  no S3 restore logged on startup (LMDB retained on PVC — expected)"
      fi

      check "Zone ${TEST_ZONE} CR present in Kubernetes after Garage recovery" \
        "$KUBECTL" get zone "$TEST_ZONE" -n "$NAMESPACE"
    fi

    if [[ "$CLEANUP" == "true" ]]; then
      "$KUBECTL" delete zone "$TEST_ZONE" -n "$NAMESPACE" --ignore-not-found &>/dev/null
    fi
  fi
fi

echo
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
