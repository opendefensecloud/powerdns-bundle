#!/usr/bin/env bash
# Verifies the LMDB map-size coupling between the PowerDNS Authoritative
# process (`lmdb-map-size`) and the Lightning Stream sidecar (`map_size`).
# Both processes open the same LMDB environment and MUST agree on this value
# (see docs/ARCHITECTURE.md "LMDB storage"); a mismatch causes one process to
# refuse to start, or silently desynchronizes the map on the next resize.
#
# Static base manifests (deploy/base/authoritative/) hardcode the value
# independently in two ConfigMaps with no shared variable, so this script
# cross-checks them numerically on every run. KRO deployments derive all
# occurrences from the single `lmdbMapSizeMB` schema field instead; this
# script also asserts the RGD template has no stray hardcoded duplicate.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

AUTH_CONFIGMAP="deploy/base/authoritative/configmap.yaml"
LS_CONFIGMAP="deploy/base/authoritative/configmap-lightningstream.yaml"
AUTH_PVC="deploy/base/authoritative/pvc.yaml"
AUTH_DEPLOYMENT="deploy/base/authoritative/deployment.yaml"
KRO_RGD="deploy/kro/powerdns-instance-rgd.yaml"

ok() {
  echo "  PASS  $1"
  ((PASS++)) || true
}

bad() {
  echo "  FAIL  $1"
  ((FAIL++)) || true
}

extract_numbers() {
  # Extracts all numeric values for a given key pattern from a file.
  local pattern="$1"
  local file="$2"
  grep -Eo -- "$pattern" "${ROOT_DIR}/${file}" 2>/dev/null \
    | grep -Eo '[0-9]+' || true
}

count_values() {
  local values="$1"
  printf '%s\n' "$values" | grep -c . || true
}

echo "=== LMDB map-size configuration validation ==="
echo

echo "--- Static base manifests (${AUTH_CONFIGMAP}, ${LS_CONFIGMAP}) ---"

auth_values="$(extract_numbers 'lmdb-map-size=[0-9]+' "$AUTH_CONFIGMAP")"
ls_values="$(extract_numbers 'map_size: [0-9]+MB' "$LS_CONFIGMAP")"
auth_value_count="$(count_values "$auth_values")"
ls_value_count="$(count_values "$ls_values")"

if [[ "$auth_value_count" -eq 1 ]]; then
  auth_value="$auth_values"
  ok "one lmdb-map-size found in ${AUTH_CONFIGMAP} (${auth_value})"
else
  auth_value=""
  bad "expected 1 lmdb-map-size in ${AUTH_CONFIGMAP}, found ${auth_value_count}"
fi

if [[ "$ls_value_count" -eq 2 ]]; then
  ok "both main and shard map_size found in ${LS_CONFIGMAP}"
else
  bad "expected 2 map_size entries in ${LS_CONFIGMAP}, found ${ls_value_count}"
fi

all_static_values="$(printf '%s\n%s\n' "$auth_values" "$ls_values" | grep -c . || true)"
unique_static_values="$(printf '%s\n%s\n' "$auth_values" "$ls_values" | sort -u | grep -c . || true)"
if [[ "$unique_static_values" -eq 1 && "$all_static_values" -eq 3 && -n "$auth_value" ]]; then
  ok "lmdb-map-size and both map_size values agree (${auth_value})"
else
  bad "lmdb-map-size/map_size values disagree - auth=${auth_values:-missing}, lightningstream=$(printf '%s' "$ls_values" | tr '\n' ',')"
fi

if [[ -n "$auth_value" ]]; then
  # Both the PVC size and the rollout revision are functions of the map size,
  # so derive the expectations rather than hardcoding them here: raising the
  # static default then fails with an actionable message instead of a
  # mismatch against a stale literal.
  expected_pvc_mib=$((auth_value * 4))
  expected_revision="ls-v2-map-${auth_value}"
  expected_ls_memory_mib=$((auth_value / 2))
