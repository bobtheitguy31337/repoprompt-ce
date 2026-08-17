---
name: rpce-contribution-check
description: Validate RepoPrompt CE commits and pushes. Sandbox delivery uses lightweight sandbox-commit/sandbox-push modes; upstream, production, release, and PR-ready work retains repository guardrails and heavyweight lanes. All paths preserve staged/outgoing redacted secret scanning, clean push boundaries, and destructive-operation approval.
---

# RepoPrompt CE Contribution Check

Read `AGENTS.md` first and choose the lane for the actual destination.

## Sandbox lane

After the coherent feature's single focused batch, use:

```bash
.agents/skills/rpce-contribution-check/scripts/preflight.sh sandbox-commit
.agents/skills/rpce-contribution-check/scripts/preflight.sh sandbox-push
```

`sandbox-commit` keeps whitespace and staged-index secret scanning but skips repository guardrails and validation lanes. `sandbox-push` additionally requires a clean local `sandbox` branch tracking `origin/sandbox` and scans its outgoing range. Do not use these modes for upstream, production, releases, public artifacts, or another branch.

## Upstream/production before committing

1. Review `git status --short` and inspect the intended diff.
2. Stage only intended files. Review `git diff --cached --stat` and `git diff --cached`.
3. Run:

```bash
.agents/skills/rpce-contribution-check/scripts/preflight.sh commit
```

4. Rerun commit preflight after any staging change, including partial-staging updates. Commit mode scans materialized staged index blobs, not merely working-tree copies.
5. Keep secret values redacted in terminal output and summaries.

## Upstream/production before pushing

1. Ensure the working tree is clean.
2. Run the immediate push safety gate:

```bash
.agents/skills/rpce-contribution-check/scripts/preflight.sh push
```

3. Review the computed current-branch range printed by the script.
4. Read [references/validation-matrix.md](references/validation-matrix.md) and ensure any required focused, release, smoke, or PR-ready evidence is recorded before pushing.
5. Push only the intended current branch and check the GitHub Actions run after pushing.

Default push mode validates whitespace, staged-index secrets, guardrails, clean worktree state, the current-branch outgoing range, and outgoing-range secrets. It does not run heavyweight lint/test/build/provider lanes.

Push mode validates only the current branch against its configured upstream. For a non-`main` topic branch without a configured upstream, it may use `origin/main` as an explicit comparison fallback. It does not validate tags, `--all`, `--mirror`, or arbitrary refspecs.

## Full / PR-ready local validation

When preparing computed-outgoing-range local PR evidence, when a maintainer requests it, or when the validation matrix calls for the path-selected lane, run:

```bash
.agents/skills/rpce-contribution-check/scripts/preflight.sh pr-ready
```

`pr-ready` reruns the push safety gate, then runs any matching path-selected heavyweight lanes for the computed outgoing range, such as conductor selftests, Swift lint, root/provider tests, product builds, and generated Xcode workspace validation for Xcode boundary changes. Heavy build/test/package lanes may wait on conductor's per-user global heavy slot when another worktree is already running Swift/Xcode-heavy work; treat that as coordination, not a reason to launch duplicate direct `swift`/`xcodebuild` commands. It does not replace explicit release validation, live smoke, already-pushed PR-base comparison, or destructive-operation approval requirements.

## Escalate before destructive operations

Obtain explicit user approval immediately before force-push, history rewrite, branch deletion, fork deletion, credential rotation, any other GitHub-visible destructive mutation, visible app launch/relaunch, or stopping a visible app. Do not bundle approval for a future destructive step into an earlier request.

## Focused validation

Read [references/validation-matrix.md](references/validation-matrix.md) when deciding whether additional focused tests, builds, PR-ready validation, release checks, or live smoke are required.
