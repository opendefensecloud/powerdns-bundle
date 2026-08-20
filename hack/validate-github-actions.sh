#!/usr/bin/env bash
# Validates that workflow actions are pinned and limited to approved OSS actions.

set -euo pipefail

if [[ "$#" -gt 0 ]]; then
  SCAN_DIRS=("$@")
else
  SCAN_DIRS=(".github/workflows" ".github/actions")
fi

EXISTING_DIRS=()
for dir in "${SCAN_DIRS[@]}"; do
  [[ -d "$dir" ]] && EXISTING_DIRS+=("$dir")
done

if [[ "${#EXISTING_DIRS[@]}" -eq 0 ]]; then
  echo "No workflow or action directories found in: ${SCAN_DIRS[*]}; skipping."
  exit 0
fi

ALLOWED_ACTIONS=(
  "actions/checkout"
  "actions/upload-artifact"
  "actions/download-artifact"
  "aws-actions/configure-aws-credentials"
  "aquasecurity/trivy-action"
  "github/codeql-action/upload-sarif"
  "open-component-model/ocm-setup-action"
)

is_allowed() {
  local action="$1"
  local allowed
  for allowed in "${ALLOWED_ACTIONS[@]}"; do
    [[ "$action" == "$allowed" ]] && return 0
  done
  return 1
}

result=0

while IFS= read -r match; do
  file="${match%%:*}"
  rest="${match#*:}"
  line="${rest%%:*}"
  text="${rest#*:}"

  spec="$(printf '%s\n' "$text" | sed -E 's/.*uses:[[:space:]]*([^[:space:]#]+).*/\1/')"

  if [[ "$spec" == ./* ]]; then
    continue
  fi

  if [[ "$spec" != *@* ]]; then
    echo "ERROR: $file:$line uses '$spec' without a pinned ref." >&2
    result=1
    continue
  fi

  action="${spec%@*}"
  ref="${spec##*@}"

  if ! is_allowed "$action"; then
    echo "ERROR: $file:$line uses '$action', which is not in the approved OSS action allowlist." >&2
    result=1
  fi

  if [[ ! "$ref" =~ ^[0-9a-f]{40}$ ]]; then
    echo "ERROR: $file:$line uses '$action' with ref '$ref'; pin actions to a full commit SHA." >&2
    result=1
  fi
done < <(grep -RInE 'uses:[[:space:]]*[^[:space:]#]+' "${EXISTING_DIRS[@]}" || true)

if [[ "$result" -eq 0 ]]; then
  echo "GitHub Actions compliance check passed."
fi

exit "$result"
