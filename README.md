# binge-ci

Shared CI and agent workflows for the Binge repositories.

The five agent workflows here were extracted from
[Binge](https://github.com/ScottCooper92/Binge), where they had grown to ~2000 lines of
shell whose comments encode real, expensive bug fixes: the `0x1f` field separator
instead of tab, `--paginate` being load-bearing on three comment endpoints,
`--max-turns 100` set only after #1968 and #1969 failed in opposite directions.
Copying those files into a second and third repo would lose those fixes one at a
time, silently. They live here once and every repo calls them.

> **Status: draft.** Nothing has been pushed and no repo calls these yet. See
> "Before this can run" below.

## Layout

```
.github/workflows/    The five reusable workflows (workflow_call only)
.github/actions/      ci-setup, the Android build bootstrap
callers/              Draft thin callers, one directory per consuming repo
```

`callers/` is not wired to anything — it is where the per-repo files are drafted
before being moved into their own repositories.

## The five workflows

| Workflow | What it does | Agent? |
| --- | --- | --- |
| `bot-review.yml` | Reviews a PR once CI is green; optionally squash-merges | yes |
| `author-ci-fix.yml` | One repair attempt per commit on a red CI run | yes |
| `author-comments.yml` | Answers review feedback of all three kinds | yes |
| `author-conflicts.yml` | Scans for conflicted PRs when the base moves, resolves them | yes |
| `author-retarget.yml` | Catches a stacked PR up to its new base | no — plain git |

## What is shared and what is not

The **mechanism** is shared: the trust boundary, the label gate, the fork guard,
the loop caps, the marker-comment dedup, the "report a failed run rather than
going silent" step every one of these ends with. Those are the parts that took
work to get right and that no repo should re-derive.

The **rules** are not, and are passed in as inputs:

- `gate_rules` — the "never silence a gate" block. Binge names its detekt
  baseline, its allowlists and its screenshot PNGs; binge-integrations names
  `buf` exclusions and proto field numbers. Nothing generalises between them.
- `conflict_rules` — which conflicts the agent may not arbitrate.
- `verify_guidance` — the scoped command this repo expects before a change is
  claimed verified.
- `gated_checks` — what CI already enforces, so the review does not re-report it.

Resist the pull to generalise these into one list. A rule that fits both repos is
usually a rule that is too vague to bind either.

## Per-repo differences that are load-bearing

| | Binge | binge-integrations |
| --- | --- | --- |
| Visibility | private | **public** |
| Default branch | `master` | `main` |
| Toolchain | `android` (ci-setup) | `jvm` + buf |
| `auto_merge` | true | **false** |

The public/private split is the one to hold onto. In Binge the same-repository
guard was belt-and-braces, because a private repo has no forks; in a public repo
it is the only thing between a drive-by fork PR and a persistent self-hosted
runner holding secrets. Do not weaken it, and do not add a `pull_request_target`
path to any workflow that executes checked-out code. `author-retarget.yml` uses
that trigger and is safe precisely because it runs `git merge` and `git push` and
nothing else.

## Why `ci-setup` lives here

A local action reference (`uses: ./.github/actions/ci-setup`) inside a reusable
workflow resolves against **this** repository, not the caller's. So the Android
bootstrap had to move here for the agent workflows to reach it. Binge's `ci.yml`
should switch from `./.github/actions/ci-setup` to
`ScottCooper92/binge-ci/.github/actions/ci-setup@v1` so there is exactly one copy
rather than two that drift.

## Before this can run

Per consuming repo:

1. Register the `agent-runner` self-hosted runner against the repo.
2. Install both GitHub Apps (author, reviewer) on it.
3. Add `REVIEWER_APP_ID`, `REVIEWER_APP_PRIVATE_KEY`, `AUTHOR_APP_ID`,
   `AUTHOR_APP_PRIVATE_KEY`, `CLAUDE_CODE_OAUTH_TOKEN` as secrets, and
   `AUTHOR_BOT_ID` as a repository variable.
4. Create the `agent` label, and keep it maintainers-only. Applying it grants
   code execution with secrets on the agent-host host.
5. Write the governing docs the agents read from the default branch. For
   binge-integrations that means a `CLAUDE.md`, a `.ai/agents/pr-review-guide.md`
   and a `.ai/agents/ci-triage.md` that are about protos and buf — not copies of
   Binge's, which are about Compose and a screenshot gate.

Repo-wide:

- Resolve `bufbuild/buf-action@v1` to a SHA before any caller sets
  `setup_buf: true`. Every other action in these files is SHA-pinned because
  these jobs run an agent with Bash, Edit, Write and a contents:write token on a
  persistent runner, and a mutable tag inside that boundary is the supply-chain
  hole the rest of the discipline closes.
- Tag `v1` once the first caller is green.
