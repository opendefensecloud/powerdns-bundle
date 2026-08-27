#!/usr/bin/env bash
# Validates CRD installation and CRUD operations.
# Usage: NAMESPACE=dns ./hack/validate-crds.sh [--cleanup]
set -euo pipefail

NAMESPACE="${NAMESPACE:-dns}"
KUBECTL="${KUBECTL_BIN:-kubectl}"
CLEANUP=false

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

echo "=== CRD Validation ==="
echo

echo "--- 1. CRDs installed ---"
for crd in \
  zones.dns.cav.enablers.ob \
  clusterzones.dns.cav.enablers.ob \
  rrsets.dns.cav.enablers.ob \
  clusterrrsets.dns.cav.enablers.ob; do
  check "CRD $crd exists" $KUBECTL get crd "$crd"
done

echo
echo "--- 2. Zone creation ---"
$KUBECTL apply -f deploy/examples/zone-reference-scenario.yaml
check "Zone intern.example.com created"    $KUBECTL get zone    intern.example.com    -n "$NAMESPACE"
check "ClusterZone cluster.example.com created" $KUBECTL get clusterzone cluster.example.com

echo
echo "--- 3. RRset creation (A, AAAA, CNAME, MX, TXT) ---"
$KUBECTL apply -f deploy/examples/rrset-reference-scenario.yaml
for name in \
  app.intern.example.com \
  lb.intern.example.com \
  ipv6.intern.example.com \
  www.intern.example.com \
  intern.example.com \
  spf.intern.example.com; do
  check "RRset $name created" $KUBECTL get rrset "$name" -n "$NAMESPACE"
done

echo
echo "--- 4. kubectl describe output ---"
check "Zone describe shows Kind field" bash -c \
  "$KUBECTL describe zone intern.example.com -n '$NAMESPACE' | grep -q 'Kind:'"
check "RRset describe shows Type field" bash -c \
  "$KUBECTL describe rrset app.intern.example.com -n '$NAMESPACE' | grep -q 'Type:'"

echo
if [[ "$CLEANUP" == "true" ]]; then
  echo "--- Cleanup ---"
  $KUBECTL delete -f deploy/examples/rrset-reference-scenario.yaml --ignore-not-found
  $KUBECTL delete -f deploy/examples/zone-reference-scenario.yaml  --ignore-not-found
  echo "  Done."
  echo
fi

echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
