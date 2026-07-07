#!/usr/bin/env bash
# Validates PowerDNS Operator deployment and CRD reconciliation.
# Usage: NAMESPACE=dns ./hack/validate-operator.sh [--cleanup]
set -euo pipefail

NAMESPACE="${NAMESPACE:-dns}"
KUBECTL="${KUBECTL_BIN:-kubectl}"
CLEANUP=false
RECONCILE_TIMEOUT="${RECONCILE_TIMEOUT:-90}"
PDNS_API_KEY="${PDNS_API_KEY:-changeme}"

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

wait_for_rrset_succeeded() {
  local name="$1" namespace="$2" expected_dns_name="$3"
  local sync_status dns_entry observed_generation

  for _ in $(seq 1 "$RECONCILE_TIMEOUT"); do
    sync_status="$("$KUBECTL" get rrset "$name" -n "$namespace" \
      -o jsonpath='{.status.syncStatus}' 2>/dev/null || true)"
    dns_entry="$("$KUBECTL" get rrset "$name" -n "$namespace" \
      -o jsonpath='{.status.dnsEntryName}' 2>/dev/null || true)"
    observed_generation="$("$KUBECTL" get rrset "$name" -n "$namespace" \
      -o jsonpath='{.status.observedGeneration}' 2>/dev/null || true)"

    if [[ "$sync_status" == "Succeeded" \
        && "$dns_entry" == "$expected_dns_name" \
        && "$observed_generation" =~ ^[0-9]+$ ]]; then
      return 0
    fi
    sleep 1
  done

  return 1
}

echo "=== Operator Deployment Validation ==="
echo

echo "--- 1. Operator resources exist ---"
check "ServiceAccount pdns-operator exists" \
  "$KUBECTL" get serviceaccount pdns-operator -n "$NAMESPACE"
check "ClusterRole pdns-operator exists" \
  "$KUBECTL" get clusterrole pdns-operator
check "ClusterRoleBinding pdns-operator exists" \
  "$KUBECTL" get clusterrolebinding pdns-operator
check "Secret pdns-operator-api-key exists" \
  "$KUBECTL" get secret pdns-operator-api-key -n "$NAMESPACE"
check "Deployment pdns-operator exists" \
  "$KUBECTL" get deployment pdns-operator -n "$NAMESPACE"

echo
echo "--- 2. Operator pod is running ---"
check "Operator deployment has at least 1 ready replica" \
  "$KUBECTL" wait deployment/pdns-operator \
    -n "$NAMESPACE" \
    --for=condition=Available \
    --timeout=60s

echo
echo "--- 3. CRD prerequisite (Zone) ---"
cat <<EOF | "$KUBECTL" apply -f - &>/dev/null
apiVersion: dns.cav.enablers.ob/v1alpha2
kind: Zone
metadata:
  name: operator-validate.example.com
  namespace: ${NAMESPACE}
spec:
  kind: Native
  nameservers:
    - ns1.example.com.
EOF
check "Zone operator-validate.example.com created" \
  "$KUBECTL" get zone operator-validate.example.com -n "$NAMESPACE"

echo
echo "--- 4. CRD reconciliation (RRset) ---"
cat <<EOF | "$KUBECTL" apply -f - &>/dev/null
apiVersion: dns.cav.enablers.ob/v1alpha2
kind: RRset
metadata:
  name: validate.operator-validate.example.com
  namespace: ${NAMESPACE}
spec:
  name: validate.operator-validate.example.com.
  type: A
  ttl: 300
  records:
    - 192.0.2.1
  zoneRef:
    name: operator-validate.example.com
    kind: Zone
EOF
check "RRset validate.operator-validate.example.com created" \
  "$KUBECTL" get rrset validate.operator-validate.example.com -n "$NAMESPACE"
check "RRset syncStatus is Succeeded with reconciled DNS entry metadata" \
  wait_for_rrset_succeeded validate.operator-validate.example.com "$NAMESPACE" \
    validate.operator-validate.example.com.

echo
echo "--- 5. Authoritative server runtime — zone served by PowerDNS ---"
AUTH_POD=$("$KUBECTL" get pod -n "$NAMESPACE" -l app.kubernetes.io/name=pdns-auth \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -n "$AUTH_POD" ]]; then
  # Prefer pdnsutil (always present in the Auth image); fall back to HTTP API.
  if "$KUBECTL" exec "$AUTH_POD" -n "$NAMESPACE" -c pdns-auth -- \
      sh -c "command -v pdnsutil" &>/dev/null; then
    check_output "Zone operator-validate.example.com served by Auth server (pdnsutil)" \
      "$KUBECTL exec $AUTH_POD -n $NAMESPACE -c pdns-auth -- \
        pdnsutil list-zone operator-validate.example.com"
    check_output "RRset validate.operator-validate.example.com present in Auth server" \
      "$KUBECTL exec $AUTH_POD -n $NAMESPACE -c pdns-auth -- \
        pdnsutil list-zone operator-validate.example.com \
        | grep -q 'validate\\.operator-validate\\.example\\.com'"
  elif "$KUBECTL" exec "$AUTH_POD" -n "$NAMESPACE" -c pdns-auth -- \
      sh -c "command -v curl" &>/dev/null; then
    check_output "Zone operator-validate.example.com served by Auth server (curl API)" \
      "$KUBECTL exec $AUTH_POD -n $NAMESPACE -c pdns-auth -- \
        curl -sf http://localhost:8081/api/v1/servers/localhost/zones/operator-validate.example.com \
        -H \"X-API-Key: ${PDNS_API_KEY}\""
  elif "$KUBECTL" exec "$AUTH_POD" -n "$NAMESPACE" -c pdns-auth -- \
      sh -c "command -v wget" &>/dev/null; then
    check_output "Zone operator-validate.example.com served by Auth server (wget API)" \
      "$KUBECTL exec $AUTH_POD -n $NAMESPACE -c pdns-auth -- \
        wget -qO- --header \"X-API-Key: ${PDNS_API_KEY}\" \
        http://localhost:8081/api/v1/servers/localhost/zones/operator-validate.example.com"
  else
    echo "  FAIL  pdnsutil, curl, and wget all unavailable in pdns-auth container — cannot verify runtime serving"
    ((FAIL++)) || true
  fi
else
  echo "  FAIL  pdns-auth pod not found — cannot verify authoritative runtime"
  ((FAIL++)) || true
fi

echo
if [[ "$CLEANUP" == "true" ]]; then
  echo "--- Cleanup ---"
  "$KUBECTL" delete rrset validate.operator-validate.example.com -n "$NAMESPACE" --ignore-not-found &>/dev/null
  "$KUBECTL" delete zone operator-validate.example.com -n "$NAMESPACE" --ignore-not-found &>/dev/null
  echo "  Done."
  echo
fi

echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
