#!/usr/bin/env bash
# Publish: apply the builder's patch to a clean checkout of the base commit, check protected paths
# on exactly what will be pushed, commit, push, and open the PR. Runs in the publish job: fresh
# checkouts, the push token, and no gate and no API key. Nothing from the build is trusted except
# the patch, and the patch is checked here.
set -euo pipefail
: "${PATCH:?}" "${BASE_SHA:?}" "${BRANCH:?}" "${BASE_BRANCH:?}" "${ISSUE_NUMBER:?}" "${ISSUE_TITLE:?}" \
  "${GH_TOKEN:?}" "${GH_REPO:?}" "${GITHUB_OUTPUT:?}"

if [ ! -s "$PATCH" ]; then
  echo "The builder made no changes; nothing to publish." >&2
  exit 1
fi

git switch -c "$BRANCH" "$BASE_SHA"
git apply --index "$PATCH"

# -z keeps odd file names intact; --no-renames lists both sides of a rename.
while IFS= read -r -d '' path; do
  case "$path" in
    .github/*|.claude/*|scripts/factory/*)
      echo "Protected path in the change, refusing to publish: $path" >&2
      exit 1
      ;;
  esac
done < <(git -c core.quotePath=false diff --cached --name-only -z --no-renames HEAD)

git -c user.name=factory-bot -c user.email=factory-bot@users.noreply.github.com \
  commit -q -m "Resolve #${ISSUE_NUMBER}: ${ISSUE_TITLE}"

gh auth setup-git
git push -u origin "$BRANCH"

gh pr create --base "$BASE_BRANCH" --head "$BRANCH" \
  --title "Resolve #${ISSUE_NUMBER}: ${ISSUE_TITLE}" \
  --body "Closes #${ISSUE_NUMBER}

Gate passed. Needs human review and merge."

pr_number="$(gh pr view "$BRANCH" --json number --jq .number)"
{
  echo "pr=$pr_number"
  echo "branch=$BRANCH"
} >> "$GITHUB_OUTPUT"