else
  expected_pvc_mib=""
  expected_revision=""
  expected_ls_memory_mib=""
fi

static_pvc="$(extract_numbers '^[[:space:]]+storage: [0-9]+(Gi|Mi)$' "$AUTH_PVC")"
static_pvc_unit="$(grep -Eo -- '^[[:space:]]+storage: [0-9]+(Gi|Mi)$' "${ROOT_DIR}/${AUTH_PVC}" | grep -Eo '(Gi|Mi)$' || true)"
if [[ "$static_pvc_unit" == "Gi" ]]; then
  static_pvc_mib=$((static_pvc * 1024))
else
  static_pvc_mib="$static_pvc"
fi
if [[ -n "$expected_pvc_mib" && "${static_pvc_mib:-0}" -ge "$expected_pvc_mib" ]]; then
  ok "static Auth PVC (${static_pvc}${static_pvc_unit}) covers the 4x sizing policy for ${auth_value} MB"
else
  bad "static Auth PVC must request at least ${expected_pvc_mib:-?}Mi for a ${auth_value:-?} MB map, found ${static_pvc:-none}${static_pvc_unit}"
fi

if [[ -n "$expected_revision" ]] \
  && grep -Fq -- "powerdns.cav.enablers.ob/lmdb-config-revision: \"${expected_revision}\"" "${ROOT_DIR}/${AUTH_DEPLOYMENT}"; then
  ok "static Auth deployment reloads the current LMDB config revision (${expected_revision})"
else
  bad "static Auth deployment must carry lmdb-config-revision \"${expected_revision:-?}\""
fi

if [[ -n "$expected_ls_memory_mib" ]] \
  && grep -Fq -- "memory: ${expected_ls_memory_mib}Mi" "${ROOT_DIR}/${AUTH_DEPLOYMENT}"; then
  ok "static Lightning Stream memory limit scales with the map size (${expected_ls_memory_mib}Mi)"
else
  bad "static Lightning Stream memory limit must be ${expected_ls_memory_mib:-?}Mi for a ${auth_value:-?} MB map"
fi

echo
echo "--- KRO ResourceGraphDefinition (${KRO_RGD}) ---"

kro_default="$(
  grep -Eo -- '^[[:space:]]*lmdbMapSizeMB: integer \| default=[0-9]+ minimum=[0-9]+' \
    "${ROOT_DIR}/${KRO_RGD}" 2>/dev/null \
    | grep -Eo 'default=[0-9]+' \
    | grep -Eo '[0-9]+' || true
)"
if [[ "$(count_values "$kro_default")" -eq 1 ]]; then
  ok "lmdbMapSizeMB schema field is declared (default ${kro_default} MB)"
else
  bad "expected one constrained lmdbMapSizeMB schema field"
fi

if grep -Eq -- '^[[:space:]]*lmdbMapSizeMB: integer \| default=[0-9]+ minimum=256$' "${ROOT_DIR}/${KRO_RGD}"; then
  ok "lmdbMapSizeMB rejects unrealistically small values"
else
  bad "lmdbMapSizeMB must enforce a 256 MB minimum"
fi

if [[ -n "$auth_value" && "$kro_default" == "$auth_value" ]]; then
  ok "KRO and static manifests share the same default map size (${auth_value} MB)"
else
  bad "KRO/static defaults disagree - kro=${kro_default:-missing}, static=${auth_value:-missing}"
fi

auth_template_refs="$(grep -Fc -- 'lmdb-map-size=${string(schema.spec.lmdbMapSizeMB)}' "${ROOT_DIR}/${KRO_RGD}" || true)"
ls_template_refs="$(grep -Fc -- 'map_size: ${string(schema.spec.lmdbMapSizeMB)}MB' "${ROOT_DIR}/${KRO_RGD}" || true)"
if [[ "$auth_template_refs" -eq 1 && "$ls_template_refs" -eq 4 ]]; then
  ok "all Auth and Lightning Stream map-size values reference the schema field"
