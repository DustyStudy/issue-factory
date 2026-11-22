#!/usr/bin/env bash
# Review: one read-only pass over the PR diff. Posts the verdict on the PR and labels it.
# PASS -> factory-ready (a human still merges). Anything else -> needs-human.
set -euo pipefail
: "${FACTORY_DIR:?}" "${ISSUE_NUMBER:?}" "${ISSUE_TITLE:?}" "${PR_NUMBER:?}" "${GH_TOKEN:?}" "${GH_REPO:?}"

# No fetch here: the checkout already has origin/main, and the checkout does not keep
# credentials, so a fresh fetch fails with "could not read Username".
work="$(mktemp -d)"
issue_body="${ISSUE_BODY:-}"
# Write the diff to a file, then cut it. A pipe into `head` would kill git under pipefail on large diffs.
git diff origin/main...HEAD > "$work/diff.patch"
{
  printf '=== ISSUE ===\n%s\n\n' "$ISSUE_TITLE"
  printf '%s' "${issue_body:0:4000}"
  printf '\n=== DIFF ===\n'
  head -c 60000 "$work/diff.patch"
} > "$work/in.txt"

# Read-only tools, no Bash, no GitHub token in the model process.
env -u GH_TOKEN claude -p "$(cat "$FACTORY_DIR/prompts/reviewer.md")" --bare \
  --model claude-haiku-5-5 --effort medium --tools "Read,Grep,Glob" --permission-mode dontAsk \
  --max-turns 6 --max-budget-usd "${REVIEW_BUDGET:-0.5}" \
  --output-format json < "$work/in.txt" > "$work/out.json" || true

verdict="NEEDS-HUMAN"
summary="Reviewer could not produce a verdict."
findings=""
if out="$(python3 "$FACTORY_DIR/scripts/json_field.py" "$work/out.json")"; then
  verdict="$(jq -r '.verdict // ""' <<<"$out")"
  summary="$(jq -r '.summary // ""' <<<"$out")"
  findings="$(jq -r '.findings[]? | "- " + tostring' <<<"$out")"
fi

{
  echo "**Factory review: ${verdict}**"
  echo
  echo "$summary"
  if [ -n "$findings" ]; then
    echo
    echo "$findings"
  fi
} > "$work/comment.md"
gh pr comment "$PR_NUMBER" --body-file "$work/comment.md"

if [ "$verdict" = "PASS" ]; then
  gh pr edit "$PR_NUMBER" --add-label factory-ready
else
  gh pr edit "$PR_NUMBER" --add-label needs-human
fi
