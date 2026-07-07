#!/usr/bin/env bash
# Validates KRO-managed multi-instance deployment and isolation.
# Usage: ./hack/validate-multi-instance.sh [--cleanup] [--skip-create] [--skip-lifecycle]
set -euo pipefail

KUBECTL="${KUBECTL_BIN:-kubectl}"
RECONCILE_TIMEOUT="${RECONCILE_TIMEOUT:-90}"
ROLLBACK_TIMEOUT="${ROLLBACK_TIMEOUT:-120}"
INSTANCE_A_NAME="${INSTANCE_A_NAME:-pdns-mi-a}"
INSTANCE_B_NAME="${INSTANCE_B_NAME:-pdns-mi-b}"
INSTANCE_A_NAMESPACE="${INSTANCE_A_NAMESPACE:-pdns-mi-a}"
INSTANCE_B_NAMESPACE="${INSTANCE_B_NAMESPACE:-pdns-mi-b}"
KRO_NAMESPACE="${KRO_NAMESPACE:-default}"
PDNS_API_KEY_A="${PDNS_API_KEY_A:-changeme-a}"
PDNS_API_KEY_B="${PDNS_API_KEY_B:-changeme-b}"
VALIDATION_VERBOSE="${VALIDATION_VERBOSE:-0}"
CREATE_INSTANCES=true
CLEANUP=false
RUN_LIFECYCLE=true

for arg in "$@"; do
  [[ "$arg" == "--cleanup" ]] && CLEANUP=true
  [[ "$arg" == "--skip-create" ]] && CREATE_INSTANCES=false
  [[ "$arg" == "--skip-lifecycle" ]] && RUN_LIFECYCLE=false
  [[ "$arg" == "--lifecycle" ]] && RUN_LIFECYCLE=true
done

if [[ "$CREATE_INSTANCES" == "false" ]]; then
  RUN_LIFECYCLE=false
fi

PASS=0
FAIL=0
WARN=0
LAST_CHECK_PASSED=true
LAST_CHECK_OUTPUT=""
LAST_PROBE_DETAIL=""
STACK_READY_FAILED=false

_emit_detail() {
  # Indents and prints a multi-line context block under a PASS/FAIL line.
  local detail="$1"
  [[ -n "$detail" ]] || return 0
  printf '%s\n' "$detail" | sed 's/^/    /'
}

check() {
  local desc="$1"; shift
  local output
  if output="$("$@" 2>&1)"; then
    LAST_CHECK_PASSED=true
    LAST_CHECK_OUTPUT="$output"
    echo "  PASS  $desc"
    if [[ "$VALIDATION_VERBOSE" == "1" && -n "$output" ]]; then
      _emit_detail "$output"
    fi
    ((PASS++)) || true
  else
    LAST_CHECK_PASSED=false
    LAST_CHECK_OUTPUT="$output"
    echo "  FAIL  $desc"
    _emit_detail "$output"
    ((FAIL++)) || true
  fi
}

check_absent() {
  local desc="$1"; shift
  local output
  if output="$("$@" 2>&1)"; then
    LAST_CHECK_PASSED=false
    LAST_CHECK_OUTPUT="$output"
    echo "  FAIL  $desc"
    _emit_detail "$output"
    ((FAIL++)) || true
  else
    LAST_CHECK_PASSED=true
    LAST_CHECK_OUTPUT="$output"
    echo "  PASS  $desc"
    if [[ "$VALIDATION_VERBOSE" == "1" && -n "$output" ]]; then
      _emit_detail "$output"
    fi
    ((PASS++)) || true
  fi
}

# Asserts a probe (which must populate LAST_PROBE_DETAIL) returns non-zero.
# Used for "should NOT be present" runtime checks where we want the captured
# probe context dumped on failure.
check_probe_absent() {
  local desc="$1"; shift
  LAST_PROBE_DETAIL=""
  if "$@"; then
    LAST_CHECK_PASSED=false
    echo "  FAIL  $desc"
    _emit_detail "$LAST_PROBE_DETAIL"
    ((FAIL++)) || true
  else
    LAST_CHECK_PASSED=true
    echo "  PASS  $desc"
    if [[ "$VALIDATION_VERBOSE" == "1" ]]; then
      _emit_detail "$LAST_PROBE_DETAIL"
    fi
    ((PASS++)) || true
  fi
}

