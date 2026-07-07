#!/usr/bin/env bash
# Validates an OCM-native version upgrade against a live cluster.
#
# Deploys a baseline package, seeds both operator-managed and LMDB-native data,
# upgrades to the candidate package (a real pdns-auth container image bump), and
# asserts that the rollout completed, the new image is running, the pod was
# replaced onto the same persistent volume, and the data survived the upgrade.
#
# Data continuity is checked with an LMDB-native sentinel record written into
# PowerDNS through its own HTTP API that is NOT backed by any Kubernetes custom
# resource, so the operator cannot recreate it — its survival demonstrates that
# the DNS data store carried over the upgrade. The record is written via the
# running Authoritative Server (the only valid LMDB writer in Lightning Stream
# mode); a second writer process such as a standalone pdnsutil cannot safely
# open the externally-locked store.
#
# Required env: BASELINE_DIR, CANDIDATE_DIR, BASELINE_AUTH_IMAGE,
#   CANDIDATE_AUTH_IMAGE (extracted deploy trees and expected pdns-auth images).
# Optional env: NAMESPACE (dns), KUBECTL_BIN (kubectl), ROLLOUT_TIMEOUT (300),
#   PVC_NAME (pdns-auth-data), SENTINEL_ZONE, SENTINEL_API_KEY (changeme),
#   LOCAL_API_PORT (18081).
# Usage: hack/validate-upgrade.sh [--cleanup]
set -euo pipefail

NAMESPACE="${NAMESPACE:-dns}"
KUBECTL="${KUBECTL_BIN:-kubectl}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300}"
RECONCILE_TIMEOUT="${RECONCILE_TIMEOUT:-90}"
PVC_NAME="${PVC_NAME:-pdns-auth-data}"
BASELINE_DIR="${BASELINE_DIR:?BASELINE_DIR is required}"
CANDIDATE_DIR="${CANDIDATE_DIR:?CANDIDATE_DIR is required}"
BASELINE_AUTH_IMAGE="${BASELINE_AUTH_IMAGE:?BASELINE_AUTH_IMAGE is required}"
CANDIDATE_AUTH_IMAGE="${CANDIDATE_AUTH_IMAGE:?CANDIDATE_AUTH_IMAGE is required}"
SENTINEL_ZONE="${SENTINEL_ZONE:-upgrade-sentinel.example.test}"
SENTINEL_TOKEN="upgrade-token-$(date +%s)"
SENTINEL_API_KEY="${SENTINEL_API_KEY:-changeme}"
LOCAL_API_PORT="${LOCAL_API_PORT:-18081}"
ZONE_CR="upgrade-cr.example.com"
LMDB_FILE="/var/lib/powerdns/pdns.lmdb"

CLEANUP=false
for arg in "$@"; do
  [[ "$arg" == "--cleanup" ]] && CLEANUP=true
done

DEPLOYMENTS=(dnsdist pdns-recursor pdns-auth pdns-operator)
CRD="zones.dns.cav.enablers.ob"

PASS=0
FAIL=0

ok()  { echo "  PASS  $1"; ((PASS++)) || true; }
bad() { echo "  FAIL  $1"; ((FAIL++)) || true; }

check() {
  local desc="$1"; shift
  if "$@" &>/dev/null; then ok "$desc"; else bad "$desc"; fi
}

expect_eq() {
  local desc="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    ok "$desc (= ${got})"
  else
    bad "$desc (got '${got}', want '${want}')"
  fi
}

get_auth_pod()    { "$KUBECTL" get pod -n "$NAMESPACE" -l app.kubernetes.io/name=pdns-auth --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true; }
get_auth_uid()    { "$KUBECTL" get pod -n "$NAMESPACE" -l app.kubernetes.io/name=pdns-auth --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.uid}' 2>/dev/null || true; }
get_auth_image()  { "$KUBECTL" get deployment pdns-auth -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[?(@.name=="pdns-auth")].image}' 2>/dev/null || true; }
get_pvc_volume()  { "$KUBECTL" get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true; }

# Calls the pdns-auth HTTP API through a short-lived kubectl port-forward and
# prints the response body. The Authoritative Server is the only valid LMDB
# writer in Lightning Stream mode, so writes must go through it rather than a
# second pdnsutil process. curl runs on the CI runner, so no in-container HTTP
# client is required. Args: METHOD PATH [JSON_BODY].
pdns_api() {
  local method="$1" path="$2" body="${3:-}"
  local base="http://127.0.0.1:${LOCAL_API_PORT}/api/v1/servers/localhost"
  local pf_pid rc=0 ready=false

  "$KUBECTL" port-forward -n "$NAMESPACE" "svc/pdns-auth" "${LOCAL_API_PORT}:8081" >/dev/null 2>&1 &
  pf_pid=$!

  for _ in $(seq 1 30); do
    kill -0 "$pf_pid" 2>/dev/null || break
    if curl -sf -o /dev/null -H "X-API-Key: ${SENTINEL_API_KEY}" "${base}" 2>/dev/null; then
      ready=true
      break
    fi
    sleep 1
  done

  if [[ "$ready" == true ]]; then
    if [[ -n "$body" ]]; then
      curl -fsS -X "$method" "${base}/${path}" \
        -H "X-API-Key: ${SENTINEL_API_KEY}" -H 'Content-Type: application/json' \
        --data-binary "$body" || rc=$?
    else
      curl -fsS -X "$method" "${base}/${path}" \
        -H "X-API-Key: ${SENTINEL_API_KEY}" || rc=$?
    fi
  else
    rc=1
  fi

  kill "$pf_pid" >/dev/null 2>&1 || true
  wait "$pf_pid" 2>/dev/null || true
  return "$rc"
}

