#!/usr/bin/env bash
# Validates DNS reachability through the dnsdist LoadBalancer Service.
# Requires: kubectl (connected to target cluster), dig
#
# Usage: ./hack/validate-network-access.sh [NAMESPACE] [SERVICE] [TEST_DOMAIN]
#   NAMESPACE    Kubernetes namespace (default: dns)
#   SERVICE      Service name for the DNS frontend (default: dnsdist)
#   TEST_DOMAIN  Domain to query for reachability check (default: example.com)

set -euo pipefail

NAMESPACE="${1:-dns}"
SERVICE="${2:-dnsdist}"
TEST_DOMAIN="${3:-example.com}"

PASS=0
FAIL=1
result=0

require() {
  if ! command -v "$1" &>/dev/null; then
    echo "ERROR: '$1' is required but not installed." >&2
    exit 1
  fi
}

require kubectl
require dig

echo "==> Resolving external address for Service '${SERVICE}' in namespace '${NAMESPACE}'…"

EXTERNAL_IP=$(kubectl get svc -n "${NAMESPACE}" "${SERVICE}" \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

if [ -z "${EXTERNAL_IP}" ]; then
  EXTERNAL_IP=$(kubectl get svc -n "${NAMESPACE}" "${SERVICE}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
fi

if [ -z "${EXTERNAL_IP}" ]; then
  echo "ERROR: No external IP or hostname assigned to Service '${SERVICE}'." >&2
  echo "       Ensure the LoadBalancer has been provisioned and ingress is populated." >&2
  exit 1
fi

echo "    Address: ${EXTERNAL_IP}"

# --- UDP ---
echo ""
echo "==> DNS/UDP port 53 — query '${TEST_DOMAIN}' via @${EXTERNAL_IP}…"
if dig +timeout=5 +tries=1 "@${EXTERNAL_IP}" "${TEST_DOMAIN}" A &>/dev/null; then
  echo "    PASS — DNS/UDP reachable"
else
  echo "    FAIL — DNS/UDP unreachable or no response" >&2
  result=${FAIL}
fi

# --- TCP ---
echo ""
echo "==> DNS/TCP port 53 — query '${TEST_DOMAIN}' via @${EXTERNAL_IP}…"
if dig +timeout=5 +tries=1 +tcp "@${EXTERNAL_IP}" "${TEST_DOMAIN}" A &>/dev/null; then
  echo "    PASS — DNS/TCP reachable"
else
  echo "    FAIL — DNS/TCP unreachable or no response" >&2
  result=${FAIL}
fi

# --- Summary ---
echo ""
if [ "${result}" -eq "${PASS}" ]; then
  echo "RESULT: PASS — DNS frontend '${EXTERNAL_IP}' reachable on UDP/53 and TCP/53."
else
  echo "RESULT: FAIL — one or more checks failed; see output above." >&2
fi

exit "${result}"
