# Issue factory

A GitHub Actions workflow that turns a labeled issue into a pull request. By default a person reviews and merges that PR. A repo can opt in to automatic merge after the review passes (see [Automatic merge](#automatic-merge)).

This repo holds the reusable workflow, its scripts and its prompts. A target repo calls it from a thin caller file.

## What it does

Applying the `factory` label starts the workflow. Three agents handle intake, implementation, and review. A separate publish step opens the pull request.

1. **Intake** reads the issue and decides whether it is a clear, low-risk change a code repo can take. It posts its verdict as a comment on the issue.
2. **Build** has the builder write the change, then runs the target's own check script (the gate). The gate has to pass. The builder gets two attempts.
3. **Publish** applies the change to a clean checkout, refuses protected paths, and opens the PR.
4. **Review** reads the diff once, with no tools, and posts PASS or CHANGES as a comment on the PR.

By default a person then reads the PR and merges it, or closes it. With `auto_merge: true`, the factory squash-merges the PR once the review passes.

```
label `factory` added by the repo owner, in a target repo
  -> intake    Haiku, no tools         PROCEED and risk low?   else -> needs-human, stops here
  -> build 1   Sonnet, API key         writes a patch          (fresh runner)
  -> gate 1    no key, no token        target gate passes?     else -> build 2 (Opus, gate log)
  -> build 2   Opus, API key           writes a patch          (fresh runner, only after gate 1 fails)
  -> gate 2    no key, no token        target gate passes?     else -> needs-human
  -> publish   clean checkout, token   protected paths? -> needs-human; else branch factory/issue-N, PR "Closes #N"
  -> review    Haiku, no tools         PASS -> factory-ready   else -> needs-human
  -> merge     a person (default)      or, with auto_merge: true, squash-merge on factory-ready
```

## Automatic merge

Off by default. A caller turns it on with one input:

```yaml
    with:
      gate_path: scripts/factory/gate.sh
      factory_ref: v2.2.1
      auto_merge: true
```

With it on, the factory squash-merges the PR only if the review labeled it `factory-ready`. If the merge fails, the PR gets `needs-human`. The merge uses `FACTORY_PAT` when the caller passes it, and the built-in token otherwise.

Before turning it on for a repo, know what it removes: the only checks left are the target's gate and one reviewer call. A person no longer reads each change first. The reviewer has failed once on a clean change (a verdict was not produced), and a retry was added after that. Its PASS decisions have not been measured against past PRs.

## Who it's for, and what to use it for

The factory suits a team that has a test suite it trusts, a backlog of small, well-specified tasks, and time spent on routine changes.

**Good fits**

- A small feature or endpoint that follows an existing pattern, with a test.
- A bug fix with a test that reproduces the bug.
- Adding missing unit tests for code that already works.
- A small refactor with a clear scope.
- Documentation or config changes that a test or the gate covers.

**Poor fits, or do not use**

- Changes to CI, workflows, infrastructure, IAM, encryption, or anything that handles credentials. Intake marks these high risk and stops them, but you should still keep them out of scope on purpose.
- Work that needs an architectural decision or a judgment call about the product.
- Repos whose tests are weak. The gate and one review pass are the only automated checks.
- Code that your data policy does not allow to be sent to a third-party AI API. See [Data and approvals](#data-and-approvals).

**How this fits a corporate setup**

- The owner of each target repo decides which issues get the `factory` label. Only the repo owner's label events start a run.
- By default a person merges every PR. Keep branch protection and required reviews on `main`, as you would for any change. If a repo opts in to `auto_merge`, the factory merges after the review passes, so decide that policy with the repo's owners first.
- Every step leaves an audit trail: the intake comment on the issue, the review comment on the PR, the job logs, and the PR itself.
- A platform or developer-productivity team can own the caller file, the API key and the spend limits. Product teams only label issues.

## Data and approvals

Before you run this on a repo, check that your organization's policy allows the data below to go to Anthropic's API:

- The issue title and body (cut to 8,000 characters).
- The files the builder reads from the target repo.
- The gate's output (the last part of its log).
- The PR diff, when the reviewer runs (cut to 60,000 characters).

The `ANTHROPIC_API_KEY` is a GitHub Actions secret on the target repo. Use a key dedicated to this, with a spend limit, and rotate it on your usual schedule.

## Add a target repo

1. Copy [examples/target-caller.yml](examples/target-caller.yml) to `.github/workflows/factory.yml` in the target. Pin it as described under [Versions](#versions).
2. Give the target a gate script at the path in `gate_path`. It must exit 0 only when the change is good. It runs from the repo root.
3. Run the one-time setup (you run these):

```powershell
gh label create factory -R OWNER/REPO --color 1D76DB
gh secret set ANTHROPIC_API_KEY -R OWNER/REPO
```

4. In the target, enable Settings > Actions > General > "Allow GitHub Actions to create and approve pull requests".
5. Recommended: a `FACTORY_PAT` secret, a fine-grained token with Contents and Pull requests read and write on the target only. Pass it as `factory_pat`. Without it, factory PRs do not show the target's CI checks. That was confirmed on the test target.

Add the `factory` label to an issue to start a run. The label is removed at intake, so re-add it to re-run.

## Access to this repo

This repo is public, so any target can call its reusable workflow without an access setting. The scripts and prompts are public too. Keep secrets out of them; the API key lives only in each target's secrets.

## Versions

A target pins the factory in two places: the `uses:` line and the `factory_ref` input. Keep them on the same release.

- `uses:` must be a full commit SHA, `factory.yml@<sha> # vX.Y.Z`. The target's zizmor check rejects a tag here.
- `factory_ref:` is the tag, `vX.Y.Z`, which names the same commit.

Changes to this repo reach a target only when the target changes its pin.

To upgrade a target: review the diff between the old and new tags here, then get the new commit with `git rev-parse vX.Y.Z^{commit}`. Change the SHA and comment on the `uses:` line, and change `factory_ref` to the new tag.

## Cost controls

- Models follow Anthropic's "choosing a model" guidance: start on the cheapest model that can do the job, and escalate only when needed. Intake and review run on Haiku 5.5 (effort low and medium). The builder starts on Sonnet 5.5 (effort medium). Only the retry escalates to Opus 5.5, after a gate failure. The retry model is set in `scripts/build.sh`.
- Each run has a dollar cap: `intake_budget`, `builder_budget` (per attempt), `review_budget`, set as inputs by the caller.
- The builder gets two attempts and a turn limit. A second failure goes to a human. Each attempt and each gate runs on its own runner, which adds runner minutes but no tokens.
- Issue text is cut to 8,000 characters. The diff is cut to 60,000.
- One run at a time per target (`concurrency`). Runs queue; they do not cancel each other.
- Intake and review run with `--bare`, which skips CLAUDE.md, hooks and plugins. Each headless call pays a fixed startup cost. In a local probe with no tools, one Haiku call cost about $0.10 in cache writes.
- Check `cost_usd=` in the job logs. The runs so far on the test target logged two small values, and I could not match them to steps, so the full cost per issue is not yet measured.

## Safety

- Intake and review have no write tools and get no GitHub token. The reviewer has no tools at all: it judges the diff it is given.
- The builder has no GitHub token and cannot run git, gh or curl. Its only shell tool is `ruff`, which runs no project code. `builder-settings.json` denies edits to `.git/`, `.github/`, `.claude/`, and `scripts/factory/`, and denies reads of `/proc` and `env` and `printenv`.
- Every step that holds `ANTHROPIC_API_KEY` runs on a runner that never ran the gate. Each builder attempt is its own job. Patches and gate logs move between jobs as artifacts, not as files on disk.
- The gate runs in a job with no API key and no token. The test code the builder wrote runs there, and nothing from that job is trusted afterward.
- The publish job runs on a clean checkout of the base commit, with the push token. It applies the patch, refuses any change under `.github/`, `.claude/` or `scripts/factory/` (checked against the base commit, so a commit made in the workspace is caught too), commits with hooks off, and pushes. The push token never runs in a repo the gate touched.
- The gate's snapshot is taken from the base commit, not the branch, so the builder cannot weaken the gate that judges it.
- Only the repo owner's label events start a run.
- A run that stops for any reason labels the issue `needs-human` and comments once.
- **Known limit:** test code runs as the runner user, which can read and write its own job's files. The protection is that no key or token is in that job and that its files never reach a key-holding job or the publish job. It does not stop the test code from making its own job's gate pass.
- **Unverified:** the `Read(//proc/**)` deny uses Claude Code's absolute-path syntax at the pinned version. The reviewer has no tools, so it does not depend on that rule.

## Status and known gaps

- Verified live on `DustyStudy/factory-test-target` at v2.2.1, with `auto_merge: true`: a labeled issue went through intake, build, gate, publish, review and automatic merge with no manual step, and the issue closed through its "Closes #N" line. Intake refused a request to add a workflow under `.github/`.
- Verified live: a gate failure on attempt 1 ran the attempt-2 retry, which also failed the gate. The run then stopped with no PR, and the issue got one comment with both gate results and `needs-human`.
- Found and fixed by live runs on the test target: the gate jobs could not read a private target (v2.1.1), the review read an empty PR number (v2.1.2), and a bare `needs.publish.result` condition skipped the review (v2.1.3). The v2.2.0 review also failed on a clean change, and v2.2.1 added a retry.
- Reviewer reliability is not measured. On v2.2.0 one clean change got no verdict; on v2.2.1 the reviews that ran passed. Run more changes before trusting it on a real repo.
- Not verified live: the publish-level protected-path refusal. Intake and the builder's deny rules block those requests before publish, so only the local tests in `tests/test_build.sh` exercise that check. Not yet run on a production codebase.
- The intake and review verdicts have not been measured against past issues and PRs. There is no eval set yet. Run both on known outcomes before you trust them.
- One issue, one build, one review. No fix loop after a CHANGES review, which is deliberate to limit spend. A CHANGES review goes to a human.
- A crash in any stage labels the issue or PR `needs-human`, so a failed run does not go silent.
- PRs target the target repo's default branch, not a hardcoded `main`.
- The Claude Code CLI is pinned to `CLAUDE_CODE_VERSION`. Bump it deliberately.
- This repo's own CI runs shellcheck, ruff, unit tests for `scripts/json_field.py`, the build chain tests in `tests/test_build.sh`, gitleaks and zizmor on each PR. The intake and review scripts have no automated tests.
