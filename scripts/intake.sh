#!/usr/bin/env bash
# Intake: classify one issue with no tools. Writes proceed=true|false to $GITHUB_OUTPUT
# and comments the verdict on the issue. Anything unclear goes to a human.
set -euo pipefail
: "${FACTORY_DIR:?}" "${ISSUE_NUMBER:?}" "${ISSUE_TITLE:?}" "${GITHUB_OUTPUT:?}" "${GH_TOKEN:?}" "${GH_REPO:?}"

# Labels the factory uses. --force makes this idempotent. `factory` is the start signal.
gh label create needs-human --color D93F0B --description "Factory stopped; a person decides" --force
gh label create factory-ready --color 0E8A16 --description "Factory review passed; ready for human merge" --force
gh label create factory --color 1D76DB --description "Start the issue factory on this issue" --force

work="$(mktemp -d)"
{
  printf '=== ISSUE ===\n%s\n\n' "$ISSUE_TITLE"
  printf '%s' "${ISSUE_BODY:-}" | head -c 8000
} > "$work/in.txt"

# GH_TOKEN is stripped so the model process never holds it.
env -u GH_TOKEN claude -p "$(cat "$FACTORY_DIR/prompts/intake.md")" --bare \
  --model claude-haiku-5-5 --effort low --tools "" --max-turns 2 \
  --max-budget-usd "${INTAKE_BUDGET:-0.25}" \
  --output-format json < "$work/in.txt" > "$work/out.json" || true

verdict="NEEDS-HUMAN"
risk="high"
comment="Intake could not classify this issue."
if out="$(python3 "$FACTORY_DIR/scripts/json_field.py" "$work/out.json")"; then
  verdict="$(jq -r '.verdict // ""' <<<"$out")"
  risk="$(jq -r '.risk // ""' <<<"$out")"
  comment="$(jq -r '.comment // ""' <<<"$out")"
fi

case "$verdict" in
  PROCEED|NEEDS-INFO|REJECT) ;;
  *) verdict="NEEDS-HUMAN"; risk="high" ;;
esac
[ "$risk" = "low" ] || risk="high"

proceed=false
if [ "$verdict" = "PROCEED" ] && [ "$risk" = "low" ]; then
  proceed=true
fi

printf 'Intake: **%s** (risk: %s)\n\n%s\n' "$verdict" "$risk" "$comment" > "$work/comment.md"
gh issue comment "$ISSUE_NUMBER" --body-file "$work/comment.md"

# Remove the start label either way, so re-adding it is the only way to re-run.
gh issue edit "$ISSUE_NUMBER" --remove-label factory || true
if [ "$proceed" != true ]; then
  gh issue edit "$ISSUE_NUMBER" --add-label needs-human
fi

echo "proceed=$proceed" >> "$GITHUB_OUTPUT"