# Polls the Auth server (through the operator-reconciled HTTP API) until the
# operator-managed Zone CR has actually been loaded, so the pre-upgrade state is
# deterministic instead of relying on a fixed settle delay.
wait_zone_reconciled() {
  local zone="$1" deadline=$((SECONDS + RECONCILE_TIMEOUT))
  while (( SECONDS < deadline )); do
    if pdns_api GET "zones/${zone}." 2>/dev/null | grep -q -- "\"${zone}.\""; then
      return 0
    fi
    sleep 3
  done
  return 1
}

apply_tree() {
  "$KUBECTL" apply -k "$1" >/dev/null
  "$KUBECTL" wait crd/"$CRD" --for=condition=Established --timeout=120s >/dev/null 2>&1 || true
  local d
  for d in "${DEPLOYMENTS[@]}"; do
    "$KUBECTL" rollout status "deployment/${d}" -n "$NAMESPACE" --timeout="${ROLLOUT_TIMEOUT}s" >/dev/null
  done
}

echo "=== OCM Package Upgrade Validation ==="
echo "  Baseline : ${BASELINE_AUTH_IMAGE}"
echo "  Candidate: ${CANDIDATE_AUTH_IMAGE}"
echo

echo "--- 1. Deploy baseline package ---"
apply_tree "$BASELINE_DIR"
expect_eq "pdns-auth runs the baseline image" "$(get_auth_image)" "$BASELINE_AUTH_IMAGE"

PVC_BEFORE="$(get_pvc_volume)"
UID_BEFORE="$(get_auth_uid)"
check "bound PVC ${PVC_NAME} present before upgrade" test -n "$PVC_BEFORE"

echo
echo "--- 2. Seed operator-managed and LMDB-native data ---"
# Operator-managed Zone: proves the controller path works across the upgrade.
"$KUBECTL" apply -f - >/dev/null <<EOF
apiVersion: dns.cav.enablers.ob/v1alpha2
kind: Zone
metadata:
  name: ${ZONE_CR}
  namespace: ${NAMESPACE}
spec:
  kind: Native
  nameservers:
    - ns1.example.com.
EOF
check "operator-managed Zone CR created" "$KUBECTL" get zone "$ZONE_CR" -n "$NAMESPACE"
# Gate on the operator actually reconciling the zone into the Auth server before the
# upgrade, instead of a fixed settle delay, so the operator-managed data path is
# genuinely exercised across the upgrade rather than racing reconciliation.
check "operator-managed Zone reconciled into Auth server before upgrade" \
  wait_zone_reconciled "$ZONE_CR"

# LMDB-native sentinel: a zone written through the Authoritative Server's own
# HTTP API. It is real DNS data in the LMDB store but is NOT backed by any CR,
# so the operator cannot recreate it; its survival demonstrates that the DNS
# data store carried over the upgrade. Delete first so a leftover zone from an
# earlier run cannot mask a write failure.
SENTINEL_BODY="$(cat <<JSON
{"name":"${SENTINEL_ZONE}.","kind":"Native","nameservers":["ns1.example.com."],"rrsets":[{"name":"token.${SENTINEL_ZONE}.","type":"TXT","ttl":3600,"records":[{"content":"\"${SENTINEL_TOKEN}\"","disabled":false}]}]}
JSON
)"
pdns_api DELETE "zones/${SENTINEL_ZONE}." >/dev/null 2>&1 || true
SEED_OUT="$(pdns_api POST "zones" "$SENTINEL_BODY" 2>&1 || true)"
SENTINEL_BEFORE="$(pdns_api GET "zones/${SENTINEL_ZONE}." 2>/dev/null || true)"
if grep -q -- "$SENTINEL_TOKEN" <<<"$SENTINEL_BEFORE"; then
  ok "LMDB-native sentinel record written before upgrade"
else
  bad "could not write LMDB-native sentinel record before upgrade"
  [[ -n "$SEED_OUT" ]] && echo "    API response: ${SEED_OUT}"
fi

