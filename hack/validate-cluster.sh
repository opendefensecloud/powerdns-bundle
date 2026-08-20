#!/usr/bin/env bash
# Runs all cluster-dependent validation scripts in dependency order.
# On completion, reports per-suite pass/fail and updates project tracking
# for every validation suite that passes.
#
# Usage: NAMESPACE=dns ./hack/validate-cluster.sh [--cleanup] [--no-tasklist-update] [--suites=<list>]
#
# Environment variables:
#   NAMESPACE              Kubernetes namespace (default: dns)
#   KUBECTL_BIN            kubectl binary (default: kubectl)
#   DNS_ADDRESS            External IP/hostname for the dnsdist LoadBalancer Service
#   RUN_MULTI_INSTANCE     Run multi-instance validation when set to "true"
#   RESTART_TIMEOUT        Seconds to wait for pod restart (default: 120)
#   RECONCILE_TIMEOUT      Seconds to wait for Operator reconciliation (default: 30)
#   TRACKING_DB            Path to the tracking document (unset: tracking disabled)
#   TRACKING_UPDATER       Path to the tracking updater script (unset: tracking disabled)
#   VALIDATION_SUITES      Comma-separated allow-list of suite IDs to run.
#                          Empty / "all" runs every suite (default). Recognised IDs:
#                          operator, lmdb, replication, observability, health-probes,
#                          rolling-update, network-policies, multi-instance, replication-multi.
#                          --suites=<list> overrides
#                          this env var.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACKING_DB="${TRACKING_DB:-}"
TRACKING_UPDATER="${TRACKING_UPDATER:-}"

NAMESPACE="${NAMESPACE:-dns}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
RUN_MULTI_INSTANCE="${RUN_MULTI_INSTANCE:-false}"
CLEANUP=false
UPDATE_TRACKING=true
SUITES_FILTER="${VALIDATION_SUITES:-}"

for arg in "$@"; do
  case "$arg" in
    --cleanup) CLEANUP=true ;;
    --no-tasklist-update) UPDATE_TRACKING=false ;;
    --suites=*) SUITES_FILTER="${arg#--suites=}" ;;
  esac
done

# Normalise the suite allow-list: strip whitespace; "" and "all" mean run everything.
SUITES_FILTER="$(printf '%s' "$SUITES_FILTER" | tr -d '[:space:]')"
if [[ -z "$SUITES_FILTER" || "$SUITES_FILTER" == "all" ]]; then
  SUITES_FILTER=""
fi

suite_enabled() {
  local id="$1"
  [[ -z "$SUITES_FILTER" ]] && return 0
  local IFS=','
  for s in $SUITES_FILTER; do
    [[ "$s" == "$id" ]] && return 0
  done
  return 1
}

export NAMESPACE KUBECTL_BIN

PASS_SUITES=()
FAIL_SUITES=()

# ── Helpers ──────────────────────────────────────────────────────────────────

banner() { echo; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; echo "  $*"; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

run_validation() {
  local label="$1"
  local suite_id="$2"
  local script="$3"
  shift 3

  banner "${label}"

  local extra_args=("$@")
  if NAMESPACE="$NAMESPACE" KUBECTL_BIN="$KUBECTL_BIN" \
      "${SCRIPT_DIR}/${script}" "${extra_args[@]}"; then
    echo; echo "  ✓ PASSED"
    PASS_SUITES+=("$suite_id")
  else
    echo; echo "  ✗ FAILED"
    FAIL_SUITES+=("$suite_id")
  fi
}

CLEANUP_ARG=""
[[ "$CLEANUP" == "true" ]] && CLEANUP_ARG="--cleanup"

# ── Validation suite ─────────────────────────────────────────────────────────

echo "=== Cluster Validation Suite ==="
echo "  Namespace : ${NAMESPACE}"
echo "  Cleanup   : ${CLEANUP}"
echo "  kubectl   : ${KUBECTL_BIN}"
if [[ -n "$SUITES_FILTER" ]]; then
  echo "  Suites    : ${SUITES_FILTER} (filtered)"
else
  echo "  Suites    : all"
fi

maybe_run() {
  local label="$1" suite_id="$2" script="$3"
  shift 3
  if suite_enabled "$suite_id"; then
    run_validation "$label" "$suite_id" "$script" "$@"
  else
    echo
    echo "  ↷ Skipping ${label} (suite '${suite_id}' not in VALIDATION_SUITES filter)"
  fi
}

maybe_run "Operator + CRD Reconciliation"  "operator"       "validate-operator.sh" $CLEANUP_ARG
maybe_run "LMDB Persistence and Recovery"   "lmdb"           "validate-lmdb.sh"     $CLEANUP_ARG
maybe_run "Replication and Recovery"        "replication"    "validate-replication.sh" $CLEANUP_ARG
maybe_run "Prometheus Metrics Endpoints"    "observability"  "validate-observability.sh"
maybe_run "Health Probe Load-Balancing"     "health-probes"  "validate-health-probes.sh"
maybe_run "Rolling Update"                  "rolling-update" "validate-rolling-update.sh"
maybe_run "Network Policy Enforcement"      "network-policies" "validate-network-policies.sh" $CLEANUP_ARG
if [[ "$RUN_MULTI_INSTANCE" == "true" ]]; then
  # --skip-lifecycle: instance A must stay up for the replication-multi suite below.
  # Orphaned namespaces are drained by force_drain_stale_namespace at the start of
  # the next validate-multi-instance.sh run (the intended CI cleanup path).
  maybe_run "Multi-Instance Isolation"      "multi-instance" "validate-multi-instance.sh" --skip-lifecycle
  # Run the replication validation against the first multi-instance namespace (pdns-mi-a)
  # so the Garage S3 path is exercised. NAMESPACE is restored after the call.
  _SAVED_NAMESPACE="$NAMESPACE"
  NAMESPACE="${INSTANCE_A_NAMESPACE:-pdns-mi-a}"
  maybe_run "Replication via Garage (multi-instance)" "replication-multi" "validate-replication.sh" --multi-instance $CLEANUP_ARG
  NAMESPACE="$_SAVED_NAMESPACE"
else
  echo
  echo "Multi-instance validation skipped; set RUN_MULTI_INSTANCE=true to enable it."
fi

# ── Summary ───────────────────────────────────────────────────────────────────

banner "Summary"

ALL_OK=true
[[ ${#FAIL_SUITES[@]} -gt 0 ]] && ALL_OK=false

[[ ${#PASS_SUITES[@]} -gt 0 ]] && echo "  PASSED : ${#PASS_SUITES[@]} suite(s)"
[[ ${#FAIL_SUITES[@]} -gt 0 ]] && echo "  FAILED : ${#FAIL_SUITES[@]} suite(s)"

# ── Tracking update ───────────────────────────────────────────────────────────

if [[ "$UPDATE_TRACKING" == "true" && ${#PASS_SUITES[@]} -gt 0 ]]; then
  if [[ -f "$TRACKING_UPDATER" ]] && [[ -f "$TRACKING_DB" ]]; then
    echo
    echo "  Updating project tracking…"
    if python3 "$TRACKING_UPDATER" "$TRACKING_DB" "${PASS_SUITES[@]}"; then
      echo "  Done."
    else
      echo "  WARNING: tracking update exited non-zero — check project tracking manually."
    fi
  else
    echo
    echo "  INFO: tracking updater not found — project tracking was not updated."
  fi
fi

echo
[[ "$ALL_OK" == "true" ]]
