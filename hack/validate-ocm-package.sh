#!/usr/bin/env bash
# Validates the OCM component archive produced by `make ocm-build`.
# Checks structural validity and confirms all expected resources are present.
#
# Usage: ./hack/validate-ocm-package.sh [CTF_FILE]
#   CTF_FILE  Path to the OCM CTF archive (default: ocm/ctf.tar)
#
# Requires: ocm CLI (https://ocm.software)

set -euo pipefail

CTF_FILE="${1:-ocm/ctf.tar}"
COMPONENT_REF="${COMPONENT_REF:-github.com/bwi/powerdns-ocm:0.1.0-poc}"
EXPECTED_RESOURCES=(
  dnsdist
  pdns-recursor
  pdns-authoritative
  lightningstream
  pdns-operator
  garage
  deploy-manifests
  kro-manifests
)

PASS=0
FAIL=1
result=${PASS}

require() {
  if ! command -v "$1" &>/dev/null; then
    echo "ERROR: '$1' is required but not installed." >&2
    echo "       Install from https://ocm.software/docs/getting-started/install-ocm-cli/" >&2
    exit 1
  fi
}

require ocm

if [ ! -f "${CTF_FILE}" ]; then
  echo "ERROR: CTF archive not found at '${CTF_FILE}'." >&2
  echo "       Run 'make ocm-build' first." >&2
  exit 1
fi

echo "==> Validating OCM component archive: ${CTF_FILE}"
echo ""

echo "==> Component version readable by OCM CLI…"
if ocm get componentversion "${CTF_FILE}//${COMPONENT_REF}" &>/dev/null; then
  echo "    PASS"
else
  echo "    FAIL — 'ocm get componentversion' returned non-zero" >&2
  result=${FAIL}
fi

echo ""
echo "==> All expected resources present…"
OCM_OUTPUT=$(ocm get resources "${CTF_FILE}//${COMPONENT_REF}" -o json 2>/dev/null || true)

for resource in "${EXPECTED_RESOURCES[@]}"; do
  if echo "${OCM_OUTPUT}" | grep -q "\"${resource}\""; then
    echo "    PASS — resource '${resource}' found"
  else
    echo "    FAIL — resource '${resource}' missing" >&2
    result=${FAIL}
  fi
done

echo ""
if [ "${result}" -eq "${PASS}" ]; then
  echo "RESULT: PASS — OCM component archive is valid and complete."
else
  echo "RESULT: FAIL — one or more checks failed; see output above." >&2
fi

exit "${result}"
