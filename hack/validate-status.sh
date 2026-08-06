#!/usr/bin/env bash
# Validates Custom Resource status feedback.
# Verifies that reconciled RRset CRs expose meaningful status fields after Operator reconciliation.
# Usage: NAMESPACE=dns ./hack/validate-status.sh [--cleanup]
set -euo pipefail

NAMESPACE="${NAMESPACE:-dns}"
KUBECTL="${KUBECTL_BIN:-kubectl}"
CLEANUP=false
TIMEOUT="${RECONCILE_TIMEOUT:-90}"

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
  local desc="$1"; shift
  if eval "$@" &>/dev/null; then
    echo "  PASS  $desc"
    ((PASS++)) || true
  else
    echo "  FAIL  $desc"
    ((FAIL++)) || true
  fi
}

wait_for_sync() {
  local resource="$1" name="$2" namespace="${3:-}"
  local expected="${4:-Succeeded|Error}"
  local i sync
  for i in $(seq 1 "$TIMEOUT"); do
    if [[ -n "$namespace" ]]; then
      sync=$($KUBECTL get "$resource" "$name" -n "$namespace" -o jsonpath='{.status.syncStatus}' 2>/dev/null || true)
    else
      sync=$($KUBECTL get "$resource" "$name" -o jsonpath='{.status.syncStatus}' 2>/dev/null || true)
    fi
    [[ "$sync" =~ ^(${expected})$ ]] && return 0
    sleep 1
  done
  return 1
}

dump_diagnostics() {
  echo
  echo "--- Diagnostics ---"

  echo "  Zone YAML:"
  $KUBECTL get zone status-validate.example.com -n "$NAMESPACE" -o yaml 2>/dev/null || echo "  (zone unavailable)"

  for rrset in probe.status-validate.example.com orphan.nonexistent-zone.example.com; do
    echo
    echo "  RRset YAML: ${rrset}"
    $KUBECTL get rrset "$rrset" -n "$NAMESPACE" -o yaml 2>/dev/null || echo "  (rrset unavailable)"

    echo
    echo "  RRset describe: ${rrset}"
    $KUBECTL describe rrset "$rrset" -n "$NAMESPACE" 2>/dev/null || echo "  (rrset describe unavailable)"
  done

  echo
  echo "  Operator logs (tail):"
  $KUBECTL logs deployment/pdns-operator -n "$NAMESPACE" --all-containers=true --tail=200 2>/dev/null || echo "  (operator logs unavailable)"
}

echo "=== CR Status Feedback Validation ==="
echo

echo "--- 1. Prerequisite Zone creation ---"
cat <<EOF | $KUBECTL apply -f - &>/dev/null
apiVersion: dns.cav.enablers.ob/v1alpha2
kind: Zone
metadata:
  name: status-validate.example.com
  namespace: ${NAMESPACE}
spec:
  kind: Native
  nameservers:
    - ns1.example.com
EOF
check "Zone status-validate.example.com created" \
  $KUBECTL get zone status-validate.example.com -n "$NAMESPACE"

echo
echo "--- 2. Zone status on successful reconciliation ---"
wait_for_sync zone status-validate.example.com "$NAMESPACE" "Succeeded" || true

check_output "Zone status.syncStatus is 'Succeeded'" \
  "$KUBECTL get zone status-validate.example.com -n $NAMESPACE -o jsonpath='{.status.syncStatus}' | grep -qx 'Succeeded'"
check_output "Zone status.name identifies the reconciled Zone" \
  "$KUBECTL get zone status-validate.example.com -n $NAMESPACE -o jsonpath='{.status.name}' | grep -qE '^status-validate\\.example\\.com\\.?$'"
check_output "Zone status.kind matches requested kind" \
  "$KUBECTL get zone status-validate.example.com -n $NAMESPACE -o jsonpath='{.status.kind}' | grep -qx 'Native'"
check_output "Zone status.serial is set" \
  "$KUBECTL get zone status-validate.example.com -n $NAMESPACE -o jsonpath='{.status.serial}' | grep -qE '^[0-9]+$'"
check_output "Zone status.observedGeneration is set" \
  "$KUBECTL get zone status-validate.example.com -n $NAMESPACE -o jsonpath='{.status.observedGeneration}' | grep -qE '^[0-9]+$'"

echo
echo "--- 3. RRset status on successful reconciliation ---"
cat <<EOF | $KUBECTL apply -f - &>/dev/null
apiVersion: dns.cav.enablers.ob/v1alpha2
kind: RRset
metadata:
  name: probe.status-validate.example.com
  namespace: ${NAMESPACE}
