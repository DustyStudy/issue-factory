# Issue factory

Turns a labeled GitHub issue into a PR, with a human at the merge step. This repo holds the reusable workflow, its scripts, and its prompts. Target repos call it from a thin caller.

```
label `factory` added by the repo owner, in a target repo
  -> intake   (Haiku, no tools)          PROCEED? low risk?   else -> needs-human
  -> build    (Sonnet; Opus on retry)    target gate passes?  else -> needs-human
  -> PR       branch factory/issue-N, body "Closes #N"
  -> review   (Haiku, read-only)         PASS -> factory-ready, else -> needs-human
  -> you merge
```

Auto-merge is not part of this flow. A person merges every PR.

## Add a target repo

1. Copy [examples/target-caller.yml](examples/target-caller.yml) to `.github/workflows/factory.yml` in the target.
2. Give the target a gate script at the path in `gate_path`. It must exit 0 only when the change is good. It runs from the repo root.
3. Run the one-time setup (you run these):

```powershell
gh label create factory -R OWNER/REPO --color 1D76DB
gh secret set ANTHROPIC_API_KEY -R OWNER/REPO
```

4. In the target, enable Settings > Actions > General > "Allow GitHub Actions to create and approve pull requests".
5. Optional: `FACTORY_PAT`, a fine-grained token with Contents and Pull requests write on the target only. Pass it as `factory_pat`. Without it, factory PRs do not trigger CI.

Add the `factory` label to an issue to start a run. The label is removed at intake, so re-add it to re-run.

## Access to this repo

The target calls this repo's reusable workflow. This repo is private. Check Settings > Actions > General > Access, and allow callers from your account. This is not yet verified on a live run.

## Cost controls

- Models follow Anthropic's "choosing a model" guidance: start on the cheapest model that can do the job, and escalate only when needed. Intake and review run on Haiku 5.5 (effort low and medium). The builder starts on Sonnet 5.5 (effort medium). Only the retry escalates to Opus 5.5, after a gate failure. Override it with `BUILDER_RETRY_MODEL`.
- Each run has a dollar cap: `intake_budget`, `builder_budget` (per attempt), `review_budget`, set as inputs by the caller.
- The builder gets two attempts and a turn limit. A second failure goes to a human.
- Issue text is cut to 8,000 characters. The diff is cut to 60,000.
- One run at a time per target (`concurrency`).
- Each headless call pays a fixed startup cost. In a local probe with no tools, one Haiku call cost about $0.10 in cache writes. Intake and review use `--bare`, which skips CLAUDE.md, hooks and plugins. Check `cost_usd=` in the job log on the first real run.
- No eval set exists yet. Before trusting Haiku for intake and review, run both on past issues and PRs with known outcomes.

## Safety

- Intake and review have no write tools and get no GitHub token.
- The builder runs with no GitHub token and cannot run git, gh or curl. `builder-settings.json` denies edits to `.github/`, `.claude/`, and `scripts/factory/`.
- The push token exists only in the push step.
- The builder's output is checked again for protected paths before commit.
- Only the repo owner's label events start a run.

## Known gaps

- One issue, one build, one review. No automatic fix loop after a CHANGES review. This is deliberate, to limit spend.
- Not tested live. The workflow has not run in GitHub Actions yet.
- The job pins the factory by `job.workflow_sha`, which is unverified. Pin the caller to a tag or SHA once tested.
- Claude Code CLI is pinned to `CLAUDE_CODE_VERSION`. Bump it deliberately.
