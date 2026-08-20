#!/usr/bin/env bash
# Validates that the workload NetworkPolicies actually enforce isolation.
#
# The deploy/upgrade smoke suites already prove every *allowed* flow end to end
# (DNS resolves through the frontend, the operator reconciles via the API, and
# Prometheus scrapes every target). This script proves the *denied* flows: a pod
# that is not in an allow-list cannot reach a protected port.
#
# Two layers are tested independently, each with its own positive control so a
# failure is never silently attributed to the wrong layer:
#
#   1. Egress containment — a test client with no egress allow cannot reach the
#      authoritative API, while cluster DNS (the shared kube-dns allow) still
#      works, proving the client is up and the default-deny is the only blocker.
#   2. Ingress segmentation — after granting the test client egress to the
#      authoritative API and recursor metrics, those connections are STILL
#      refused (the targets' ingress rules exclude it), while a connection to the
#      public frontend succeeds, proving egress now works and the block is ingress.
#
# The test client is a Deployment (not a bare pod): the VPC CNI only enforces
# policy on pods owned by a Deployment, so a bare pod would falsely pass.
#
# Usage: NAMESPACE=dns ./hack/validate-network-policies.sh [--cleanup]
#   --cleanup is accepted for interface parity; test artifacts are always removed.
set -euo pipefail

NAMESPACE="${NAMESPACE:-dns}"
KUBECTL="${KUBECTL_BIN:-kubectl}"
# Reuse an image already pinned by the bundle; alpine's BusyBox provides nc and
# nslookup, which is all the test client needs.
TEST_IMAGE="${TEST_IMAGE:-alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc}"
TEST_APP="netpol-validator"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-3}"
DENY_POLLS="${DENY_POLLS:-3}"
OPEN_TIMEOUT="${OPEN_TIMEOUT:-30}"

PASS=0
FAIL=0

cleanup() {
  "$KUBECTL" delete networkpolicy "${TEST_APP}-egress" -n "$NAMESPACE" \
    --ignore-not-found --wait=false &>/dev/null || true
  "$KUBECTL" delete deployment "$TEST_APP" -n "$NAMESPACE" \
    --ignore-not-found --wait=false &>/dev/null || true
}
trap cleanup EXIT

require() {
  if ! command -v "$1" &>/dev/null; then
    echo "ERROR: '$1' is required but not installed." >&2
    exit 1
  fi
}

pass() { echo "  PASS  $1"; ((PASS++)) || true; }
fail() { echo "  FAIL  $1"; ((FAIL++)) || true; }

pod_ip() {
  "$KUBECTL" get pod -n "$NAMESPACE" -l "app.kubernetes.io/name=$1" \
    -o jsonpath='{.items[0].status.podIP}' 2>/dev/null
}

