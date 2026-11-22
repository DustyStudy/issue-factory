#!/usr/bin/env bash
# Review: one read-only pass over the PR diff. Posts the verdict on the PR and labels it.
# PASS -> factory-ready (a human still merges). Anything else -> needs-human.
set -euo pipefail
: "${FACTORY_DIR:?}" "${ISSUE_NUMBER:?}" "${ISSUE_TITLE:?}" "${BRANCH:?}" "${GH_TOKEN:?}" "${GH_REPO:?}" "${BASE_BRANCH:?}"

# The PR is found from its branch. Fail loudly if it is missing, rather than commenting on nothing.
pr_number="$(gh pr view "$BRANCH" --json number --jq .number)"
if [ -z "$pr_number" ]; then
  echo "No PR found for branch $BRANCH; not reviewing." >&2
  exit 1
fi
echo "Reviewing PR #$pr_number"

# No fetch here: the checkout already has origin/$BASE_BRANCH, and the checkout does not keep
# credentials, so a fresh fetch fails with "could not read Username".
work="$(mktemp -d)"
issue_body="${ISSUE_BODY:-}"
# Write the diff to a file, then cut it. A pipe into `head` would kill git under pipefail on large diffs.
git diff "origin/${BASE_BRANCH}...HEAD" > "$work/diff.patch"
{
  printf '=== ISSUE ===\n%s\n\n' "$ISSUE_TITLE"
  printf '%s' "${issue_body:0:4000}"
  printf '\n=== DIFF ===\n'
  head -c 60000 "$work/diff.patch"
} > "$work/in.txt"

# No tools at all, so the model cannot read the runner's files or environment. The reviewer judges
# the diff it is given, and its summary goes to a public PR comment verbatim.
# A failed parse once gave NEEDS-HUMAN on a clean change, so try twice and log why each attempt failed.
verdict="NEEDS-HUMAN"
summary="Reviewer could not produce a verdict."
findings=""
for attempt in 1 2; do
  env -u GH_TOKEN claude -p "$(cat "$FACTORY_DIR/prompts/reviewer.md")" --bare \
    --model claude-haiku-5-5 --effort medium --tools "" \
    --max-turns 4 --max-budget-usd "${REVIEW_BUDGET:-0.5}" \
    --output-format json < "$work/in.txt" > "$work/out-$attempt.json" || true
  echo "::group::review attempt $attempt"
  jq -c '{is_error, subtype, num_turns, total_cost_usd, errors}' "$work/out-$attempt.json" 2>/dev/null || true
  echo "::endgroup::"
  if out="$(python3 "$FACTORY_DIR/scripts/json_field.py" "$work/out-$attempt.json")"; then
    verdict="$(jq -r '.verdict // ""' <<<"$out")"
    summary="$(jq -r '.summary // ""' <<<"$out")"
    findings="$(jq -r '.findings[]? | "- " + tostring' <<<"$out")"
    break
  fi
done

{
  echo "**Factory review: ${verdict}**"
  echo
  echo "$summary"
  if [ -n "$findings" ]; then
    echo
    echo "$findings"
  fi
} > "$work/comment.md"
gh pr comment "$pr_number" --body-file "$work/comment.md"

if [ "$verdict" = "PASS" ]; then
  gh pr edit "$pr_number" --add-label factory-ready
else
  gh pr edit "$pr_number" --add-label needs-human
fi
