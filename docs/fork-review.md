# Fork review

An advisory, read-only review of a pull request from a fork. The five bots refuse fork PRs, and
that refusal stays. This is a separate, much smaller thing: one reusable workflow,
`fork-review.yml`, that reads a fork's diff and posts one comment.

It does not approve, request changes, merge, push, label, or run anything from the PR.
**A fork PR is never auto-merged, by this workflow or by any other here.** A merge is a
maintainer's decision.

## Why the bots refuse forks

The bots run an agent with a Claude token and a GitHub App key in scope. A fork PR is text an
attacker wrote: the diff, the title, the description, the branch name, the file names. Any of it
can be an instruction aimed at that agent. The same-repository guard in each workflow and caller is
what keeps that text away from the secrets. Nothing here weakens it.

Fork review lets the text through to an agent only when all of these hold:

- the agent holds a Claude token and nothing else: no GitHub write token, no shell, no network;
- it can read one directory of data and cannot write anywhere;
- a maintainer chose to run it on this commit.

## The design

Two stages, run by two workflows in the consumer, one reusable workflow behind both.

```
fork pushes ──▶ pull_request          fork-review-collect.yml     UNTRUSTED
                  └─ collect          read-only token, no secrets, no checkout
                       uploads  diff, file list, metadata, CI snapshot
                                          │
maintainer labels the PR `fork-review` ───┤  (then re-runs collect, if it already finished)
                                          ▼
              workflow_run          fork-review.yml             TRUSTED, default branch's copy
                  ├─ gate           no secrets, read-only
                  │    finds the PR itself, checks the label and who applied it,
                  │    opens the artifact as data, rebuilds every input from the API,
                  │    and requires the two to match
                  ├─ agent          Claude token, `contents: read`, no shell
                  │    reads the rebuilt inputs, writes text
                  └─ post           `pull-requests: write`, no other secret
                       posts one comment, removes the label
```

### The untrusted stage

`collect` runs on `pull_request`, so a fork's run gets GitHub's default token for a fork: read-only,
no secrets. It does not check anything out, so no PR code is ever on the runner. It reads the PR
through the API and writes `diff.patch`, `files.json`, `meta.json`, `ci.json` and `bound.json`.

It runs the fork's own copy of the caller workflow, so the fork controls everything it does and
uploads. That is why the stage after it believes none of it.

### The trusted stage

`workflow_run` always runs the caller as it is on the **default branch**, so the fork cannot edit it.
It is the only event here with that property, and everything with a secret hangs off it.

**`gate`** has no secrets and a read-only token.

1. It finds the PR from what GitHub says about the triggering run: head repository, branch and SHA.
   It does not use the artifact for this. `workflow_run.pull_requests` is empty for a fork, and the
   artifact is whatever the fork chose to upload.
2. It checks that the PR is open, that its head is still the commit the run was for, and that the
   head is in a different repository from the base.
3. It checks the opt-in (below). Without one it stops and says nothing.
4. Only then does it open the artifact, as four regular files of known names and bounded size, or
   not at all.
5. It derives the same inputs from the API and requires the artifact's `diff.patch`,
   `files.json` and `bound.json` to be byte-identical, and the artifact's PR number and head SHA to
   match. A mismatch means the untrusted stage was edited, or the PR changed since, and nothing is
   reviewed. The artifact is evidence and never authority.
6. It reads CI again for itself, because the collector's snapshot may have been taken before CI
   finished, and reads the review guide and conventions document from the default branch through
   the API, never from the PR.

What the agent reads is the API's copy. The artifact only proves the untrusted stage saw what the
trusted one sees.

**`agent`** holds the Claude token and a token with `contents: read` and `actions: read`. It cannot post.

- Tools: `Read`, `Grep` and `Glob`, allowed only under `./review-input/`. `Bash`, `Write`, `Edit`,
  `WebFetch`, `WebSearch` and subagents are disallowed, as are the places a credential would live.
- No skip-permissions flag. A tool outside the allowlist is refused, not asked about.
- The workspace is an empty repository holding only `review-input/`. No `.mcp.json`, no `.claude/`,
  no checkout.
- It answers in its final message; it has no tool to write a file with. The job screens that text
  for the Claude token and for common token shapes, caps it, and hands it on as an output.

**`post`** holds `pull-requests: write` and no other secret, and never ran the agent. It posts one
issue comment and removes the label. The agent's text is written to a file from an `env:` value,
defused (no `@` mentions, no HTML comments or active tags, no images), and appended. It is never part
of a command line.

### Hostile strings

The title, description, branch name, file names, comment text and the agent's own output are all
hostile. None is interpolated into a `run:` block, `GITHUB_ENV`, `GITHUB_OUTPUT` or
`GITHUB_STEP_SUMMARY`. They travel in `env:` values and in files, and are quoted when used. What
reaches an output is an integer, a 40-hex SHA, or a word the script chose. The one multi-line output,
the review, is written under a random delimiter that is checked absent from it.
`tools/test-fork-review.sh` fails the build on a `${{ }}` inside any `run:` block, a checkout,
a `pull_request_target`, a write scope beyond `pull-requests`, a skip-permissions flag, a
shell for the agent, or the Claude token in any job but `agent`.

### Bounds

The reviewer gets at most `max_diff_bytes` (default 200000) of diff and `max_files` (default 300)
files. The diff is cut at a file boundary and then at a line. A diff GitHub will not return at all
(over 20000 lines) reaches the reviewer as the file list alone. Each case is stated at the top of
the comment, with how much was read.