else
  bad "expected 1 Auth and 4 Lightning Stream references, found ${auth_template_refs} and ${ls_template_refs}"
fi

# Any hardcoded `lmdb-map-size=<number>` or `map_size: <number>MB` left in the
# RGD (outside the schema default itself) would silently bypass the shared
# field — fail if one is found.
stray_matches="$(grep -Ec -- 'lmdb-map-size=[0-9]+|map_size: [0-9]+MB' "${ROOT_DIR}/${KRO_RGD}" || true)"
if [[ "$stray_matches" -eq 0 ]]; then
  ok "no stray hardcoded lmdb-map-size/map_size values in the RGD"
else
  bad "found ${stray_matches} stray hardcoded lmdb-map-size/map_size value(s) in the RGD"
fi

if grep -Fq -- 'storage: "${string(schema.spec.lmdbMapSizeMB * 4)}Mi"' "${ROOT_DIR}/${KRO_RGD}"; then
  ok "KRO Auth PVC capacity is derived from lmdbMapSizeMB"
else
  bad "KRO Auth PVC capacity is not derived from lmdbMapSizeMB"
fi

if grep -Fq -- 'powerdns.cav.enablers.ob/lmdb-config-revision: "ls-v2-map-${string(schema.spec.lmdbMapSizeMB)}"' "${ROOT_DIR}/${KRO_RGD}"; then
  ok "KRO Auth rollout revision tracks lmdbMapSizeMB"
else
  bad "KRO Auth rollout revision does not track lmdbMapSizeMB"
fi

if grep -Fq -- 'memory: "${string(schema.spec.lmdbMapSizeMB / 2)}Mi"' "${ROOT_DIR}/${KRO_RGD}"; then
  ok "KRO Lightning Stream memory limit is derived from lmdbMapSizeMB"
else
  bad "KRO Lightning Stream memory limit is not derived from lmdbMapSizeMB"
fi

if grep -Fq -- 'capacity:${string(schema.spec.lmdbMapSizeMB * 4000000)},' "${ROOT_DIR}/${KRO_RGD}"; then
  ok "Garage layout capacity is derived from lmdbMapSizeMB"
else
  bad "Garage layout capacity is not derived from lmdbMapSizeMB"
fi

if grep -Fq -- 'current_capacity" != "$DESIRED_CAPACITY' "${ROOT_DIR}/${KRO_RGD}" \
  && grep -Fq -- 'next_layout_version=$((layout_version + 1))' "${ROOT_DIR}/${KRO_RGD}"; then
  ok "Garage bootstrap reconciles capacity changes"
else
  bad "Garage bootstrap does not reconcile capacity changes"
fi

cleanup_blocks="$(
  grep -Eh -- '^[[:space:]]+cleanup:$' \
    "${ROOT_DIR}/${LS_CONFIGMAP}" "${ROOT_DIR}/${KRO_RGD}" \
    | grep -c . || true
)"
cleanup_enabled="$(
  grep -Eh -- '^[[:space:]]+enabled: true$' \
    "${ROOT_DIR}/${LS_CONFIGMAP}" "${ROOT_DIR}/${KRO_RGD}" \
    | grep -c . || true
)"
cleanup_intervals="$(
  grep -Eh -- '^[[:space:]]+interval: 5m$' \
    "${ROOT_DIR}/${LS_CONFIGMAP}" "${ROOT_DIR}/${KRO_RGD}" \
    | grep -c . || true
)"
cleanup_retention="$(
  grep -Eh -- '^[[:space:]]+must_keep_interval: 10m$|^[[:space:]]+remove_old_instances_interval: 168h$' \
    "${ROOT_DIR}/${LS_CONFIGMAP}" "${ROOT_DIR}/${KRO_RGD}" \
    | grep -c . || true
)"
if [[ "$cleanup_blocks" -eq 3 && "$cleanup_enabled" -eq 3 && "$cleanup_intervals" -eq 3 && "$cleanup_retention" -eq 6 ]]; then
  ok "snapshot cleanup is enabled with bounded retention in all 3 storage configurations"
