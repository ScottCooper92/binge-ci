# binge-ci

Shared CI and agent workflows for the Binge repositories.

Five GitHub Actions workflows run a review bot and three author bots across
[Binge](https://github.com/ScottCooper92), [binge-integrations](https://github.com/ScottCooper92/binge-integrations)
and [binge-seerr](https://github.com/ScottCooper92/binge-seerr). They live here once, and
each repo calls them with a ~30-line caller.

They used to be copied. That went the way copies go: by the time there were three, all
three were missing the same 23 fixes, and the original had grown 43% past the version they
shared. The comments in these files record what each fix was for, which is most of why
they are worth keeping in one place.

> **Status: nothing calls these yet.** See [MIGRATION.md](MIGRATION.md) for the order to
> land it in.

## The five workflows

| Workflow | What it does |
| --- | --- |
| `bot-review.yml` | Reviews a PR once CI goes green, and optionally squash-merges it. |
| `author-ci-fix.yml` | Makes one repair attempt when CI goes red, then stops rather than churning. |
| `author-comments.yml` | Answers review feedback — top-level comments, inline notes and reviews. |
| `author-conflicts.yml` | Finds PRs that conflict when the base moves, and resolves them. |
| `author-retarget.yml` | Catches a stacked PR up to its base so it starts moving again. |

All but the last run an agent. `author-retarget.yml` is plain git.

A PR opts in with the **`agent` label**, which is maintainers-only in every repo: applying
it grants code execution with that repository's secrets in scope.

## Using them

A caller owns the triggers — a reusable workflow cannot declare its own — and passes what
makes it that repo's:

```yaml
name: Bot review
on:
  workflow_run:
    workflows: ["CI"]
    types: [completed]

jobs:
  review:
    uses: ScottCooper92/binge-ci/.github/workflows/bot-review.yml@v1
    with:
      auto_merge: false
      gated_checks: ktlint or Android lint
    secrets:
      REVIEWER_APP_ID: ${{ secrets.REVIEWER_APP_ID }}
      REVIEWER_APP_PRIVATE_KEY: ${{ secrets.REVIEWER_APP_PRIVATE_KEY }}
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

Worked examples for two repos are in `callers/`. Every input is documented on the workflow
it belongs to.

**What is shared is the mechanism**: the trust boundary, the label gate, the fork guard,
the loop caps, the marker-comment dedup, and the "report a failed run rather than going
silent" step each one ends with.

**What is not shared is the rules**, which arrive as inputs — `gate_rules`,
`conflict_rules`, `verify_guidance`, `gated_checks`. Binge names its detekt baseline and
screenshot gate; binge-integrations names buf and proto field numbers. A rule that fits
both is usually too vague to bind either.

## Defaults are public-safe

Two of the three consumers are public, so the defaults are the strict setting and a caller
opts *out*. A repo that forgets to configure something gets the safe behaviour.

| Input | Default | Why |
| --- | --- | --- |
| `runner` | `["ubuntu-latest"]` | Ephemeral, so the `agent` label means code execution on a throwaway VM. |
| `auto_merge` | `false` | Bot merging should be a decision a caller made, not one it inherited. |
| `show_full_output` | `false` | The agent's log stream carries what it read and ran; public logs are world-readable. |
| `default_branch` | `main` | Binge is the only `master`. |

Binge's callers are not in `callers/`. They name that repo's self-hosted runner labels, and
this repository is public — a public staging area has no reason to carry infrastructure
detail about a private repo. They live on the `ci/binge-ci-callers` branch in Binge itself.

## Layout

```
.github/workflows/    The five reusable workflows, and this repo's own CI
.github/actions/      ci-setup (Android build bootstrap), governed-paths (see below)
callers/              Worked callers for the two public repos
tools/                The checks actionlint cannot do
```

**`governed-paths`** ships the script that undoes claude-code-action's rewrite of the files
that govern an agent — `CLAUDE.md`, `.claude` and friends. The action overwrites them with
the base branch's copy before it starts, because a PR head is untrusted; without the undo,
the author bots commit that rewrite as their own work and silently revert the PR. It lives
here so a PR cannot reach the guard that is about to refuse it.

Both actions live here rather than in the consuming repos because a local `uses: ./...`
inside a reusable workflow resolves against **this** repository, not the caller's.

## Its own gate

This repo ships no product code, so CI checks the two things that can be wrong with it:
the workflows (actionlint + shellcheck) and whether the callers still fit them
(`tools/check-callers.sh` — actionlint cannot see across a remote workflow reference, so
a misspelled input would otherwise fail at run time in the consuming repo).

## Writing a caller: the one thing that will bite you

**A caller must declare any permission the called workflow needs beyond `contents`.**

A reusable workflow cannot be granted more than its caller holds, and a caller with no
`permissions:` block gets the repository default — `contents: read`, with no `actions`.
`bot-review` and `author-ci-fix` both need `actions: read` for their CI-run lookup, so a
caller that omits it dies as `startup_failure`: no log, no annotation, no job, and nothing
on the PR beyond a red tick.

This is the one way a caller differs from the copy it replaces. An ordinary workflow
declaring `permissions: actions: read` simply gets it; a caller has to hold it first — which
is why the in-repo copies ran for months and the first caller could not start.

`tools/check-callers.sh` checks this now. Nothing else can: actionlint cannot see across a
remote reference, and the called workflow's own CI is not the caller.

## Versioning

Callers reference `@v1`, a moving alias. `v1.0.0` and friends are immutable — pin to one
if you want no surprises.