# Asserts a probe (which must populate LAST_PROBE_DETAIL) returns zero.
check_probe_present() {
  local desc="$1"; shift
  LAST_PROBE_DETAIL=""
  if "$@"; then
    LAST_CHECK_PASSED=true
    echo "  PASS  $desc"
    if [[ "$VALIDATION_VERBOSE" == "1" ]]; then
      _emit_detail "$LAST_PROBE_DETAIL"
    fi
    ((PASS++)) || true
  else
    LAST_CHECK_PASSED=false
    echo "  FAIL  $desc"
    _emit_detail "$LAST_PROBE_DETAIL"
    ((FAIL++)) || true
  fi
}

warn() {
  echo "  WARN  $*"
  ((WARN++)) || true
}

apply_instances() {
  cat <<EOF | "$KUBECTL" apply -f - >/dev/null
apiVersion: kro.run/v1alpha1
kind: PowerDNSInstance
metadata:
  name: ${INSTANCE_A_NAME}
  namespace: ${KRO_NAMESPACE}
spec:
  namespace: ${INSTANCE_A_NAMESPACE}
  pdnsApiKey: ${PDNS_API_KEY_A}
  multiInstance: true
---
apiVersion: kro.run/v1alpha1
kind: PowerDNSInstance
metadata:
  name: ${INSTANCE_B_NAME}
  namespace: ${KRO_NAMESPACE}
spec:
  namespace: ${INSTANCE_B_NAMESPACE}
  pdnsApiKey: ${PDNS_API_KEY_B}
  multiInstance: true
EOF
}

delete_instance() {
  local name="$1"
  "$KUBECTL" delete powerdnsinstance "$name" -n "$KRO_NAMESPACE" \
    --ignore-not-found \
    --wait=false \
    --timeout=30s >/dev/null
}

# Force-clears finalizers on every namespaced resource in $1 and waits for the
# namespace to fully disappear. Used to recover from stuck Terminating
# namespaces left over by a previous run (KRO/operator finalizers that outlived
# their controllers), which otherwise block KRO's targetNamespace node from
# reconciling. Idempotent: silently no-ops if the namespace does not exist.
force_drain_stale_namespace() {
  local namespace="$1"
  local drain_timeout="${STALE_NS_DRAIN_TIMEOUT:-90}"

  "$KUBECTL" get namespace "$namespace" >/dev/null 2>&1 || return 0

  echo "  INFO  Draining stale namespace ${namespace} before reconciliation"

  "$KUBECTL" delete namespace "$namespace" --ignore-not-found --wait=false --timeout=30s >/dev/null 2>&1 || true

  # Give the namespace a short grace period to drain naturally before doing
  # the expensive resource enumeration. In the common case (no stuck
  # finalizers) the namespace disappears within a few seconds and we save
  # ~30-60s of kubectl get calls per namespace.
  local grace="${STALE_NS_GRACE:-10}"
  local i
  for i in $(seq 1 "$grace"); do
    if ! "$KUBECTL" get namespace "$namespace" >/dev/null 2>&1; then
      echo "  INFO  Stale namespace ${namespace} drained naturally after ${i}s"
      return 0
    fi
    sleep 1
  done

  echo "  INFO  Stale namespace ${namespace} still Terminating after ${grace}s; clearing finalizers on contained resources"

  local api_resources resource items name
  api_resources="$("$KUBECTL" api-resources --verbs=list --namespaced -o name 2>/dev/null \
    | grep -Ev '^(events(\.events\.k8s\.io)?|bindings|tokenreviews|localsubjectaccessreviews|selfsubjectaccessreviews|selfsubjectrulesreviews|subjectaccessreviews)$' || true)"

  for resource in $api_resources; do
    items="$("$KUBECTL" get "$resource" -n "$namespace" -o jsonpath='{range .items[?(@.metadata.finalizers)]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
    [[ -z "$items" ]] && continue
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      "$KUBECTL" patch "$resource" "$name" -n "$namespace" --type=merge \
        -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    done <<<"$items"
  done

  for i in $(seq 1 "$drain_timeout"); do
    if ! "$KUBECTL" get namespace "$namespace" >/dev/null 2>&1; then
      echo "  INFO  Stale namespace ${namespace} drained after ${i}s"
      return 0
    fi
    sleep 1
  done

  echo "  WARN  Stale namespace ${namespace} still present after ${drain_timeout}s; clearing namespace finalizers"
  "$KUBECTL" patch namespace "$namespace" --type=merge \
    -p '{"metadata":{"finalizers":[]},"spec":{"finalizers":[]}}' >/dev/null 2>&1 || true
  for i in $(seq 1 30); do
    "$KUBECTL" get namespace "$namespace" >/dev/null 2>&1 || return 0
    sleep 1
  done
  echo "  WARN  Namespace ${namespace} did not finish deleting; continuing anyway"
  return 0
}