spec:
  name: probe.status-validate.example.com.
  type: A
  ttl: 300
  records:
    - 192.0.2.100
  zoneRef:
    name: status-validate.example.com
    kind: Zone
EOF

wait_for_sync rrset probe.status-validate.example.com "$NAMESPACE" "Succeeded" || true

check_output "RRset status.syncStatus is 'Succeeded'" \
  "$KUBECTL get rrset probe.status-validate.example.com -n $NAMESPACE -o jsonpath='{.status.syncStatus}' | grep -qx 'Succeeded'"
check_output "RRset status.dnsEntryName matches requested FQDN" \
  "$KUBECTL get rrset probe.status-validate.example.com -n $NAMESPACE -o jsonpath='{.status.dnsEntryName}' | grep -qx 'probe.status-validate.example.com.'"
check_output "RRset status.lastUpdateTime is set" \
  "$KUBECTL get rrset probe.status-validate.example.com -n $NAMESPACE -o jsonpath='{.status.lastUpdateTime}' | grep -q '.'"
check_output "RRset status.observedGeneration is set" \
  "$KUBECTL get rrset probe.status-validate.example.com -n $NAMESPACE -o jsonpath='{.status.observedGeneration}' | grep -qE '^[0-9]+$'"

echo
echo "--- 4. RRset pending status on missing zone reference ---"
cat <<EOF | $KUBECTL apply -f - &>/dev/null
apiVersion: dns.cav.enablers.ob/v1alpha2
kind: RRset
metadata:
  name: orphan.nonexistent-zone.example.com
  namespace: ${NAMESPACE}
spec:
  name: orphan.nonexistent-zone.example.com.
  type: A
  ttl: 300
  records:
    - 192.0.2.200
  zoneRef:
    name: nonexistent-zone.example.com
    kind: Zone
EOF

wait_for_sync rrset orphan.nonexistent-zone.example.com "$NAMESPACE" "Pending" || true

check_output "Orphan RRset status.syncStatus is 'Pending'" \
  "$KUBECTL get rrset orphan.nonexistent-zone.example.com -n $NAMESPACE -o jsonpath='{.status.syncStatus}' | grep -qx 'Pending'"
check_output "Orphan RRset condition status is 'False' or 'Unknown'" \
  "$KUBECTL get rrset orphan.nonexistent-zone.example.com -n $NAMESPACE -o jsonpath='{.status.conditions[0].status}' | grep -qE '^(False|Unknown)$'"
check_output "Orphan RRset condition reason is 'ZoneMissing'" \
  "$KUBECTL get rrset orphan.nonexistent-zone.example.com -n $NAMESPACE -o jsonpath='{.status.conditions[0].reason}' | grep -qx 'ZoneMissing'"
check_output "Orphan RRset missing-zone message identifies the missing Zone" \
  "$KUBECTL get rrset orphan.nonexistent-zone.example.com -n $NAMESPACE -o jsonpath='{.status.conditions[0].message}' | grep -qE 'nonexistent-zone\\.example\\.com.*not found|not found.*nonexistent-zone\\.example\\.com'"

echo
echo "--- 5. kubectl get tabular output (Sync column) ---"
echo "  RRset table:"
$KUBECTL get rrset probe.status-validate.example.com -n "$NAMESPACE" 2>/dev/null || echo "  (unavailable)"
echo
check_output "RRset kubectl get --no-headers shows sync state" \
  "$KUBECTL get rrset probe.status-validate.example.com -n $NAMESPACE --no-headers 2>/dev/null | grep -qE 'Succeeded|Pending|Failed|Error'"

echo
echo "--- 6. kubectl describe status section ---"
echo "  RRset describe (Status block):"
$KUBECTL describe rrset probe.status-validate.example.com -n "$NAMESPACE" 2>/dev/null \
  | grep -A 20 "^Status:" || echo "  (unavailable)"

if [[ "$FAIL" -gt 0 ]]; then
  dump_diagnostics
fi

if [[ "$CLEANUP" == "true" ]]; then
  echo
  echo "--- Cleanup ---"
  $KUBECTL delete rrset probe.status-validate.example.com -n "$NAMESPACE" --ignore-not-found &>/dev/null
  $KUBECTL delete rrset orphan.nonexistent-zone.example.com -n "$NAMESPACE" --ignore-not-found &>/dev/null
  $KUBECTL delete zone status-validate.example.com -n "$NAMESPACE" --ignore-not-found &>/dev/null
  echo "  Done."
  echo
fi

echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
