# CLAUDE.md

Conventions for this repository. The agent workflows read this file from `main` and treat
it as the source of truth; so should you.

## What this repository is

The shared CI for Binge and its companions: five reusable workflows (a review bot and four
author bots), the composite actions they need, the checks actionlint cannot do, and worked
callers for the two public consumers. Read `README.md` for the shape of it and
`MIGRATION.md` for how the consumers got here.

Nothing here builds. It is shell and YAML, and it runs inside three other repositories.

## The one rule everything else serves

**A change here is a change in three other repositories that will not notice until their
next release.**

A reusable workflow's inputs, outputs, secrets and required permissions are its public
signature. A caller that no longer fits dies as `startup_failure` before a single step runs,
with nothing on the PR. So a PR that changes one says so in its body, keeps the worked
callers under `callers/` in step in the same commit, and names the consumer PRs that have to
follow. `tools/check-callers.sh` catches the mechanical part for the two public consumers;
Binge's callers live on its own `ci/binge-ci-callers` branch and it cannot see them. The
`self-*.yml` callers are the exception: they pin a release tag and are checked against the
workflow at that tag, so they change in the release bump and never with the workflow.

The consumers pin `@v1`, a moving alias, and this repository's own actions and callers pin
the immutable `vX.Y.Z` the release was cut at. Releasing is bumping those pins, merging,
tagging `vX.Y.Z` at that commit, then moving `v1` - in that order, by a human.
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
  comment. Self-references use the release tag and never `./` - inside a reusable workflow a
  local path resolves against the caller's workspace.
- Workflow and caller files end in `.yml`. Every glob here says so.
- A path that governs an agent (`CLAUDE.md`, `.claude`, `.ai/` and the rest of the
  governed-paths list) is read from the base branch, never from the PR head. Keep it that
  way when adding a document the bots read.

## Gates

CI runs actionlint (with shellcheck) over the workflows and callers, shellcheck over the
scripts, `tools/check-callers.sh`, `tools/check-action-shell.sh` and
`tools/check-internal-refs.sh`. There is no build, no test suite beyond those, and no
coverage floor, so do not look for one and do not report a finding as though one had caught
it. `tag-check.yml` runs on pushes to `main` and on tags, not on PRs.

**Never silence a gate instead of fixing it.** Do not weaken a step in `ci.yml` or a check
in `tools/`, and do not touch a `uses:` pin to make `check-internal-refs.sh` pass - that is
a release, not a repair.

## Follow-ups

Anything worth doing that does not belong in the diff in front of you becomes a GitHub
issue, not a TODO comment and not a line in a PR description. The test is scope, not
severity. Dedupe against the open backlog before filing, and label it using the labels the
repository already has.

## Commits and pull requests

- Conventional-commit subjects (`feat:`, `fix:`, `docs:`, `chore:`), imperative mood.
- One reviewable idea per PR. A release bump is a PR of its own.
- A PR that changes a workflow's signature, a caller, or what a bot posts says what it means
  for the consumers.
- Documentation here is plain, direct English - short sentences, one idea each.

## Agent workflows

The five bots run on this repository's own PRs too, through the `self-*.yml` callers in
`.github/workflows/`, pinned to the same release tag as the actions. A PR here is reviewed
by the reviewer the consumers run, never by the one it is changing. They act only on PRs
carrying the `agent` label, and `auto_merge` is off: everything here governs the agents, so
a merge is a human's decision.

**That label is maintainers-only.** Applying it grants an agent code execution with this
repository's secrets in scope. Do not apply it to a PR you have not read, and never to one
from a fork - the workflows refuse fork PRs, and on a public repository that guard is the
load-bearing control rather than a formality.