delete_instance_finalizer_if_stuck() {
  local name="$1"
  if "$KUBECTL" get powerdnsinstance "$name" -n "$KRO_NAMESPACE" >/dev/null 2>&1; then
    "$KUBECTL" patch powerdnsinstance "$name" -n "$KRO_NAMESPACE" --type merge \
      -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    "$KUBECTL" delete powerdnsinstance "$name" -n "$KRO_NAMESPACE" \
      --ignore-not-found \
      --wait=false \
      --timeout=30s >/dev/null 2>&1 || true
  fi
}

powerdnsinstance_api_available() {
  "$KUBECTL" api-resources --api-group=kro.run --no-headers \
    | awk '{print $1}' \
    | grep -qx "powerdnsinstances"
}

wait_for_powerdnsinstance_api() {
  for _ in $(seq 1 "$RECONCILE_TIMEOUT"); do
    if powerdnsinstance_api_available; then
      return 0
    fi
    sleep 1
  done

  echo "  INFO  ResourceGraphDefinition status:"
  "$KUBECTL" get resourcegraphdefinition powerdnsinstance -o yaml 2>/dev/null \
    | sed -n '/^status:/,$p' || true
  return 1
}

wait_namespace_exists() {
  local namespace="$1" instance="$2"

  for _ in $(seq 1 "$RECONCILE_TIMEOUT"); do
    if "$KUBECTL" get namespace "$namespace" >/dev/null 2>&1; then
      return 0
    fi
    if powerdnsinstance_terminal_failure "$instance"; then
      return 1
    fi
    sleep 1
  done

  echo "Namespace ${namespace} did not appear within ${RECONCILE_TIMEOUT}s"
  return 1
}

powerdnsinstance_terminal_failure() {
  local name="$1"
  local state message

  state="$("$KUBECTL" get powerdnsinstance "$name" -n "$KRO_NAMESPACE" \
    -o jsonpath='{.status.state}' 2>/dev/null || true)"
  message="$("$KUBECTL" get powerdnsinstance "$name" -n "$KRO_NAMESPACE" \
    -o jsonpath='{range .status.conditions[*]}{.message}{"\n"}{end}' 2>/dev/null || true)"

  if [[ "$state" == "ERROR" || "$state" == "DELETING" ]]; then
    echo "PowerDNSInstance ${KRO_NAMESPACE}/${name} is ${state}"
    [[ -n "$message" ]] && printf '%s\n' "$message" | sed 's/^/  /'
    return 0
  fi

  if [[ "$message" == *'cannot get resource "namespaces"'* || "$message" == *"forbidden:"* ]]; then
    echo "PowerDNSInstance ${KRO_NAMESPACE}/${name} reported an RBAC error"
    printf '%s\n' "$message" | sed 's/^/  /'
    return 0
  fi

  return 1
}

wait_deployment_available() {
  local namespace="$1" deployment="$2"
  for _ in $(seq 1 "$RECONCILE_TIMEOUT"); do
    if "$KUBECTL" get deployment "$deployment" -n "$namespace" >/dev/null 2>&1; then
      "$KUBECTL" wait "deployment/${deployment}" -n "$namespace" \
        --for=condition=Available \
        "--timeout=${ROLLBACK_TIMEOUT}s"
      return
    fi
    sleep 1
  done

  echo "Deployment ${namespace}/${deployment} did not appear within ${RECONCILE_TIMEOUT}s"
  return 1
}