else
  bad "snapshot cleanup contract incomplete (blocks=${cleanup_blocks}, enabled=${cleanup_enabled}, intervals=${cleanup_intervals}, retention-settings=${cleanup_retention})"
fi

echo
echo "--- Lightning Stream sidecar contract ---"

# Lightning Stream keeps snapshot buffers in memory per LMDB, and this bundle
# configures two (main + shard). Without explicit bounds the upstream defaults
# dominate the sidecar's memory profile and can OOMKill it at larger map sizes,
# which silently stops replication.
ls_http="$(
  grep -Eh -- '^[[:space:]]+address: ":8500"$' \
    "${ROOT_DIR}/${LS_CONFIGMAP}" "${ROOT_DIR}/${KRO_RGD}" | grep -c . || true
)"
ls_buffers="$(
  grep -Eh -- '^[[:space:]]+memory_downloaded_snapshots: 2$|^[[:space:]]+memory_decompressed_snapshots: 1$' \
    "${ROOT_DIR}/${LS_CONFIGMAP}" "${ROOT_DIR}/${KRO_RGD}" | grep -c . || true
)"
if [[ "$ls_http" -eq 3 ]]; then
  ok "Lightning Stream exposes metrics/healthz in all 3 storage configurations"
else
  bad "expected 3 Lightning Stream http.address entries, found ${ls_http}"
fi
if [[ "$ls_buffers" -eq 6 ]]; then
  ok "Lightning Stream snapshot memory buffers are bounded in all 3 storage configurations"
else
  bad "expected 6 snapshot buffer settings across the Lightning Stream configs, found ${ls_buffers}"
fi

ls_ports="$(
  grep -Eh -- '^[[:space:]]+containerPort: 8500$' \
    "${ROOT_DIR}/${AUTH_DEPLOYMENT}" "${ROOT_DIR}/${KRO_RGD}" | grep -c . || true
)"
ls_probes="$(
  grep -Eh -- '^[[:space:]]+port: ls-metrics$' \
    "${ROOT_DIR}/${AUTH_DEPLOYMENT}" "${ROOT_DIR}/${KRO_RGD}" | grep -c . || true
)"
if [[ "$ls_ports" -eq 2 ]]; then
  ok "both Auth deployments declare the Lightning Stream metrics port"
else
  bad "expected 2 Lightning Stream containerPort declarations, found ${ls_ports}"
fi
# Two probes per deployment plus the Service targetPort in the RGD.
if [[ "$ls_probes" -ge 4 ]]; then
  ok "Lightning Stream liveness and readiness probes are wired to the metrics port"
else
  bad "expected at least 4 ls-metrics port references for probes, found ${ls_probes}"
fi

# A pod-name-derived instance mints a new Lightning Stream identity on every
# restart, orphaning the previous instance's final snapshot until
# remove_old_instances_interval elapses.
stable_instances="$(
  grep -Eh -- '^[[:space:]]+- pdns-auth-\$\(POD_NAMESPACE\)$' \
    "${ROOT_DIR}/${AUTH_DEPLOYMENT}" "${ROOT_DIR}/${KRO_RGD}" | grep -c . || true
)"
podname_instances="$(
  grep -Eh -- '^[[:space:]]+- \$\(POD_NAME\)$' \
    "${ROOT_DIR}/${AUTH_DEPLOYMENT}" "${ROOT_DIR}/${KRO_RGD}" | grep -c . || true
)"
if [[ "$stable_instances" -eq 2 && "$podname_instances" -eq 0 ]]; then
  ok "Lightning Stream uses a stable instance name in both Auth deployments"
else
  bad "Lightning Stream instance name must be stable (stable=${stable_instances}, pod-name-derived=${podname_instances})"
fi

echo
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
