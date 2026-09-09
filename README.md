# binge-ci

Shared CI and agent workflows for the Binge repositories.

The five agent workflows here come from [Binge](https://github.com/ScottCooper92/Binge),
where they had grown to ~2500 lines of shell whose comments encode real, expensive bug
fixes: the `0x1f` field separator instead of tab, `--paginate` being load-bearing on
three comment endpoints, `--max-turns 100` set only after #1968 and #1969 failed in
opposite directions.

Copying those files into a second and third repo loses those fixes one at a time,
silently. That is not a hypothetical — it already happened. A first extraction on
2026-09-01/02 froze while Binge kept moving, `binge-integrations` took its own copy on
09-01, and `binge-seerr` was scaffolded from a sibling on 09-06. By 09-09 all three
copies were missing the same 23 commits, and Binge's `bot-review.yml` had grown 43%
past the version they shared. They live here once now, and every repo calls them.

> **Status: pre-first-push.** No repo calls these yet, and there is no `v1` tag. See
> "Re-derivation status" for which workflows are current and "Applying this" in
> [MIGRATION.md](MIGRATION.md) for the order to land it in.

## Re-derivation status

Each workflow is re-derived from Binge's HEAD rather than patched forward from the
09-02 draft — 23 commits against a restructured file is 23 conflicts and no guarantee.
The pre-re-derivation draft is preserved in this repo's first commit, so nothing
editorial is lost silently.

| Workflow | Lines | Re-derived | Behind Binge by |
| --- | --- | --- | --- |
| `bot-review.yml` | 941 | ✅ 2026-09-09 | — |
| `author-ci-fix.yml` | 787 | ✅ 2026-09-09 | — |
| `author-comments.yml` | 422 | ❌ still the 09-01 draft | 4 commits |
| `author-conflicts.yml` | 710 | ✅ 2026-09-09 | — |
| `author-retarget.yml` | 296 | ✅ 2026-09-09 | — |

**Do not point a caller at a workflow that is not yet re-derived.** It will run, and it
will be missing fixes the repo it came from has had for a week.

## Layout

```
.github/workflows/    The five reusable workflows (workflow_call only) + this repo's own CI
.github/actions/      ci-setup, the Android build bootstrap
callers/              Draft thin callers, one directory per consuming repo
tools/                check-callers.sh, the half of the gate actionlint cannot do
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

## Defaults are public-safe

Two of the three consuming repos are public, so the defaults are the strict posture and
a caller opts *out* rather than in. A repo that forgets to configure something gets the
safe setting, not Binge's.

| Input | Default | Why |
| --- | --- | --- |
| `runner` | `["ubuntu-latest"]` | Ephemeral. The `agent` label grants code execution on a throwaway VM rather than on a host that outlives the job. |
| `auto_merge` | `false` | Turning bot merging on should be a decision a caller made, not one it inherited. |
| `show_full_output` | `false` | The agent's stream carries what it read and ran. On a public repo the logs are world-readable. |
| `default_branch` | `main` | Binge is the only `master`. |

## Per-repo differences that are load-bearing

| | Binge | binge-integrations | binge-seerr |
| --- | --- | --- | --- |
| Visibility | private | **public** | **public** |
| Default branch | `master` | `main` | `main` |
| Runner | self-hosted `review-runner` | hosted | hosted |
| Toolchain | `android` (ci-setup) | `jvm` + buf | `android`, no ci-setup |
| `auto_merge` | true | **false** | **false** |
| `paths-ignore` | six patterns | none | none (deliberate) |

The public/private split is the one to hold onto. In Binge the same-repository
guard was belt-and-braces, because a private repo has no forks; in a public repo
it is the only thing between a drive-by fork PR and an agent holding a
contents:write token. Do not weaken it, and do not add a `pull_request_target`
path to any workflow that executes checked-out code. `author-retarget.yml` uses
that trigger and is safe precisely because it runs `git merge` and `git push` and
nothing else.

The `paths-ignore` row decides whether `bot-review`'s third door exists at all. Binge
has PRs CI will never run on, so the `labeled` trigger is the only way they get
reviewed; the other two repos have none, so passing no `unbuilt_paths` keeps that door
shut rather than letting it review code mid-build.

## This repo's own gate

It ships no code, so the two things that can be wrong with it are the workflows
themselves and whether the callers still fit them:

- **actionlint**, with shellcheck on PATH, over both the workflows and the drafted
  callers. `--severity=warning`: shellcheck's info level fires SC2016 on every
  `printf '...%s...'` in these files, where single quotes are exactly right.
- **`tools/check-callers.sh`**, which matches each caller's `with:` keys against the
  target workflow's declared inputs and its secrets against what is passed. actionlint
  validates inputs for a *local* `./.github/workflows/x.yml` call but cannot fetch a
  remote `ScottCooper92/binge-ci/...@v1`, so without this a caller passing a misspelled
  or removed input is accepted here and fails at run time in the consuming repo — the
  one place the failure is expensive.

## Why `ci-setup` lives here

A local action reference (`uses: ./.github/actions/ci-setup`) inside a reusable
workflow resolves against **this** repository, not the caller's. So the Android
bootstrap had to move here for the agent workflows to reach it. Binge's `ci.yml`
should switch from `./.github/actions/ci-setup` to
`ScottCooper92/binge-ci/.github/actions/ci-setup@v1` so there is exactly one copy
rather than two that drift.

## Before this can run

Per consuming repo:

1. Install both GitHub Apps (author, reviewer) on it.
2. Add `REVIEWER_APP_ID`, `REVIEWER_APP_PRIVATE_KEY`, `AUTHOR_APP_ID`,
   `AUTHOR_APP_PRIVATE_KEY`, `CLAUDE_CODE_OAUTH_TOKEN` as secrets, and
   `AUTHOR_BOT_ID` as a repository variable.
3. Create the `agent` label, and keep it maintainers-only. Applying it grants
   code execution with that repository's secrets in scope.
4. Write the governing docs the agents read from the default branch: a conventions
   document (`CLAUDE.md`), a `.ai/agents/pr-review-guide.md` and a
   `.ai/agents/ci-triage.md` that are about *that repo*. binge-integrations' have to be
   about protos and buf — not copies of Binge's, which are about Compose and a
   screenshot gate.
5. Only if the caller passes a self-hosted `runner`: register that runner against the
   repo. The default needs none.

Repo-wide:

- Resolve `bufbuild/buf-action@v1` to a SHA before any caller sets
  `setup_buf: true`. Every other action in these files is SHA-pinned because
  these jobs run an agent with Bash, Edit, Write and a contents:write token, and
  a mutable tag inside that boundary is the supply-chain hole the rest of the
  discipline closes.
- Tag `v1` once the remaining four workflows are re-derived and the first caller is
  green. Every caller references `@v1`.