wait_secret_exists() {
  local namespace="$1" secret="$2"
  for _ in $(seq 1 "$RECONCILE_TIMEOUT"); do
    if "$KUBECTL" get secret "$secret" -n "$namespace" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "Secret ${namespace}/${secret} did not appear within ${RECONCILE_TIMEOUT}s"
  return 1
}

print_powerdnsinstance_diagnostics() {
  local name
  for name in "$INSTANCE_A_NAME" "$INSTANCE_B_NAME"; do
    echo "  INFO  PowerDNSInstance ${KRO_NAMESPACE}/${name} status:"
    "$KUBECTL" get powerdnsinstance "$name" -n "$KRO_NAMESPACE" -o yaml 2>/dev/null \
      | sed -n '/^status:/,$p' \
      | sed 's/^/    /' || true
  done

  echo "  INFO  Recent KRO namespace events:"
  "$KUBECTL" get events -n "$KRO_NAMESPACE" --sort-by=.lastTimestamp 2>/dev/null \
    | tail -n 20 \
    | sed 's/^/    /' || true
}

print_container_logs() {
  local namespace="$1" pod="$2" container="$3"
  local output

  echo "    Logs pod/${pod} container/${container} (tail 80):"
  output="$("$KUBECTL" logs "$pod" -n "$namespace" -c "$container" \
    --tail=80 --timestamps=true 2>&1 || true)"
  if [[ -n "$output" ]]; then
    printf '%s\n' "$output" | sed 's/^/      /'
  else
    echo "      (no current logs)"
  fi

  output="$("$KUBECTL" logs "$pod" -n "$namespace" -c "$container" \
    --previous --tail=80 --timestamps=true 2>&1 || true)"
  if [[ -n "$output" && "$output" != *"previous terminated container"* ]]; then
    echo "    Previous logs pod/${pod} container/${container} (tail 80):"
    printf '%s\n' "$output" | sed 's/^/      /'
  fi
}

print_namespace_stack_diagnostics() {
  local namespace="$1"
  local deployment pod container

  echo "  INFO  Generated stack diagnostics for namespace ${namespace}:"
  if ! "$KUBECTL" get namespace "$namespace" >/dev/null 2>&1; then
    echo "    Namespace ${namespace} does not exist."
    return
  fi

  echo "    Resources:"
  "$KUBECTL" get deployments,pods,pvc,svc -n "$namespace" -o wide 2>&1 \
    | sed 's/^/      /' || true

  echo "    Deployment status:"
  for deployment in garage pdns-auth pdns-recursor dnsdist pdns-operator; do
    if "$KUBECTL" get deployment "$deployment" -n "$namespace" >/dev/null 2>&1; then
      "$KUBECTL" get deployment "$deployment" -n "$namespace" \
        -o jsonpath='      {.metadata.name}: replicas={.status.replicas} ready={.status.readyReplicas} available={.status.availableReplicas} updated={.status.updatedReplicas} unavailable={.status.unavailableReplicas}{"\n"}' \
        2>/dev/null || true
      "$KUBECTL" describe deployment "$deployment" -n "$namespace" 2>&1 \
        | sed 's/^/      /' || true
    else
      echo "      deployment/${deployment}: not found"
    fi
  done

  for pod in $("$KUBECTL" get pods -n "$namespace" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true); do
    echo "    Describe pod/${pod}:"
    "$KUBECTL" describe pod "$pod" -n "$namespace" 2>&1 \
      | sed 's/^/      /' || true

    for container in $("$KUBECTL" get pod "$pod" -n "$namespace" \
        -o jsonpath='{range .spec.initContainers[*]}{.name}{"\n"}{end}{range .spec.containers[*]}{.name}{"\n"}{end}' 2>/dev/null || true); do
      print_container_logs "$namespace" "$pod" "$container"
    done
  done

  echo "    Recent namespace events:"
  "$KUBECTL" get events -n "$namespace" --sort-by=.lastTimestamp 2>&1 \
    | tail -n 40 \
    | sed 's/^/      /' || true
}

