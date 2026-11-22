#!/usr/bin/env bash
# Push the factory branch and open its PR. Runs with the push token only (GH_TOKEN).
set -euo pipefail
: "${BRANCH:?}" "${ISSUE_NUMBER:?}" "${ISSUE_TITLE:?}" "${GH_TOKEN:?}" "${GH_REPO:?}" "${GITHUB_OUTPUT:?}" "${BASE_BRANCH:?}"

gh auth setup-git
git push -u origin "$BRANCH"

gh pr create --base "$BASE_BRANCH" --head "$BRANCH" \
  --title "Resolve #${ISSUE_NUMBER}: ${ISSUE_TITLE}" \
  --body "Closes #${ISSUE_NUMBER}

Gate passed. Needs human review and merge."

pr_number="$(gh pr view "$BRANCH" --json number --jq .number)"
echo "pr=$pr_number" >> "$GITHUB_OUTPUT"
