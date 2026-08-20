#!/usr/bin/env bash
# Validates that health probes are configured on all Deployments and that an
# unready pod is removed from Service Endpoints (i.e. gated by readinessProbe).
# Usage: NAMESPACE=dns ./hack/validate-health-probes.sh
set -euo pipefail

NAMESPACE="${NAMESPACE:-dns}"
KUBECTL="${KUBECTL_BIN:-kubectl}"
READINESS_TIMEOUT="${READINESS_TIMEOUT:-90}"

PASS=0
FAIL=0
PATCH_APPLIED=false

restore_dnsdist() {
  if [[ "$PATCH_APPLIED" != "true" ]]; then
    return
  fi

  echo
  echo "--- Restore dnsdist readiness probe ---"
  if $KUBECTL rollout undo deployment/dnsdist -n "$NAMESPACE" &>/dev/null; then
    $KUBECTL rollout status deployment/dnsdist -n "$NAMESPACE" --timeout=90s &>/dev/null || true
    PATCH_APPLIED=false
    echo "  Restored previous dnsdist rollout."
  else
    echo "  WARNING  Failed to restore dnsdist via rollout undo; inspect deployment/dnsdist manually."
  fi
}

trap restore_dnsdist EXIT

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

echo "=== Health Probe Validation ==="
echo

echo "--- 1. Probe configuration on all Deployments ---"
for deploy in dnsdist pdns-recursor pdns-auth pdns-operator; do
  check_output "${deploy}: livenessProbe configured" \
    "$KUBECTL get deployment $deploy -n $NAMESPACE \
      -o jsonpath='{.spec.template.spec.containers[0].livenessProbe}' | grep -q '.'"
  check_output "${deploy}: readinessProbe configured" \
    "$KUBECTL get deployment $deploy -n $NAMESPACE \
      -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}' | grep -q '.'"
done

echo
echo "--- 2. Unready pod excluded from Service Endpoints (dnsdist) ---"
BEFORE=$($KUBECTL get endpoints dnsdist -n "$NAMESPACE" \
  -o jsonpath='{.subsets[0].addresses}' 2>/dev/null || echo "")
echo "  Endpoints before: ${BEFORE:-<none>}"

check_output "Service Endpoints contain a ready pod IP before unready-pod test" \
  "$KUBECTL get endpoints dnsdist -n $NAMESPACE \
    -o jsonpath='{.subsets[0].addresses[0].ip}' | grep -qE '^[0-9]+\\.'"

echo "  Patching dnsdist readinessProbe to an unused TCP port to create a selected but unready pod…"
$KUBECTL patch deployment dnsdist -n "$NAMESPACE" --type='json' \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/tcpSocket/port","value":65535}]' \
  &>/dev/null
PATCH_APPLIED=true

NOT_READY_IPS=""
echo "  Waiting up to ${READINESS_TIMEOUT}s for an unready selected pod to appear…"
for _ in $(seq 1 "$READINESS_TIMEOUT"); do
  NOT_READY_IPS=$($KUBECTL get endpoints dnsdist -n "$NAMESPACE" \
    -o jsonpath='{range .subsets[*].notReadyAddresses[*]}{.ip}{"\n"}{end}' 2>/dev/null || true)
  [[ -n "$NOT_READY_IPS" ]] && break
  sleep 1
done

if [[ -n "$NOT_READY_IPS" ]]; then
  echo "  PASS  Service Endpoints expose selected unready pod(s) under notReadyAddresses"
  echo "$NOT_READY_IPS" | sed 's/^/    /'
  ((PASS++)) || true
else
  echo "  FAIL  No selected unready dnsdist pod appeared in Service Endpoints"
  ((FAIL++)) || true
fi

READY_IPS=$($KUBECTL get endpoints dnsdist -n "$NAMESPACE" \
  -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null || true)

OVERLAP=false
for ip in $NOT_READY_IPS; do
  if echo "$READY_IPS" | grep -qx "$ip"; then
    OVERLAP=true
  fi
done

if [[ "$OVERLAP" == "false" && -n "$NOT_READY_IPS" ]]; then
  echo "  PASS  Unready pod IPs are absent from ready Service Endpoint addresses"
  ((PASS++)) || true
else
  echo "  FAIL  At least one unready pod IP is still present as a ready endpoint"
  ((FAIL++)) || true
fi

restore_dnsdist
trap - EXIT

check_output "Service Endpoints contain a ready pod IP after readinessProbe is restored" \
  "$KUBECTL get endpoints dnsdist -n $NAMESPACE \
    -o jsonpath='{.subsets[0].addresses[0].ip}' | grep -qE '^[0-9]+\\.'"

echo
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