print_generated_stack_diagnostics() {
  print_namespace_stack_diagnostics "$INSTANCE_A_NAMESPACE"
  print_namespace_stack_diagnostics "$INSTANCE_B_NAMESPACE"
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

apply_zone_and_rrset() {
  local namespace="$1" zone="$2" record="$3" address="$4"
  cat <<EOF | "$KUBECTL" apply -f - >/dev/null
apiVersion: dns.cav.enablers.ob/v1alpha2
kind: Zone
metadata:
  name: ${zone}
  namespace: ${namespace}
spec:
  kind: Native
  nameservers:
    - ns1.${zone}.
---
apiVersion: dns.cav.enablers.ob/v1alpha2
kind: RRset
metadata:
  name: ${record}
  namespace: ${namespace}
spec:
  name: ${record}.
  type: A
  ttl: 300
  records:
    - ${address}
  zoneRef:
    name: ${zone}
    kind: Zone
EOF
}

auth_has_zone() {
  local namespace="$1" zone="$2" api_key="$3"
  local pod tool url body code rc=1
  LAST_PROBE_DETAIL=""

  pod="$("$KUBECTL" get pod -n "$namespace" -l app.kubernetes.io/name=pdns-auth \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

  if [[ -z "$pod" ]]; then
    LAST_PROBE_DETAIL="ns=$namespace zone=$zone: no pdns-auth pod found"
    return 1
  fi

  if "$KUBECTL" exec "$pod" -n "$namespace" -c pdns-auth -- \
      sh -c "command -v pdnsutil" >/dev/null 2>&1; then
    tool=pdnsutil
    body="$("$KUBECTL" exec "$pod" -n "$namespace" -c pdns-auth -- \
      pdnsutil list-zone "$zone" 2>&1)" && rc=0 || rc=$?
    LAST_PROBE_DETAIL="ns=$namespace pod=$pod tool=$tool zone=$zone rc=$rc"$'\n'"$(printf '%s' "$body" | head -c 800)"
  elif "$KUBECTL" exec "$pod" -n "$namespace" -c pdns-auth -- \
      sh -c "command -v curl" >/dev/null 2>&1; then
    tool=curl
    url="http://localhost:8081/api/v1/servers/localhost/zones/${zone}"
    body="$("$KUBECTL" exec "$pod" -n "$namespace" -c pdns-auth -- \
      curl -s -o - -w '\nHTTP_CODE=%{http_code}' \
      -H "X-API-Key: ${api_key}" "$url" 2>&1)" || true
    code="$(printf '%s\n' "$body" | sed -n 's/^HTTP_CODE=//p' | tail -1)"
    [[ "$code" == "200" ]] && rc=0 || rc=1
    LAST_PROBE_DETAIL="ns=$namespace pod=$pod tool=$tool zone=$zone url=$url http=$code rc=$rc"$'\n'"$(printf '%s' "$body" | head -c 800)"
  elif "$KUBECTL" exec "$pod" -n "$namespace" -c pdns-auth -- \
      sh -c "command -v wget" >/dev/null 2>&1; then
    tool=wget
    url="http://localhost:8081/api/v1/servers/localhost/zones/${zone}"
    body="$("$KUBECTL" exec "$pod" -n "$namespace" -c pdns-auth -- \
      wget -qO- --header "X-API-Key: ${api_key}" "$url" 2>&1)" && rc=0 || rc=$?
    LAST_PROBE_DETAIL="ns=$namespace pod=$pod tool=$tool zone=$zone url=$url rc=$rc"$'\n'"$(printf '%s' "$body" | head -c 800)"
  else
    LAST_PROBE_DETAIL="ns=$namespace pod=$pod zone=$zone: no probe tool (pdnsutil/curl/wget) available"
    rc=1
  fi
  return "$rc"
}

dump_step6_diagnostics() {
  local ns
  echo "  INFO  Runtime-isolation diagnostics (auto-dumped on FAIL):"
  for ns in "$INSTANCE_A_NAMESPACE" "$INSTANCE_B_NAMESPACE"; do
    echo "    --- ns=$ns ---"
    echo "    [Zone CRs in $ns]:"
    "$KUBECTL" get zone -n "$ns" 2>&1 | sed 's/^/      /' || true
    echo "    [auth pdnsutil list-zones]:"
    "$KUBECTL" exec -n "$ns" deploy/pdns-auth -c pdns-auth -- pdnsutil list-zones 2>&1 \
      | head -c 4000 | sed 's/^/      /' || true
    echo
    echo "    [lightningstream tail]:"
    "$KUBECTL" logs -n "$ns" deploy/pdns-auth -c lightningstream --tail=40 2>&1 \
      | sed 's/^/      /' || true
    echo "    [pdns-operator tail]:"
    "$KUBECTL" logs -n "$ns" deploy/pdns-operator --tail=40 2>&1 \
      | sed 's/^/      /' || true
    echo "    [pdns-operator env]:"
    "$KUBECTL" get deployment pdns-operator -n "$ns" \
      -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' 2>&1 \
      | sed 's/^/      /' || true
    echo "    [pdns-operator args]:"
    "$KUBECTL" get deployment pdns-operator -n "$ns" \
      -o jsonpath='{.spec.template.spec.containers[0].args}{"\n"}' 2>&1 \
      | sed 's/^/      /' || true
  done
}

cleanup_validation_records() {
  "$KUBECTL" delete rrset a.multi-a.example.com -n "$INSTANCE_A_NAMESPACE" --ignore-not-found --wait=false --timeout=30s >/dev/null 2>&1 || true
  "$KUBECTL" delete zone multi-a.example.com -n "$INSTANCE_A_NAMESPACE" --ignore-not-found --wait=false --timeout=30s >/dev/null 2>&1 || true
  "$KUBECTL" delete rrset b.multi-b.example.com -n "$INSTANCE_B_NAMESPACE" --ignore-not-found --wait=false --timeout=30s >/dev/null 2>&1 || true
  "$KUBECTL" delete zone multi-b.example.com -n "$INSTANCE_B_NAMESPACE" --ignore-not-found --wait=false --timeout=30s >/dev/null 2>&1 || true
}

echo "=== Multi-Instance Validation ==="
echo "  Instance A : ${INSTANCE_A_NAME} -> ${INSTANCE_A_NAMESPACE}"
echo "  Instance B : ${INSTANCE_B_NAME} -> ${INSTANCE_B_NAMESPACE}"
echo "  KRO ns     : ${KRO_NAMESPACE}"
echo "  Cleanup    : ${CLEANUP}"
echo "  Lifecycle  : ${RUN_LIFECYCLE}"
echo

echo "--- 1. KRO prerequisites ---"
check "ResourceGraphDefinition powerdnsinstance exists" \
  "$KUBECTL" get resourcegraphdefinition powerdnsinstance
check "PowerDNSInstance API is available" \
  wait_for_powerdnsinstance_api

if [[ "$CREATE_INSTANCES" == "true" ]]; then
  echo
  echo "--- 2. Create two validation instances ---"
  force_drain_stale_namespace "$INSTANCE_A_NAMESPACE"
  force_drain_stale_namespace "$INSTANCE_B_NAMESPACE"
  check "PowerDNSInstance resources applied" apply_instances
else
  echo
  echo "--- 2. Reuse existing validation instances ---"
fi

check "PowerDNSInstance ${INSTANCE_A_NAME} exists" \
  "$KUBECTL" get powerdnsinstance "$INSTANCE_A_NAME" -n "$KRO_NAMESPACE"
check "PowerDNSInstance ${INSTANCE_B_NAME} exists" \
  "$KUBECTL" get powerdnsinstance "$INSTANCE_B_NAME" -n "$KRO_NAMESPACE"

echo
echo "--- 3. Namespaced stack readiness ---"
STACK_READY_FAILURES_BEFORE="$FAIL"
for ns in "$INSTANCE_A_NAMESPACE" "$INSTANCE_B_NAMESPACE"; do
  instance="$INSTANCE_A_NAME"
  [[ "$ns" == "$INSTANCE_B_NAMESPACE" ]] && instance="$INSTANCE_B_NAME"
  check "Namespace ${ns} exists" wait_namespace_exists "$ns" "$instance"
  [[ "$LAST_CHECK_PASSED" == "true" ]] || continue
  check "${ns}: pdns-auth available" wait_deployment_available "$ns" pdns-auth
  [[ "$LAST_CHECK_PASSED" == "true" ]] || continue
  check "${ns}: pdns-recursor available" wait_deployment_available "$ns" pdns-recursor
  check "${ns}: dnsdist available" wait_deployment_available "$ns" dnsdist
  check "${ns}: pdns-operator available" wait_deployment_available "$ns" pdns-operator
  check "${ns}: garage available" wait_deployment_available "$ns" garage
  check "${ns}: namespace-local API Secret exists" \
    wait_secret_exists "$ns" pdns-operator-api-key
done

if [[ "$FAIL" -gt "$STACK_READY_FAILURES_BEFORE" ]]; then
  STACK_READY_FAILED=true
  echo
  echo "  INFO  KRO did not finish generating the expected namespaced stacks."
  print_powerdnsinstance_diagnostics
  print_generated_stack_diagnostics
else
  echo
  echo "--- 4. Operator scope guardrail ---"
  OPERATOR_ARGS_A="$("$KUBECTL" get deployment pdns-operator -n "$INSTANCE_A_NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null || true)"
  OPERATOR_ARGS_B="$("$KUBECTL" get deployment pdns-operator -n "$INSTANCE_B_NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null || true)"
  OPERATOR_ENV_A="$("$KUBECTL" get deployment pdns-operator -n "$INSTANCE_A_NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' 2>/dev/null || true)"
  OPERATOR_ENV_B="$("$KUBECTL" get deployment pdns-operator -n "$INSTANCE_B_NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' 2>/dev/null || true)"

  if [[ "$OPERATOR_ARGS_A $OPERATOR_ARGS_B $OPERATOR_ENV_A $OPERATOR_ENV_B" == *"WATCH_NAMESPACE"* \
      || "$OPERATOR_ARGS_A $OPERATOR_ARGS_B" == *"namespace"* ]]; then
    echo "  PASS  Operator deployment exposes namespace-scope configuration"
    ((PASS++)) || true
  else
    warn "Operator deployment does not expose namespace-scope configuration; runtime isolation must be verified below"
    echo "    [pdns-operator/${INSTANCE_A_NAMESPACE} args]: ${OPERATOR_ARGS_A:-<none>}"
    echo "    [pdns-operator/${INSTANCE_A_NAMESPACE} env names]: ${OPERATOR_ENV_A:-<none>}"
    echo "    [pdns-operator/${INSTANCE_B_NAMESPACE} args]: ${OPERATOR_ARGS_B:-<none>}"
    echo "    [pdns-operator/${INSTANCE_B_NAMESPACE} env names]: ${OPERATOR_ENV_B:-<none>}"
  fi

  # Negative RBAC test: each operator ServiceAccount must be confined to its
  # own namespace. We probe with `kubectl auth can-i`, which evaluates the
  # cluster's RBAC bindings without mutating anything (fast, no API writes).
  sa_a="system:serviceaccount:${INSTANCE_A_NAMESPACE}:pdns-operator"
  sa_b="system:serviceaccount:${INSTANCE_B_NAMESPACE}:pdns-operator"
  for verb in create delete; do
    for kind in zones rrsets; do
      check "${sa_a} CAN ${verb} ${kind} in own ns ${INSTANCE_A_NAMESPACE}" \
        "$KUBECTL" auth can-i "$verb" "$kind" -n "$INSTANCE_A_NAMESPACE" --as="$sa_a" --quiet
      check "${sa_b} CAN ${verb} ${kind} in own ns ${INSTANCE_B_NAMESPACE}" \
        "$KUBECTL" auth can-i "$verb" "$kind" -n "$INSTANCE_B_NAMESPACE" --as="$sa_b" --quiet
      check_absent "${sa_a} CANNOT ${verb} ${kind} in peer ns ${INSTANCE_B_NAMESPACE}" \
        "$KUBECTL" auth can-i "$verb" "$kind" -n "$INSTANCE_B_NAMESPACE" --as="$sa_a" --quiet
      check_absent "${sa_b} CANNOT ${verb} ${kind} in peer ns ${INSTANCE_A_NAMESPACE}" \
        "$KUBECTL" auth can-i "$verb" "$kind" -n "$INSTANCE_A_NAMESPACE" --as="$sa_b" --quiet
    done
  done

  echo
  echo "--- 5. Configuration isolation through Kubernetes API ---"
  apply_zone_and_rrset "$INSTANCE_A_NAMESPACE" multi-a.example.com a.multi-a.example.com 192.0.2.10
  apply_zone_and_rrset "$INSTANCE_B_NAMESPACE" multi-b.example.com b.multi-b.example.com 192.0.2.20
  check "Instance A RRset reconciled" \
    wait_for_rrset_succeeded a.multi-a.example.com "$INSTANCE_A_NAMESPACE" a.multi-a.example.com.
  check "Instance B RRset reconciled" \
    wait_for_rrset_succeeded b.multi-b.example.com "$INSTANCE_B_NAMESPACE" b.multi-b.example.com.
  check_absent "Instance A Zone absent from instance B namespace" \
    "$KUBECTL" get zone multi-a.example.com -n "$INSTANCE_B_NAMESPACE"
  check_absent "Instance B Zone absent from instance A namespace" \
    "$KUBECTL" get zone multi-b.example.com -n "$INSTANCE_A_NAMESPACE"

  echo
  echo "--- 6. Runtime isolation through PowerDNS Auth API ---"
  STEP6_FAILURES_BEFORE="$FAIL"
  check_probe_present "Instance A Auth serves only A zone" \
    auth_has_zone "$INSTANCE_A_NAMESPACE" multi-a.example.com "$PDNS_API_KEY_A"
  check_probe_absent "Instance A Auth does not serve instance B zone" \
    auth_has_zone "$INSTANCE_A_NAMESPACE" multi-b.example.com "$PDNS_API_KEY_A"
  check_probe_present "Instance B Auth serves only B zone" \
    auth_has_zone "$INSTANCE_B_NAMESPACE" multi-b.example.com "$PDNS_API_KEY_B"
  check_probe_absent "Instance B Auth does not serve instance A zone" \
    auth_has_zone "$INSTANCE_B_NAMESPACE" multi-a.example.com "$PDNS_API_KEY_B"

  if [[ "$FAIL" -gt "$STEP6_FAILURES_BEFORE" ]]; then
    echo
    dump_step6_diagnostics
  fi

  echo
  echo "--- 7. Lifecycle isolation ---"
  if [[ "$RUN_LIFECYCLE" == "true" ]]; then
    delete_instance "$INSTANCE_A_NAME"
    check "Instance B remains available after deleting instance A" \
      wait_deployment_available "$INSTANCE_B_NAMESPACE" dnsdist
  else
    echo "  INFO  Lifecycle deletion skipped"
  fi
fi

if [[ "$CLEANUP" == "true" ]]; then
  echo
  echo "--- Cleanup ---"
  cleanup_validation_records
  delete_instance "$INSTANCE_A_NAME" || true
  delete_instance "$INSTANCE_B_NAME" || true
  if [[ "$STACK_READY_FAILED" == "true" ]]; then
    delete_instance_finalizer_if_stuck "$INSTANCE_A_NAME"
    delete_instance_finalizer_if_stuck "$INSTANCE_B_NAME"
  fi
  "$KUBECTL" delete namespace "$INSTANCE_A_NAMESPACE" --ignore-not-found --wait=false --timeout=30s >/dev/null 2>&1 || true
  "$KUBECTL" delete namespace "$INSTANCE_B_NAMESPACE" --ignore-not-found --wait=false --timeout=30s >/dev/null 2>&1 || true
  # Note: do NOT force_drain_stale_namespace here. The non-blocking delete
  # above lets KRO cascade-delete in the background while the CI job exits.
  # Any leftovers will be picked up by the pre-flight drain on the next run.
  echo "  Done."
fi

echo
echo "=== Results: ${PASS} passed, ${WARN} warned, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
