#!/usr/bin/env bash
# Configures branch protection and required reviews for the default branch.
#
# This encodes the repository's merge policy as code so it is reviewable,
# auditable, and reproducible in another GitHub environment. Run it with the
# GitHub CLI (gh) authenticated as a user with admin rights on the repository.
#
# Usage:
#   REPO=owner/name BRANCH=main APPROVALS=1 ./hack/setup-branch-protection.sh
#
# Defaults: REPO is taken from the current checkout, BRANCH=main, APPROVALS=1.
set -euo pipefail

REPO="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
BRANCH="${BRANCH:-main}"
APPROVALS="${APPROVALS:-1}"

# Stable, single (non-matrix) status checks that must pass before merge. The CVE
# and SBOM jobs run as an image matrix with per-image names, so they are gated
# through the aggregating "3e. CVE scan gate" job (a single stable context) rather
# than required directly. The deployment smoke tests are conditional on a
# configured test cluster, so they are reported but not required as merge gates.
REQUIRED_CHECKS=(
  "1. Quality checks"
  "2. Build OCM package"
  "3c. Config security scan"
  "3e. CVE scan gate"
)

contexts_json=""
for check in "${REQUIRED_CHECKS[@]}"; do
  contexts_json+="\"${check}\","
done
contexts_json="[${contexts_json%,}]"

payload=$(cat <<EOF
{
  "required_status_checks": {
    "strict": false,
    "contexts": ${contexts_json}
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": ${APPROVALS},
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false
  },
  "required_conversation_resolution": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "restrictions": null
}
EOF
)

echo "Applying branch protection to ${REPO}@${BRANCH} (approvals: ${APPROVALS})…"
printf '%s' "$payload" | gh api -X PUT \
  -H "Accept: application/vnd.github+json" \
  "repos/${REPO}/branches/${BRANCH}/protection" \
  --input - >/dev/null

echo "Applied. Effective policy:"
gh api "repos/${REPO}/branches/${BRANCH}/protection" --jq '{
  required_checks: .required_status_checks.contexts,
  strict: .required_status_checks.strict,
  approvals: .required_pull_request_reviews.required_approving_review_count,
  dismiss_stale: .required_pull_request_reviews.dismiss_stale_reviews,
  enforce_admins: .enforce_admins.enabled,
  conversation_resolution: .required_conversation_resolution.enabled,
  force_pushes: .allow_force_pushes.enabled,
  deletions: .allow_deletions.enabled
}'
