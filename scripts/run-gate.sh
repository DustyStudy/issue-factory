#!/usr/bin/env bash
# Gate job: run the target's gate on the base commit plus one builder patch. This job has no API
# key and no token, and it runs the test code the builder wrote. It is a fresh runner, and nothing
# it leaves behind is trusted: the publish job starts from a clean checkout and re-checks the patch.
# Usage: run-gate.sh ATTEMPT PATCH. Writes gate=pass|fail|missing to $GITHUB_OUTPUT.
set -euo pipefail

attempt="${1:?attempt number}"
patch="${2:?patch path}"
: "${GATE_PATH:?}" "${GITHUB_OUTPUT:?}" "${RUNNER_TEMP:?}"

# Snapshot the gate from the base commit, before the patch can change it.
snapshot="$RUNNER_TEMP/gate-$attempt.sh"
if ! git show "HEAD:$GATE_PATH" > "$snapshot" 2>/dev/null; then
  echo "gate=missing" >> "$GITHUB_OUTPUT"
  exit 0
fi

if [ -s "$patch" ]; then
  git apply "$patch"
fi

log="$RUNNER_TEMP/gate-$attempt.log"
if bash "$snapshot" > "$log" 2>&1; then
  echo "gate=pass" >> "$GITHUB_OUTPUT"
else
  echo "::group::gate attempt $attempt output"
  tail -c 4000 "$log" || true
  echo "::endgroup::"
  echo "gate=fail" >> "$GITHUB_OUTPUT"
fi
