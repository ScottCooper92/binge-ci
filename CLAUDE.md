# CLAUDE.md

Conventions for this repository. The agent workflows read this file from `main` and treat
it as the source of truth; so should you.

## What this repository is

The shared CI for Binge and its companions: twelve reusable workflows, the composite actions
they and the consumers need, the checks actionlint cannot do, and worked callers for the public
consumers. Five of the workflows are the bots, a review bot and four author bots. Three more are
shared steps a consumer would otherwise copy: the submodule-pin check, the consumer check and
the emulator lane. Then the weekly storage sweep, `fork-review.yml`, an advisory,
read-only review of a fork PR, and `upstream-watch.yml`, which opens an issue when a server the apps use ships a release, and `submodule-bump.yml`, which opens a PR moving a submodule pin to its branch head. Read `README.md` for the shape of it and
`MIGRATION.md` for how the consumers got here.

Most of it is shell and YAML, and it runs inside every repository that calls it. The one thing that builds is
`gradle-plugins/`: the shared Gradle gates, an included build the consumers apply by path.

## The one rule everything else serves

**A change here is a change in every consuming repository, and none of them will notice
until their next release.**

A reusable workflow's inputs, outputs, secrets and required permissions are its public
signature. A caller that no longer fits dies as `startup_failure` before a single step runs,
with nothing on the PR. So a PR that changes one says so in its body, keeps the worked
callers under `callers/` in step in the same commit, and names the consumer PRs that have to
follow. `tools/check-callers.sh` catches the mechanical part for the public consumers;
Binge's callers live in its own `.github/workflows/` and it cannot see them. The
`self-*.yml` callers are the exception: they pin a release tag and are checked against the
workflow at that tag, so they change in the release bump and never with the workflow.

The consumers follow `v1`, a moving alias: each pins the commit it names, with a `# v1`
comment, and moves when Renovate's digest update for it merges. This repository's own actions
and callers pin the immutable `vX.Y.Z` the release was cut at. Releasing is bumping those
pins, merging, tagging `vX.Y.Z` at that commit, then moving `v1` - in that order, by a human.
`tools/check-internal-refs.sh` and `tag-check.yml` hold the order; nothing else does.

## Shell and YAML

- Every `run:` block and every script is bash with `set -euo pipefail`, or says why not: a
  step that must report on the PR whatever happens runs with `-e` off and guards each
  command itself.
- shellcheck at `--severity=warning` and actionlint both gate. No `# shellcheck disable=`,
  no lowered severity.
- A comment explains a *why* the code cannot: a permission a caller has to hold, a race in
  the Actions event model, a `set -e` interaction. Not what the next line does.
- Every outcome reports on the PR. A bot that fails silently restores exactly the condition
  it exists to remove, so every job has an `always()` reporter, and every comment it posts
  is deduped on a marker keyed to the PR head.
- Third-party actions are pinned to a full commit SHA with the version in a trailing
  comment. Self-references use the release tag and never `./` inside a reusable workflow or
  composite action - there a local path resolves against the caller's workspace. `ci.yml` runs
  only here, so it uses the actionlint action by `./`: a release PR pins a tag that does not
  exist until it merges.
- Workflow and caller files end in `.yml`. Every glob here says so.
- A path that governs an agent (`CLAUDE.md`, `.claude`, `.ai/` and the rest of the
  governed-paths list) is read from the base branch, never from the PR head. Keep it that
  way when adding a document the bots read.

## Gates

