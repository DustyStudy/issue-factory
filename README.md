# Issue factory

A GitHub Actions workflow that turns a labeled issue into a pull request. A person reviews and merges that PR. The factory never merges.

This repo holds the reusable workflow, its scripts and its prompts. A target repo calls it from a thin caller file.

## What it does

When you label an issue `factory` in a target repo, three AI agents work through it in order:

1. **Intake** reads the issue and decides whether it is a clear, low-risk change a code repo can take. It posts its verdict as a comment on the issue.
2. **Build** implements the change on a new branch, then runs the target's own check script (the gate). The check has to pass.
3. **Review** reads the diff once, read-only, and posts PASS or CHANGES as a comment on the PR.

A person then reads the PR and merges it, or closes it.

```
label `factory` added by the repo owner, in a target repo
  -> intake   Haiku, no tools         PROCEED and risk low?  else -> needs-human, stops here
  -> build    Sonnet, Opus on retry   gate must pass, 2 tries  else -> needs-human
  -> PR       branch factory/issue-N, title "Resolve #N", body "Closes #N"
  -> review   Haiku, read-only        PASS -> factory-ready  else -> needs-human
  -> a person merges
```

Auto-merge is not part of this flow. A person merges every PR.

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
- A person merges every PR. Keep branch protection and required reviews on `main`, as you would for any change.
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

The target calls this repo's reusable workflow. This repo is private. Check Settings > Actions > General > Access, and allow callers from the target's owner. A caller in the same account has run this workflow end to end.

## Versions

A target pins the factory in two places: the `uses:` line and the `factory_ref` input. Keep them on the same release.

- `uses:` must be a full commit SHA, `factory.yml@<sha> # vX.Y.Z`. The target's zizmor check rejects a tag here.
- `factory_ref:` is the tag, `vX.Y.Z`, which names the same commit.

Changes to this repo reach a target only when the target changes its pin.

To upgrade a target: review the diff between the old and new tags here, then get the new commit with `git rev-parse vX.Y.Z^{commit}`. Change the SHA and comment on the `uses:` line, and change `factory_ref` to the new tag.

## Cost controls

- Models follow Anthropic's "choosing a model" guidance: start on the cheapest model that can do the job, and escalate only when needed. Intake and review run on Haiku 5.5 (effort low and medium). The builder starts on Sonnet 5.5 (effort medium). Only the retry escalates to Opus 5.5, after a gate failure. Override it with `BUILDER_RETRY_MODEL`.
- Each run has a dollar cap: `intake_budget`, `builder_budget` (per attempt), `review_budget`, set as inputs by the caller.
- The builder gets two attempts and a turn limit. A second failure goes to a human.
- Issue text is cut to 8,000 characters. The diff is cut to 60,000.
- One run at a time per target (`concurrency`). Runs queue; they do not cancel each other.
- Intake and review run with `--bare`, which skips CLAUDE.md, hooks and plugins. Each headless call pays a fixed startup cost. In a local probe with no tools, one Haiku call cost about $0.10 in cache writes.
- Check `cost_usd=` in the job logs. The runs so far on the test target logged two small values, and I could not match them to steps, so the full cost per issue is not yet measured.

## Safety

- Intake and review have no write tools and get no GitHub token.
- The builder runs with no GitHub token and cannot run git, gh or curl. `builder-settings.json` denies edits to `.github/`, `.claude/`, and `scripts/factory/`, and denies `env` and `printenv`.
- The push token exists only in the push step.
- The builder's output is checked again for protected paths before commit.
- The gate is snapshot from the base commit before the builder runs, and that copy decides pass or fail. A branch cannot weaken the gate that judges it.
- Only the repo owner's label events start a run.
- **Known gap:** the build step has `ANTHROPIC_API_KEY` in its environment, and the gate and the builder's `pytest` runs execute code the builder wrote. A test that reads the environment could send the key out. The builder cannot print the environment directly, but test code can. Until this is fixed, treat the key as readable by test code, and keep its spend limit low. The planned fix is to run the gate and tests without the key, and to remove the builder's direct `pytest` permission.

## Status and known gaps

- Ran end to end on one test repo, `DustyStudy/factory-test-target`, with several issues. Two builds failed the gate before one passed. Not yet run on a production codebase.
- The intake and review verdicts have not been measured against past issues and PRs. There is no eval set yet. Run both on known outcomes before you trust them.
- One issue, one build, one review. No fix loop after a CHANGES review, which is deliberate to limit spend. A CHANGES review goes to a human.
- The Claude Code CLI is pinned to `CLAUDE_CODE_VERSION`. Bump it deliberately.
- This repo's own CI runs shellcheck, ruff, gitleaks and zizmor on each PR.
