#!/usr/bin/env bash
# Runs the factory's build chain locally: build.sh diff -> run-gate.sh -> open-pr.sh. The test plays
# the builder by running a shell snippet in the workspace. The push goes to a bare repo on disk, and
# gh is a stub, so the protected-path check and the gate verdict are exercised end to end.
# Run: bash tests/test_build.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0

# run_case NAME CHANGE WANT_GATE WANT_PUBLISH
# CHANGE is shell run in the repo in place of the builder. WANT_PUBLISH is pushed, refused or skipped.
run_case() {
  local name="$1" change="$2" want_gate="$3" want_publish="$4"
  local t gate publish pr_status branch="factory/issue-7-1"
  t="$(mktemp -d)"

  git init -q --bare "$t/remote.git"
  git init -q "$t/repo"
  (
    cd "$t/repo"
    git config user.name tester
    git config user.email tester@example.com
    printf 'test -f ok.txt\n' > gate.sh
    mkdir -p .github
    printf 'keep\n' > .github/keep.yml
    git add -A
    git commit -q -m base
    git remote add origin "$t/remote.git"
    git push -q origin HEAD:main
  )
  mkdir -p "$t/bin"
  cat > "$t/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth setup-git") exit 0 ;;
  "pr create") echo "https://example.test/pull/1" ;;
  "pr view") echo 1 ;;
esac
STUB
  chmod +x "$t/bin/gh"

  local base
  base="$(git -C "$t/repo" rev-parse HEAD)"

  # 1. The builder's workspace: run the change, then write the patch.
  (
    cd "$t/repo"
    eval "$change"
    RUNNER_TEMP="$t/rt" BASE_SHA="$base" bash "$here/scripts/build.sh" diff 1
  ) > "$t/log1" 2>&1 || { echo "FAIL $name: diff step exited non-zero"; cat "$t/log1"; failures=$((failures + 1)); return; }

  # 2. The gate job: a fresh checkout at base, then the patch applied and the gate run.
  (
    cd "$t/repo"
    git reset -q --hard "$base"
    git clean -fdq
    RUNNER_TEMP="$t/rt" GATE_PATH=gate.sh GITHUB_OUTPUT="$t/gout" \
      bash "$here/scripts/run-gate.sh" 1 "$t/rt/patch/patch.diff"
  ) > "$t/log2" 2>&1 || { echo "FAIL $name: gate step exited non-zero"; cat "$t/log2"; failures=$((failures + 1)); return; }
  gate="$(grep '^gate=' "$t/gout" 2>/dev/null | tail -1 | cut -d= -f2- || true)"

  # 3. The publish job: a fresh clone, the patch applied, checked, committed, pushed.
  publish="skipped"
  if [ "$gate" = "pass" ]; then
    git clone -q "$t/remote.git" "$t/pub"
    pr_status=0
    (
      cd "$t/pub"
      PATCH="$t/rt/patch/patch.diff" BASE_SHA="$base" BRANCH="$branch" BASE_BRANCH=main \
        ISSUE_NUMBER=7 ISSUE_TITLE="Test issue" GH_TOKEN=x GH_REPO=test/test \
        GITHUB_OUTPUT="$t/pout" PATH="$t/bin:$PATH" bash "$here/scripts/open-pr.sh"
    ) > "$t/log3" 2>&1 || pr_status=$?
    if [ "$pr_status" -eq 0 ]; then
      publish="pushed"
    else
      publish="refused"
    fi
    if [ "$publish" = "pushed" ] && [ -z "$(git ls-remote "$t/remote.git" "refs/heads/$branch")" ]; then
      publish="not-pushed"
    fi
    if [ "$publish" = "refused" ] && [ -n "$(git ls-remote "$t/remote.git" "refs/heads/$branch")" ]; then
      publish="pushed-despite-refusal"
    fi
  fi

  if [ "$gate" = "$want_gate" ] && [ "$publish" = "$want_publish" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: gate=$gate publish=$publish (want gate=$want_gate publish=$want_publish)"
    if [ -f "$t/log3" ]; then tail -5 "$t/log3"; fi
    failures=$((failures + 1))
  fi
  rm -rf "$t"
}

run_case "allowed change passes the gate and is pushed" \
  'touch ok.txt' pass pushed

run_case "gate fails: nothing is published" \
  'echo x > notes.txt' fail skipped

run_case "a protected directory is refused at publish" \
  'mkdir -p .github/workflows; echo x > .github/workflows/ci.yml; touch ok.txt' pass refused

run_case "a protected path with a space is refused" \
  'mkdir -p .github/workflows; echo x > ".github/workflows/a b.yml"; touch ok.txt' pass refused

run_case "a commit made in the workspace is still checked against the base" \
  'touch ok.txt; mkdir -p .github; echo x > .github/ci.yml; git add -A; git commit -q -m sneaky' \
  pass refused

run_case "deleting a protected file is refused" \
  'git mv .github/keep.yml docs-keep.yml; touch ok.txt' pass refused

run_case "a hook in .git cannot block the diff or the publish" \
  'touch ok.txt; printf "#!/bin/sh\nexit 1\n" > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit' \
  pass pushed

if [ "$failures" -ne 0 ]; then
  echo "$failures case(s) failed" >&2
  exit 1
fi
echo "all build cases passed"