CI runs actionlint (with shellcheck) over the workflows and callers, shellcheck over the
scripts, `tools/check-callers.sh`, `tools/check-action-shell.sh`, `tools/check-action-env.sh`
and `tools/check-internal-refs.sh`, with `tools/test-internal-refs.sh` testing the last against
fixtures, `tools/check-token-permissions.sh`, which holds each app-token mint to its app's grant and the author bots' write token to the calling repository
(tested by `tools/test-token-permissions.sh`, which also runs the submodule fetch step against a stubbed `git`), `tools/test-check-callers.sh`, which runs the caller check against fixture callers for each shape of `permissions:` grant, `tools/test-merge-guards.sh`, which runs the
merge guards' offline checks against fixed inputs, `tools/test-governed-paths.sh`, which runs the governed-paths script against scratch
repositories, `tools/test-submodule-pins.sh`, which runs the submodule-pin check's step the same way,
`tools/test-fork-review.sh`, which holds `fork-review.yml` to the properties its safety rests on and runs its
shared `collect_pr` function against a stubbed `gh`, and `tools/test-download-actionlint.sh`, which runs the actionlint
action's download-and-verify script against a stubbed `gh`, `tools/test-upstream-watch.sh`, which runs the upstream-watch
script against a stubbed `gh`, `tools/test-submodule-bump.sh`, which runs the submodule-bump script against scratch repositories and a stubbed `gh`, `tools/test-body-checklist.sh`, which holds the author bot's PR-body edit to a checklist box and one line, `tools/test-rebuttal-cap.sh`, which holds the review bot's cap on reconsidering an unchanged head, `tools/test-agent-limits.sh`, which holds the steps that bound each agent job's network calls and print its last tool calls, `tools/test-claude-code-cache.sh`, which holds the step that lets a self-hosted runner reuse one Claude Code install and runs it against a stubbed installer, `tools/test-rerecord-comment.sh`, which builds the screenshot re-record comment from scratch repositories and holds the prompt's gate and the review rules for it, `tools/test-shard-screenshots.sh`, which holds the screenshot sharding action to putting every class in exactly one shard and to failing closed, `tools/test-changed-files.sh`, which holds the changed-files action to skipping a job only for a path in a closed set and to running everything when it cannot read the diff, `tools/test-pin-only.sh`, which holds the pin-only action to answering `true` only for a pin to one tagged release and nothing else, and `tools/check-gate-lists.sh`, which fails when a list of these
gates here does not name one `ci.yml` runs (tested by `tools/test-check-gate-lists.sh`). It also runs `./gradlew build` in `gradle-plugins/`, which
compiles the gates and runs their unit and TestKit tests. There is no coverage floor, so do
not look for one and do not report a finding as though one had caught it.

A change to a gate's plugin id, extension or task names is a change in every consumer that
applies it, the same as a workflow's signature. `tag-check.yml` runs on pushes to `main` and on tags, not on PRs.

**Never silence a gate instead of fixing it.** Do not weaken a step in `ci.yml` or a check
in `tools/`, and do not touch a `uses:` pin to make `check-internal-refs.sh` pass - that is
a release, not a repair.

## Follow-ups

Anything worth doing that does not belong in the diff in front of you becomes a GitHub
issue, not a TODO comment and not a line in a PR description. The test is scope, not
severity. Dedupe against the open backlog before filing, and label it using the labels the
repository already has.

## Commits and pull requests

**Open every PR from `.github/pull_request_template.md`** (`gh pr create --body-file` it, then fill it in, or paste its checklist into your body). Tick only the checks you ran locally on the final head, and say what you left to CI and why. The review bot reads the ticks against this PR's earlier CI runs, so a ticked check that failed one of them is a finding.

- Conventional-commit subjects (`feat:`, `fix:`, `docs:`, `chore:`), imperative mood.
- One reviewable idea per PR. A release bump is a PR of its own.
- A PR that changes a workflow's signature, a caller, or what a bot posts says what it means
  for the consumers.
- Documentation here is plain, direct English - short sentences, one idea each.

## Agent workflows

The five bots run on this repository's own PRs too, through the `self-*.yml` callers in
`.github/workflows/`, and the weekly storage sweep has its own, `self-actions-storage-sweep.yml`.
All of them are pinned to the same release tag as the actions. A PR here is reviewed
by the reviewer the consumers run, never by the one it is changing. The bots act only on PRs
carrying the `agent` label, and `auto_merge` is off: everything here governs the agents, so
a merge is a human's decision.

**That label is maintainers-only.** Applying it grants an agent code execution with this
repository's secrets in scope. Do not apply it to a PR you have not read, and never to one
from a fork - the workflows refuse fork PRs, and on a public repository that guard is the
load-bearing control rather than a formality.
