#!/usr/bin/env bash
# Builder steps. Each attempt runs on its own fresh runner, so the API key never shares a VM with
# the gate or with anything the gate wrote. Subcommands:
#   implement N   run the builder, attempt N. Holds ANTHROPIC_API_KEY. The builder has no shell
#                 except ruff, and no git, gh or curl.
#   diff N        write everything changed since BASE_SHA as a patch. No key, no token.
# Runs from the target repo root. The workspace is the base commit plus any earlier patch.
# Output: $RUNNER_TEMP/patch/patch.diff (diff) and $RUNNER_TEMP/builder-N.json (implement).
set -euo pipefail

cmd="${1:?usage: build.sh implement N | diff N}"
n="${2:?attempt number}"
: "${RUNNER_TEMP:?}"
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

implement() {
  local model="claude-sonnet-5-5" issue_body="${ISSUE_BODY:-}" input="$RUNNER_TEMP/in-$n.txt"
  : "${FACTORY_DIR:?}" "${GATE_PATH:?}" "${ISSUE_TITLE:?}"

  # Start on Sonnet 5.5. Escalate to Opus 5.5 only for the retry, after a gate failure.
  if [ "$n" -gt 1 ]; then
    model="${BUILDER_RETRY_MODEL:-claude-opus-5-5}"
  fi

  {
    printf '=== ISSUE ===\n%s\n\n' "$ISSUE_TITLE"
    # Slice, not `| head`: a pipe that closes early kills the writer under pipefail.
    printf '%s' "${issue_body:0:8000}"
    printf '\n\n=== GATE ===\n%s\n' "$GATE_PATH"
    if [ -n "${GATE_LOG:-}" ] && [ -s "$GATE_LOG" ]; then
      printf '\n=== GATE LOG ===\n%s\n' "$(tail -c 6000 "$GATE_LOG")"
    fi
  } > "$input"

  # Fresh context each attempt. The builder gets no GitHub token and cannot run git, gh or curl.
  env -u GH_TOKEN -u GITHUB_TOKEN claude -p "$(cat "$FACTORY_DIR/prompts/builder.md")" \
    --model "$model" --effort medium --max-turns 25 \
    --max-budget-usd "${BUILDER_BUDGET:-2}" \
    --permission-mode dontAsk \
    --settings "$FACTORY_DIR/builder-settings.json" \
    --allowedTools "Read,Edit,Write,Glob,Grep,Bash(ruff:*)" \
    --output-format json < "$input" > "$RUNNER_TEMP/builder-$n.json" || true

  # Surface what the builder did, so a failed run can be diagnosed from the job log.
  echo "::group::builder attempt $n ($model)"
  jq -c '{is_error, subtype, num_turns, total_cost_usd, errors, permission_denials, result: ((.result // "") | .[0:800])}' \
    "$RUNNER_TEMP/builder-$n.json" 2>/dev/null || head -c 2000 "$RUNNER_TEMP/builder-$n.json" || true
  echo "::endgroup::"
}

diff_patch() {
  : "${BASE_SHA:?}"
  mkdir -p "$RUNNER_TEMP/patch"

  # The factory's own checkout sits inside the target workspace as a nested repo. Keep it out of
  # `git add -A`, or it is committed as an embedded repo (gitlink) and breaks the PR.
  printf '/factory/\n' >> "$(git rev-parse --git-path info/exclude)"
  git add -A

  # Refuse to publish an embedded repository. A gitlink here would break the PR.
  if grep -q '^160000' <<<"$(git ls-files -s -- factory)"; then
    echo "embedded repository in the change; refusing to publish" >&2
    exit 1
  fi

  # Against the base commit, so commits made in this workspace are included, not just the tree.
  git -c core.hooksPath=/dev/null diff --cached --binary --no-ext-diff "$BASE_SHA" > "$RUNNER_TEMP/patch/patch.diff"
}

case "$cmd" in
  implement) implement ;;
  diff) diff_patch ;;
  *) echo "unknown subcommand: $cmd" >&2; exit 2 ;;
esac