echo
echo "--- 3. Upgrade to candidate package ---"
apply_tree "$CANDIDATE_DIR"
GEN="$("$KUBECTL" get deployment pdns-auth -n "$NAMESPACE" -o jsonpath='{.metadata.generation}' 2>/dev/null || echo 0)"
OBS="$("$KUBECTL" get deployment pdns-auth -n "$NAMESPACE" -o jsonpath='{.status.observedGeneration}' 2>/dev/null || echo 0)"
check "pdns-auth observedGeneration caught up with spec" test "$OBS" -ge "$GEN"
expect_eq "pdns-auth now runs the candidate image" "$(get_auth_image)" "$CANDIDATE_AUTH_IMAGE"

UID_AFTER="$(get_auth_uid)"
if [[ -n "$UID_BEFORE" && "$UID_BEFORE" != "$UID_AFTER" ]]; then
  ok "pdns-auth pod was replaced (uid ${UID_BEFORE} -> ${UID_AFTER})"
else
  bad "pdns-auth pod was not replaced (uid '${UID_BEFORE}' -> '${UID_AFTER}')"
fi
expect_eq "pdns-auth PVC volume unchanged across upgrade" "$(get_pvc_volume)" "$PVC_BEFORE"

echo
echo "--- 4. Verify data continuity ---"
POD_AFTER="$(get_auth_pod)"
check "LMDB database file present after upgrade (${LMDB_FILE})" \
  "$KUBECTL" exec "$POD_AFTER" -n "$NAMESPACE" -c pdns-auth -- ls "$LMDB_FILE"
SENTINEL_AFTER="$(pdns_api GET "zones/${SENTINEL_ZONE}." 2>/dev/null || true)"
if [[ -n "$POD_AFTER" ]] && grep -q -- "$SENTINEL_TOKEN" <<<"$SENTINEL_AFTER"; then
  ok "LMDB-native sentinel survived the upgrade (data continuity confirmed)"
else
  bad "LMDB-native sentinel missing after upgrade — data was NOT preserved"
fi
check "operator-managed Zone CR still present after upgrade" \
  "$KUBECTL" get zone "$ZONE_CR" -n "$NAMESPACE"

echo
echo "--- 5. Roll back to baseline package ---"
# Rollback smoke for the pinned patch pair (candidate -> baseline): a downgrade to the
# previous pdns-auth image must keep serving the same PVC and preserve data written
# before/under the candidate. This is intentionally NOT a general cross-version downgrade
# guarantee — it must not be repointed across an on-disk LMDB schema boundary (e.g. 5.0).
UID_CANDIDATE="$UID_AFTER"
apply_tree "$BASELINE_DIR"
GEN_RB="$("$KUBECTL" get deployment pdns-auth -n "$NAMESPACE" -o jsonpath='{.metadata.generation}' 2>/dev/null || echo 0)"
OBS_RB="$("$KUBECTL" get deployment pdns-auth -n "$NAMESPACE" -o jsonpath='{.status.observedGeneration}' 2>/dev/null || echo 0)"
check "pdns-auth observedGeneration caught up after rollback" test "$OBS_RB" -ge "$GEN_RB"
expect_eq "pdns-auth deployment reverted to the baseline image" "$(get_auth_image)" "$BASELINE_AUTH_IMAGE"

UID_ROLLBACK="$(get_auth_uid)"
if [[ -n "$UID_CANDIDATE" && "$UID_CANDIDATE" != "$UID_ROLLBACK" ]]; then
  ok "pdns-auth pod was replaced on rollback (uid ${UID_CANDIDATE} -> ${UID_ROLLBACK})"
else
  bad "pdns-auth pod was not replaced on rollback (uid '${UID_CANDIDATE}' -> '${UID_ROLLBACK}')"
fi
expect_eq "pdns-auth PVC volume unchanged across rollback" "$(get_pvc_volume)" "$PVC_BEFORE"

echo
echo "--- 6. Verify data continuity after rollback ---"
POD_ROLLBACK="$(get_auth_pod)"
check "LMDB database file present after rollback (${LMDB_FILE})" \
  "$KUBECTL" exec "$POD_ROLLBACK" -n "$NAMESPACE" -c pdns-auth -- ls "$LMDB_FILE"
SENTINEL_ROLLBACK="$(pdns_api GET "zones/${SENTINEL_ZONE}." 2>/dev/null || true)"
if [[ -n "$POD_ROLLBACK" ]] && grep -q -- "$SENTINEL_TOKEN" <<<"$SENTINEL_ROLLBACK"; then
  ok "LMDB-native sentinel survived the rollback (data continuity confirmed)"
else
  bad "LMDB-native sentinel missing after rollback — data was NOT preserved"
fi
check "operator-managed Zone CR still present after rollback" \
  "$KUBECTL" get zone "$ZONE_CR" -n "$NAMESPACE"

if [[ "$CLEANUP" == "true" ]]; then
  echo
  echo "--- 7. Cleanup ---"
  "$KUBECTL" delete zone "$ZONE_CR" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
  pdns_api DELETE "zones/${SENTINEL_ZONE}." >/dev/null 2>&1 || true
  echo "  removed operator-managed Zone CR and LMDB-native sentinel zone"
fi

echo
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