## The manual gate

A maintainer applies a label, `fork-review` by default (`label` input). It must exist in the
repository, and applying a label already needs triage access.

The gate does not trust that it was applied. It reads the PR's timeline and checks:

- **Who.** The person who applied it has `write`, `maintain` or `admin` on the repository.
- **When.** The label postdates the head's collector run, which GitHub creates when the head is
  pushed. A label applied to an earlier commit does not carry over to the next push.
- **Once.** The label is removed when the review is posted. Each head needs its own decision,
  and so does a second review of the same head.

If the collector run has already finished when the label goes on, re-run it. It keeps its creation
time, so the label stays later than it, and its completion starts the trusted stage again.

An outcome with no opt-in leaves no comment: one per push to every fork PR would be noise, and the
run's summary says what it did. Every outcome after an opt-in is on the PR: the review, or a short
note saying it did not run and why (a label from someone without write access, a stale label, a
failed collection, a mismatched artifact, a failed or timed-out agent).

**Why a label and not an Environment with required reviewers.** An Environment approves one run, which
is tighter. But a repository that forgets to configure its reviewers gets an environment with
none, and the job runs ungated. Nothing in a workflow can read that setting, so the failure would be
silent. The label is checked in code and fails closed. A consumer who wants both can protect the
secret with an environment of its own.

## What an injected agent could and could not do

Assume the diff talks the agent into anything.

It **could**:

- write a misleading review: call a bad change fine, or a good one bad. The comment says it is
  advisory, and a maintainer still reads the diff.
- put links, formatting or text of its choosing in one comment. Mentions, HTML comments, active tags
  and images are neutralised; links are not.
- spend its turns and its time, up to `max_turns` and `agent_timeout_minutes`.
- read anything its tool scope lets it read. That scope is one directory, and the places a credential
  lives are denied as well. If a scope were read more loosely than intended, the Claude token is the
  one secret in reach, so the answer is screened for it before it leaves the job.

It **could not**:

- run a command, fetch a URL, or write a file: those tools are disallowed.
- post, approve, request changes, merge, push, label or close: its job has no token for it.
- reach the Claude token from the posting job, or the posting token from its own.
- edit what governs it: the guide and conventions come from the default branch, and the workflow
  that runs it from the default branch's copy of the caller.

Not ruled out: the Claude token can be spent on a fork's diff a maintainer opted in. That is what
the label buys, and why a maintainer should read the PR before applying it.

## Repository settings to turn on

- **Actions, Fork pull request workflows: require approval for all outside collaborators.**
  Without it a first-time contributor's collect run starts on its own. It has no secrets,
  but it should not run unreviewed either.
- **Actions, Fork pull request workflows: do not send write tokens or secrets to fork PR workflows**,
  and leave the setting that does so off.
- **Create the label** the workflow is called with. Limit who has triage access, since that is
  who can apply it.
- **Do not add `pull_request_target` or `issue_comment` to either caller.** The first runs the fork's
  PR with secrets in scope. Neither is needed.
- **Hosted runners only.** The workflow uses `ubuntu-latest`. An agent that reads a fork's text
  should not run on a machine that outlives the job.
- **Do not turn on `auto_merge`** or any merge automation for fork PRs. Branch protection and
  CODEOWNERS apply as they do to any PR.
- **Keep the Claude token to this workflow.** It is the only secret the workflow reads, and only
  the `agent` job sees it.

## Callers

The workflow needs two thin callers in the consumer's `.github/workflows/`, because a workflow that
triggered on its own completion would trigger itself. Complete, checked copies are in
`callers/example/`. They pin `@v1`; a consumer pins the commit `v1` names, as for the bots.

`fork-review-collect.yml`, the untrusted stage. Its **name** is load-bearing.

```yaml
name: Fork review collect
on:
  pull_request:
    types: [opened, synchronize, reopened]
permissions:
  contents: read
  actions: read
  pull-requests: write   # read-only on a fork's run whatever is declared
jobs:
  collect:
    if: github.event.pull_request.head.repo.full_name != github.repository
    uses: owner/shared-ci/.github/workflows/fork-review.yml@v1
```

`fork-review.yml`, the trusted stage.

```yaml
name: Fork review
on:
  workflow_run:
    workflows: ["Fork review collect"]
    types: [completed]
permissions:
  contents: read
  actions: read
  pull-requests: write
jobs:
  review:
    if: >-
      github.event.workflow_run.event == 'pull_request' &&
      github.event.workflow_run.head_repository.full_name != github.repository
    uses: owner/shared-ci/.github/workflows/fork-review.yml@v1
    with:
      label: fork-review
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

A caller that does not hold `contents: read`, `actions: read` and `pull-requests: write` at the
top dies as `startup_failure`, with no log: see "Writing a caller" in the README.
`tools/check-callers.sh` checks the copies in `callers/example/`.

## What has not been proven

This was built without a real fork run. The first one should confirm:

- that the action's actor check admits the run with `allowed_non_write_users: '*'`;
- that `Read(./review-input/**)` style rules scope `Grep` and `Glob` as well as `Read`, and that
  the denied paths are refused;
- that a fork's `pull_request` run can read the PR, its files and its CI runs with the token it gets;
- the artifact download through the API, and the shape of the action's execution file.
