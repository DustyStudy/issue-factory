#!/usr/bin/env bash
# Builder: implement one issue on a fresh branch in the target repo, run the target's gate,
# retry once on failure, and commit if the gate passes. Never pushes.
# Writes ready, branch and reason to $GITHUB_OUTPUT. Runs from the target repo root.
set -euo pipefail
: "${FACTORY_DIR:?}" "${GATE_PATH:?}" "${ISSUE_NUMBER:?}" "${ISSUE_TITLE:?}" "${GITHUB_OUTPUT:?}"
cd "$(git rev-parse --show-toplevel)"

# The factory's own checkout sits inside the target workspace as a nested repo. Keep it out of
# `git add -A`, or it is committed as an embedded repo (gitlink) and breaks the PR.
printf '/factory/\n' >> "$(git rev-parse --git-path info/exclude)"

# Unique per run, so a retry never collides with a branch a failed run left behind.
branch="factory/issue-${ISSUE_NUMBER}-${GITHUB_RUN_ID:-local}"
work="$(mktemp -d)"
git switch -c "$branch"

ready=false
gate_log=""
for attempt in 1 2; do
  {
    printf '=== ISSUE ===\n%s\n\n' "$ISSUE_TITLE"
    printf '%s' "${ISSUE_BODY:-}" | head -c 8000
    printf '\n\n=== GATE ===\n%s\n' "$GATE_PATH"
    if [ -n "$gate_log" ]; then
      printf '\n=== GATE LOG ===\n%s\n' "$gate_log"
    fi
  } > "$work/in.txt"

  # Start on Sonnet 5.5. Escalate to Opus 5.5 only for the retry, after a gate failure.
  # Effort medium: tune it before switching models.
  model="claude-sonnet-5-5"
  if [ "$attempt" -gt 1 ]; then
    model="${BUILDER_RETRY_MODEL:-claude-opus-5-5}"
  fi

  # Fresh context each attempt. The builder gets no GitHub token and cannot run git, gh or curl.
  env -u GH_TOKEN -u GITHUB_TOKEN claude -p "$(cat "$FACTORY_DIR/prompts/builder.md")" \
    --model "$model" --effort medium --max-turns 25 \
    --max-budget-usd "${BUILDER_BUDGET:-2}" \
    --permission-mode dontAsk \
    --settings "$FACTORY_DIR/builder-settings.json" \
    --allowedTools "Read,Edit,Write,Glob,Grep,Bash(bash ${GATE_PATH}:*),Bash(python3 -m pytest:*),Bash(ruff:*)" \
    --output-format json < "$work/in.txt" > "$work/builder-$attempt.json" || true

  # Surface what the builder did, so a failed run can be diagnosed from the job log.
  echo "::group::builder attempt $attempt ($model)"
  jq -c '{is_error, subtype, num_turns, total_cost_usd, errors, permission_denials, result: ((.result // "") | .[0:800])}' \
    "$work/builder-$attempt.json" 2>/dev/null || cat "$work/builder-$attempt.json" 2>/dev/null | head -c 2000 || true
  echo "::endgroup::"

  if bash "$GATE_PATH" > "$work/gate.log" 2>&1; then
    ready=true
    break
  fi
  echo "::group::gate attempt $attempt output"
  tail -c 4000 "$work/gate.log" || true
  echo "::endgroup::"
  gate_log="$(tail -c 6000 "$work/gate.log")"
done

if [ "$ready" != true ]; then
  {
    echo "ready=false"
    echo "reason=gate-failed"
  } >> "$GITHUB_OUTPUT"
  exit 0
fi

changed="$(git status --porcelain)"
if [ -z "$changed" ]; then
  {
    echo "ready=false"
    echo "reason=no-changes"
  } >> "$GITHUB_OUTPUT"
  exit 0
fi

# The builder settings already deny these paths. Check again before commit.
if printf '%s\n' "$changed" | grep -qE '^.. (\.github/|\.claude/|scripts/factory/)'; then
  {
    echo "ready=false"
    echo "reason=protected-path"
  } >> "$GITHUB_OUTPUT"
  exit 0
fi

git add -A
git -c user.name=factory-bot -c user.email=factory-bot@users.noreply.github.com \
  commit -q -m "Resolve #${ISSUE_NUMBER}: ${ISSUE_TITLE}"

{
  echo "ready=true"
  echo "branch=$branch"
} >> "$GITHUB_OUTPUT"