client_pod() {
  "$KUBECTL" get pod -n "$NAMESPACE" -l "app.kubernetes.io/name=${TEST_APP}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# Returns 0 if a TCP connection to host:port can be established from the test
# client, non-zero otherwise (refused or silently dropped by a policy). The
# BusyBox `timeout` hard-bounds the attempt so a policy-dropped SYN cannot hang
# on the kernel TCP connect timeout.
tcp_from_client() {
  local host="$1" port="$2" pod
  pod="$(client_pod)"
  "$KUBECTL" exec -n "$NAMESPACE" "$pod" -- \
    timeout "$CONNECT_TIMEOUT" nc -w "$CONNECT_TIMEOUT" "$host" "$port" </dev/null &>/dev/null
}

# Asserts host:port is reachable from the client within OPEN_TIMEOUT (a positive
# control that tolerates VPC CNI policy-reconcile lag at pod/policy startup).
assert_open() {
  local host="$1" port="$2" desc="$3" i
  for ((i = 0; i < OPEN_TIMEOUT; i++)); do
    if tcp_from_client "$host" "$port"; then
      pass "$desc"
      return
    fi
    sleep 1
  done
  fail "$desc (never became reachable)"
}

# Asserts host:port is denied. First waits (up to OPEN_TIMEOUT) for the block to
# take effect, so a not-yet-reconciled allow policy on a fresh pod is not mistaken
# for a permissive target; then requires the denial to hold across DENY_POLLS
# consecutive checks, so a single transient drop is not mistaken for enforcement.
assert_blocked() {
  local host="$1" port="$2" desc="$3" i
  for ((i = 0; i < OPEN_TIMEOUT; i++)); do
    tcp_from_client "$host" "$port" || break
    sleep 1
  done
  for ((i = 0; i < DENY_POLLS; i++)); do
    if tcp_from_client "$host" "$port"; then
      fail "$desc (connection unexpectedly succeeded)"
      return
    fi
  done
  pass "$desc"
}

require "$KUBECTL"

echo "=== Network Policy Validation ==="
echo "  Namespace: ${NAMESPACE}"

echo
echo "--- Policy objects present ---"
for np in default-deny allow-egress-kube-dns dnsdist recursor auth operator; do
  if "$KUBECTL" get networkpolicy "$np" -n "$NAMESPACE" &>/dev/null; then
    pass "NetworkPolicy/${np} exists"
  else
    fail "NetworkPolicy/${np} exists"
  fi
done

echo
echo "--- Test client ---"
"$KUBECTL" apply -n "$NAMESPACE" -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${TEST_APP}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${TEST_APP}
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: ${TEST_APP}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${TEST_APP}
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: client
          image: ${TEST_IMAGE}
          command: ["sleep", "3600"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              cpu: 100m
              memory: 32Mi
EOF

if "$KUBECTL" rollout status deployment/"$TEST_APP" -n "$NAMESPACE" \
  --timeout=120s >/dev/null; then
  pass "test client is running"
else
  fail "test client is running"
  echo
  echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
  exit 1
fi

AUTH_IP="$(pod_ip pdns-auth)"
RECURSOR_IP="$(pod_ip pdns-recursor)"
DNSDIST_IP="$(pod_ip dnsdist)"

if [[ -z "$AUTH_IP" || -z "$RECURSOR_IP" || -z "$DNSDIST_IP" ]]; then
  fail "resolved workload pod IPs (auth=${AUTH_IP:-?} recursor=${RECURSOR_IP:-?} dnsdist=${DNSDIST_IP:-?})"
  echo
  echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
  exit 1
fi

echo
echo "--- Layer 1: egress containment (no egress allow) ---"
# Positive control: cluster DNS works (shared kube-dns egress), proving the pod
# is up and policy enforcement permits exactly what it should.
CLIENT_POD="$(client_pod)"
if "$KUBECTL" exec -n "$NAMESPACE" "$CLIENT_POD" -- \
  nslookup kubernetes.default.svc.cluster.local &>/dev/null; then
  pass "cluster DNS resolves (shared kube-dns egress allowed)"
else
  fail "cluster DNS resolves (shared kube-dns egress allowed)"
fi
assert_blocked "$AUTH_IP" 8081 "authoritative API blocked by egress default-deny"

echo
echo "--- Layer 2: ingress segmentation (egress to targets granted) ---"
"$KUBECTL" apply -n "$NAMESPACE" -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${TEST_APP}-egress
  namespace: ${NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: ${TEST_APP}
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: dnsdist
      ports:
        - protocol: TCP
          port: 53
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: pdns-auth
      ports:
        - protocol: TCP
          port: 8081
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: pdns-recursor
      ports:
        - protocol: TCP
          port: 8082
EOF

# Positive control: with egress now granted, the public frontend (which accepts
# ingress from any source) is reachable — proving the egress grant is active, so
# the assertions below isolate the targets' ingress rules.
assert_open "$DNSDIST_IP" 53 "frontend reachable (egress grant active)"
assert_blocked "$AUTH_IP" 8081 "authoritative API blocked by its ingress rules"
assert_blocked "$RECURSOR_IP" 8082 "recursor metrics blocked by its ingress rules"

echo
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
