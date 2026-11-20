# binge-ci

Shared CI and agent workflows for the Binge repositories.

Five GitHub Actions workflows run a review bot and four author bots across
[Binge](https://github.com/ScottCooper92), [binge-companions](https://github.com/ScottCooper92/binge-companions),
[binge-seerr](https://github.com/ScottCooper92/binge-seerr),
[binge-design-system](https://github.com/ScottCooper92/binge-design-system),
[binge-archive](https://github.com/ScottCooper92/binge-archive) and
[ephyra](https://github.com/ScottCooper92/ephyra). They live here
once, and each repo calls them with a ~30-line caller.

They used to be copied. That went the way copies go: by the time there were three, all
three were missing the same 23 fixes, and the original had grown 43% past the version they
shared. The comments in these files record what each fix was for, which is most of why
they are worth keeping in one place.

> **Status: Binge, binge-seerr, binge-companions, binge-design-system, binge-archive and ephyra call these.**
> What is not yet proven is every bot — see [MIGRATION.md](MIGRATION.md) for which have had a real run and which have only
> ever been skipped by a guard.

## The five workflows

| Workflow | What it does |
| --- | --- |
| `bot-review.yml` | Reviews a PR once CI goes green, and optionally merges it by the caller's `merge_method`. While CI on the default branch is red it does not merge, except a PR carrying the `fix-default-branch` label; a held PR is marked `merge-held` and merged when the default branch goes green. |
| `author-ci-fix.yml` | Makes one repair attempt per commit when CI goes red, at most two per human push, then stops rather than churning. While CI on the default branch is red it leaves PR branches alone, since they all inherit that failure, and opens one repair PR from the default branch instead (`repair_default_branch`). |
| `author-comments.yml` | Answers review feedback — top-level comments, inline notes and reviews. When a finding is only that the PR body ticks a check that did not pass, it un-ticks the box (or rewords the "Left to CI" line) and says so in its reply; it edits nothing else in the body. It reads every maintainer reply posted after a review point, and a point a maintainer has settled is left alone and answered as decided. It never narrows public visibility on a non-blocking or taste comment, and never because an API looks unused outside this repository, since consumers may be private. |
| `author-conflicts.yml` | Finds PRs that conflict when the base moves, and resolves them. |
| `author-retarget.yml` | Catches a stacked PR up to its base so it starts moving again. |

All but the last run an agent. `author-retarget.yml` is plain git.

A PR opts in with the **`agent` label**, which is maintainers-only in every repo: applying
it grants code execution with that repository's secrets in scope.

A PR that repairs a red default branch also carries **`fix-default-branch`**, and a merge held
while it is red carries **`merge-held`**. Each caller's repository needs both labels to exist;
their names are inputs.

## Using them

A caller owns the triggers — a reusable workflow cannot declare its own — and passes what
makes it that repo's:

```yaml
name: Bot review
run-name: >-
  ${{ github.event.workflow_run.pull_requests[0].number
        && format('#{0} · {1}', github.event.workflow_run.pull_requests[0].number, github.event.workflow_run.head_branch)
      || github.event.pull_request.number
        && format('#{0} · {1}', github.event.pull_request.number, github.event.pull_request.head.ref)
      || inputs.pr && format('#{0} · dispatched', inputs.pr)
      || github.event.workflow_run.head_branch
      || github.event.issue.number && format('#{0} · rebuttal', github.event.issue.number)
      || github.ref_name }}
on:
  workflow_run:
    workflows: ["CI"]
    types: [completed]
  pull_request:
    types: [labeled]      # a PR labelled after its CI already reported
  issue_comment:
    types: [created]      # a rebuttal comment from the author bot - see bot-review.yml
  workflow_dispatch:
    inputs:
      pr:
        description: PR number to review
        required: true

# The called workflow cannot hold more than the caller does - see "Writing a caller".
permissions:
  contents: read
  actions: read
  checks: write

jobs:
  review:
    uses: ScottCooper92/binge-ci/.github/workflows/bot-review.yml@v1
    with:
      dispatch_pr: ${{ inputs.pr }}
      auto_merge: false
      gated_checks: ktlint or Android lint
    secrets:
      REVIEWER_APP_ID: ${{ secrets.REVIEWER_APP_ID }}
      REVIEWER_APP_PRIVATE_KEY: ${{ secrets.REVIEWER_APP_PRIVATE_KEY }}
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

The worked callers under `callers/` are the complete versions, one per workflow. Two things a
consumer does that the sketch above leaves out: it pins the commit `v1` names rather than the
alias (see Versioning), and each bot job carries a fork guard in its `if:`. On an event that
names a head repository, that repository must be the caller's own. The workflows refuse fork PRs
themselves; the caller's guard keeps the check visible in the repository that holds the secrets.

Worked examples for the public repos are in `callers/`. Every input is documented on the workflow
it belongs to.

**What is shared is the mechanism**: the trust boundary, the label gate, the fork guard,
the loop caps, the marker-comment dedup, and the "report a failed run rather than going
silent" step each one ends with.

**What is not shared is the rules**, which arrive as inputs — `gate_rules`,
`conflict_rules`, `verify_guidance`, `gated_checks`. Binge names its detekt baseline and
screenshot gate; binge-companions names buf and proto field numbers. A rule that fits
both is usually too vague to bind either.

`author-comments` and `author-ci-fix` take an optional `build_cache_url`: a Gradle remote cache the
agent's builds read from. It is exported as the URL alone, with no credentials, so the build is
given no way to write to the cache. The consumer's Gradle settings must read `GRADLE_CACHE_URL` and
enable the remote cache from it. It needs a cache that serves anonymous reads and refuses anonymous writes, and a self-hosted
runner that can reach it.

The one exception is the list of suppression files. The three author workflows that take
`gate_rules` or `conflict_rules` also take `suppression_files`: newline-separated globs, by
default `*-allowlist.txt` and `detekt-baseline.xml`. A caller cannot compute an input, so the
job expands the globs itself, against the PR's tree and the default branch's, and adds the files
it finds to the agent's prompt as files it may not edit. Adding an allowlist that matches a glob
needs no caller change. The rules inputs still apply alongside it. Pass an empty string to turn
the derived list off.

## Fork PRs

The bots refuse them, and that guard is deliberate. `fork-review.yml` is a separate, far more
restricted path: a read-only agent reads a fork's diff and posts one advisory comment, after a
maintainer has labelled that commit. It never approves or merges. The design, the threat model,
what an injected agent could and could not do, and the repository settings it needs are in
[docs/fork-review.md](docs/fork-review.md). The callers are the two files in `callers/example/`.

## Seeing what the bots did

A `workflow_run` run is not associated with the pull request that caused it. It is attributed
to the default branch, so it never appears in the PR's checks list, `gh pr checks` never
mentions it, and every run in the Actions list carries the same branch and the same title.
Two things narrow that gap, and neither replaces the comments a bot posts when it needs a
human.

**`run-name` in the caller** puts the PR number and head branch in the Actions list. It has
to live in the caller — a reusable workflow cannot name its caller's run — and it is
evaluated before any job, so it reads the event rather than the number the called workflow
later resolves. Every caller in `callers/` shows the shape for its own triggers.

**`pr-check-run`** posts a check run against the PR's head commit, which is how `bot-review`
appears on the PR itself: a check named *Bot review*, linking to the run, saying whether the
commit was approved, had changes requested, or the run failed. A check run is addressed by
SHA, so it lands on the PR even though the run does not.

> **Prerequisite: the reviewer GitHub App needs `checks: write`**, granted in the App's
> settings, not here. Until the grant is in place the step warns and the bots carry on — it
> reports, it does not gate. **And every `bot-review` caller declares `checks: write` too**,
> for the one report the app cannot make: when the first job fails before the app's token
> exists (a GitHub outage minting it), a job posting with the workflow's own `GITHUB_TOKEN`
> leaves a neutral *Bot review (run failed)* check on the head, under a name of its own
> because a check run can only be updated by the app that created it. A caller that misses
> that permission dies as `startup_failure` with no log — the trap described below.

> **Prerequisite: the author GitHub App needs contents and pull requests**, read and write, and
> workflows for a fix that touches one. The author workflows mint a second, read-only token for
> the agent from the same `AUTHOR_APP_*` secrets, asking for `contents` and `pull-requests` only.
> A mint can only narrow the installation's grant, so an author app without either fails there and
> the job stops before its agent runs. `tools/check-token-permissions.sh` holds every mint to the
> grant it records, so a mint that asks for more fails here first.

The action only ever posts an **already-completed** check, and `bot-review` posts one at the
start of a review as well as at the end. Both are the same constraint: a queued or
in-progress check holds `mergeStateStatus` at `UNSTABLE`, and the merge gate holds on
anything that is not `CLEAN`, so a reviewer that announced itself the obvious way would hold
its own merge on every PR — and a `failure` left by a crashed run would hold the next attempt
at the same commit. Posting a completed check at the start clears the predecessor's.

## Defaults are public-safe

Five of the six consumers are public, so the defaults are the strict setting and a caller
opts *out*. A repo that forgets to configure something gets the safe behaviour.

| Input | Default | Why |
| --- | --- | --- |
| `runner` | `["ubuntu-latest"]` | Ephemeral, so the `agent` label means code execution on a throwaway VM. Self-hosted needs `git`, `gh` and `jq` on PATH. |
| `auto_merge` | `false` | Bot merging should be a decision a caller made, not one it inherited. |
| `merge_unbuilt` | `false` | With `auto_merge` and `unbuilt_paths`, lets a clean review merge a PR CI never builds: one whose every changed path, both sides of a rename included, is in `unbuilt_paths`. Off, such a PR is reviewed and then waits for a human. The diff is checked again at merge time, a change under `.github/workflows/`, or to a path that governs the agents, is never merged: the governed list with `governed_extra_paths`, the review guide and its directory (`review_guide_path`), and the conventions file (`conventions_path`), and the push must be datable from the repository's activity log. A required status check that CI never reports still blocks the merge, so a caller whose branch protection requires its CI check has nothing to gain. |
| `max_rebuttals` | `1` | How many times the author bot's reply to a `CHANGES_REQUESTED` verdict re-opens the review of an unchanged head. Past it the review stays shut, one comment says a human has to decide, and the verdict stands. `0` never reconsiders. A new push is a new head with a new count, and so is a dismissed review: it no longer pins the head, so running the review again reviews it afresh (a dismissal alone starts no run). Before this input a head was reviewed again on every reply. |
| `merge_method` | `squash` | What this workflow has always done, and it keeps a linear history. A caller landing **stacked** PRs passes `merge`: squash and rebase rewrite the parent's commits, so every child is left holding commits absent from the base and needs a hand-resolved merge. The repository must allow the method too. |
| `show_full_output` | `false` | The agent's log stream carries what it read and ran; public logs are world-readable. |
| `default_branch` | `main` | Binge is the only `master`. |
| `model` | `claude-opus-5-5` (`bot-review`), `claude-sonnet-5-5` (`author-ci-fix`, `author-comments`, `author-conflicts`) | The agent model is pinned once per role here, so a model change is one edit and one release. A caller can pass another value, and an empty string omits `--model` to use the action's own default. |

Binge's callers are not in `callers/`. They name that repo's self-hosted runner labels, and
this repository is public — a public staging area has no reason to carry infrastructure
detail about a private repo. They live in Binge's own `.github/workflows/`.

### Re-recording screenshot frames

By default a failing screenshot test is a stop: re-recording the reference frames turns CI green on
whatever rendered. `author-ci-fix.yml` can be allowed to do it for the screens a PR itself changed. Set
`rerecord_screenshots: true` on the caller. It is off by default, and nothing changes without it.

`author-ci-fix.yml` makes no attempt while a `record-screenshots` run is queued or in progress on the branch. The conflict
bot dispatches one after it takes the default branch's frames, and a fix beside it would record the same classes and
collide on the push. It says so once on the PR. If the recording commits frames, CI runs again and that head gets its
own attempt; if it commits nothing, re-running CI on the PR gets the attempt back. A failed lookup of the runs changes
nothing.

- **The gate.** The agent re-records only when nothing else is red, there are at most 40 failing frames,
  and every failing frame is one of three cases. It renders a component whose source the PR changed.
  Or it is a new frame: its reference image does not exist, and the test function or preview that renders it
  was added or changed in this PR's diff. Or the PR moves a submodule pin, the frame's screen did not
  need the PR's own code to change because what it shows changed with the new pin (a component, a theme
  or a token in `git log -p old..new`), and the PR body says `frames from the <submodule> bump`. How large
  the difference is does not matter when the screen is the PR's own: an intended redesign moves most of
  its pixels. A frame outside the gate stops the run: one the PR did not touch on a PR with no pin move
  or no such sentence, a missing reference whose test this PR did not add, and anything that is not a
  difference, an out-of-memory failure or a render or compose error.
- **What it changes.** Only the reference PNGs of the failing frames, scoped to those test classes. It
  runs the update task and then the validate task, and looks at the old and new image of each frame.
- **The record.** After the push, the comment on the PR lists every re-recorded frame with its before (the
  frame at the merge base with the PR's base branch) and after (the frame at the pushed commit) as
  images, and the difference the agent reported. The workflow builds the list from the commit's own
  diff, so the agent cannot add or hide a frame. It says how many frames the commit adds (expected only
  for a test the PR added) or deletes (never expected), and which submodule pins the PR moves. The
  comment carries `<!-- ci-fix-rerecord:<sha> -->`. The images are links to the files on GitHub, so
  they show for a viewer with access to the repository.
- **The review.** `bot-review.yml` sees the comment, looks at each frame and judges it against what the
  PR says it changes. A frame that differs somewhere the change does not explain is a finding. A pin-bump
  frame is explained only when the PR body says `frames from the <submodule> bump` and the frame shows
  what the pin changed, and a new frame only when the PR added the test that renders it. The
  rules for this are in the workflow's own prompt, so a consumer's review guide needs no change: the
  guide is the consumer's own file, and a rule kept there would be missing for every other repository.
- **The consumer's half.** The caller's `gate_rules` and the triage table of its
  `.ai/agents/ci-triage.md` must stop forbidding the re-record, or they win and the agent stops. A row
  that fits:

  | A screenshot test fails | The rendering changed | If `rerecord_screenshots` is on and every failing frame is a screen this PR changed, re-record only those frames, as the prompt says. Otherwise stop and name the frames. Never re-record on a render error or an out-of-memory failure |

  Drop "Do not touch any screenshot baseline PNG, and never run the update task" from `gate_rules`.

### Recording screenshots on a runner

A cloud worker cannot build an app whose submodules are private, so it cannot record a new or changed screenshot
frame. `record-screenshots.yml` does it on a CI runner, for a maintainer. The caller (`callers/example/record-screenshots.yml`)
is a `workflow_dispatch` with two inputs: the branch, and a Gradle `--tests` filter such as `com.example.home.*ScreenshotTest`.

- **Who can start it.** Only a person with write access: the dispatch needs it, and the workflow checks again that the
  event is a dispatch, the sender is a user and not a bot, and the user's permission is write or better. No bot starts it
  and no pull request can. It refuses the default branch and an unsafe filter (letters, digits and `_ . * $ ,` only).
- **What it does.** It checks out the branch, fetches every submodule at the pin the branch records, compiles the
  screenshot sources, stops the daemon so the render gets a JVM of its own, and runs the record task with one `--tests`
  per filter. Then it commits the changed PNGs, with a message naming the filter, and pushes the branch.
- **What it will not do.** It stages only PNG files. Any other file the run changed, tracked or new, fails the run and is
  listed. The push is never forced, so a branch that moved under the run is a rejected push, not a lost commit. The
  push is made with the author app's installation token, named in the step and not left to the checkout's persisted
  credential, so CI starts on the new commit like on any push. A push made with `GITHUB_TOKEN` starts no workflow, which
  would leave the pull request's required check missing; the workflow does not dispatch CI as a fallback.
- **A bot that may start it.** The `trusted_dispatcher` input (empty by default) names one bot login, such as
  `binge-pr-author[bot]`. A dispatch from exactly that login is accepted; its permission is not read, since an app is
  not a collaborator. Every other check still applies to it, and any other bot is still refused.

#### Screenshot-only merge conflicts

When the default branch moves and a PR conflicts only in reference frames (`**/screenshotTest*/reference/**/*.png`,
each changed or added on both sides), `author-conflicts.yml` does not ask the agent to pick between two images. It takes
the default branch's copy of each frame, commits the merge, and pushes it with the author app's token, so CI starts. It
then dispatches the consumer's `record-screenshots.yml` on the branch, with exactly the affected classes as the `tests`
filter (a class is the directory above a frame, under `reference/<package path>/`), and posts one comment naming the
frames it took and the recording it started. Then it stops.

- **What keeps today's behaviour.** A conflict in any other path (a source file, a non-reference PNG), a frame one side
  deleted, a governed path, or a repository with no `record-screenshots.yml` is left to the agent and its usual bail.
  The workflow is looked up before anything is pushed. The lookup needs the app to read Actions, so on an installation
  without the permission it fails and the conflict goes to the agent, as before.
- **What the consumer has to set up.** The caller of `record-screenshots.yml` passes `trusted_dispatcher` set to the
  author bot's login, or the recording refuses the bot's dispatch. The author app's installation needs the Actions
  permission at write, which a maintainer grants in the app's settings; the token mint asks for no narrower set, so it
  carries whatever the installation grants. With the permission but without `trusted_dispatcher`, the merge lands and the comment says the recording could
  not be started and which classes to record.
- **What it says.** The step summary lists the frames. The pull request for the branch gets one comment saying what
  happened: recorded, nothing changed, a refusal or a failure, with the run's link.
- **The caller grants** `contents: read` and `pull-requests: write`, and passes `AUTHOR_APP_ID` and
  `AUTHOR_APP_PRIVATE_KEY`, and `REVIEWER_APP_ID` and `REVIEWER_APP_PRIVATE_KEY` when `private_submodules` is set. The
  tasks default to the `:app` module; a multi-module app names its own in `compile_tasks` and `record_tasks`.

### A runner-local Claude Code cache

Each agent job installs Claude Code, and Bun for the action's own scripts, from the network: several
hundred MB a job. On a self-hosted runner with a slow link that is slow, and a job that cannot finish the
download posts no verdict. A runner can keep one install instead. Set the environment variable
`BINGE_CI_CLAUDE_CODE_CACHE` on the runner (not in a workflow) to an absolute directory path, and every agent
job there reuses what is in it. Unset or empty, nothing changes: the action installs as always.

- The versions come from the pinned `claude-code-action`, so a bump of that pin installs the new version into the
  directory on first use. Each version is a directory, `claude-<version>` and `bun-<version>`, holding the
  executable and a `sha256` file. The current version and the one other used most recently are kept.
- The install is built in a temporary directory inside the cache and renamed into place, so a killed job leaves
  no half-installed version, and a lock makes jobs that start together share one download.
- Every use checks the executable against the checksum recorded at install. On a mismatch the version is deleted
  and that job installs it as always, so the next job installs it afresh. If anything else about the cache fails,
  the job still runs: it just installs as always.
- The step is capped at 10 minutes (each download at 8, and a wait for another job's install at 8) and is allowed to
  fail. The first job per version on a runner can spend those 10 minutes, so the default `timeout_minutes` of each
  agent workflow includes them (and a caller that passes its own `timeout_minutes` and sets the variable should add
  10). A download that does not fit is left to the action's own install, with no retry here.
- Put the directory on a volume that outlives the runner's container, or each new container starts cold.
- Use it on a single-tenant runner only. The directory outlives each job, and every later job on the runner runs
  what is in it, so an agent job that can write to it can change what later jobs run. The installed files are
  read-only and checked against the recorded checksum, which catches corruption and not a deliberate change by
  the user the runner runs as, who could change the checksum too. `fork-review.yml` never uses it.
- The agent jobs' network limits (`max-time = 120` for curl) are set after this step, so they do not cut the
  download short. They do apply to the action's own install when the cache is off.

## Layout

```
.github/workflows/    The five bot workflows, the shared CI ones (submodule-pins,
                      consumer-check, device-smoke, actions-storage-sweep, upstream-watch,
                      submodule-bump), fork-review,
                      and this repo's own CI
.github/actions/      ci-setup (Android build bootstrap), governed-paths,
                      suppression-files, pr-check-run,
                      restore-avd-cache / save-avd-cache, robolectric-cache,
                      nightly-report,
                      agent-claude-cache (every agent job uses it),
                      agent-network-limits and agent-tool-calls (every agent
                      job uses both), shard-screenshots, changed-files, pin-only, upstream-watch, submodule-bump and
                      actionlint (all below)
callers/              Worked callers for the public repos
                      and a generic pair for fork-review in example/
docs/                 fork-review.md
gradle-plugins/       The shared Gradle gates, as an included build (below)
tools/                The checks actionlint cannot do
```

**`governed-paths`** ships the script that undoes claude-code-action's rewrite of the files
that govern an agent — `CLAUDE.md`, `.claude` and friends. The action overwrites them with
the base branch's copy before it starts, because a PR head is untrusted; without the undo,
the author bots commit that rewrite as their own work and silently revert the PR. It lives
here so a PR cannot reach the guard that is about to refuse it. The action only rewrites on
an entity event (a comment, a review), and from the PR's base branch rather than the default
one; so the two `workflow_run`-and-schedule bots, `author-ci-fix` and `author-conflicts`,
perform the rewrite themselves with the script's `--rewrite` mode before their agent starts,
and every author bot undoes it against the PR's base. Without that, an agent run on those triggers
reads the PR head's own `CLAUDE.md` live, and the guard is not in force. `bot-review` runs the
same `--rewrite`, from the default branch, before its reviewer starts. It runs on `workflow_run`
and dispatch too, and without the rewrite a PR's own `CLAUDE.md` would join the rules it is
judged by. The reviewer commits nothing, so it needs no undo. It takes `governed_extra_paths`
as the author workflows do, so a consumer's extra governed paths are rewritten for the
reviewer too.

**`suppression-files`** expands a caller's `suppression_files` globs against the checkout and
the default branch, and outputs the prompt block that tells an agent not to edit what they
match. The three author workflows that take `suppression_files` share it, each passing its own
`lead` sentence.

All the actions live here rather than in the consuming repos so a PR cannot edit the
guard that is about to refuse it, and so the public repos get one they never had.

**`robolectric-cache` and `robolectric-cache-save`** keep Robolectric's `android-all` jars between runs on a
GitHub-hosted runner. Robolectric downloads them from Maven Central itself, into `~/.m2/repository/org/robolectric`,
outside Gradle's cache, and a rate limit (HTTP 429) there fails every unit test with `initializationError`.

- `robolectric-cache` only restores. It reads the Robolectric version(s) the build declares from the version catalog and
  the Gradle build files, and restores the newest entry for them, falling back to the newest of any version, so a new
  version starts from the old jars. A build that declares none, and a self-hosted runner, restore nothing. It outputs
  `versions` and `matched-key`. Its optional `jars` input (one `<artifact>:<version>` per line, empty by default)
  downloads named jars first with a retry and backoff, and a failed download is a warning, since Robolectric then tries
  itself.
- `robolectric-cache-save` runs after the unit tests, in the one job that writes. It saves the directory under
  `robolectric-<os>-<versions>-<hash of the jar files present>`. A run that downloaded one more jar, such as a new SDK
  level under the same Robolectric version, saves a new entry holding all of them, and a run that downloaded nothing
  new, or whose restored entry already matches, saves nothing. The restore's primary key is the bare prefix, which no
  save names, so an older entry never hides a newer one.
- The Android app CI workflow restores in its tests and screenshots jobs, taking the list from `robolectric_jars`, and
  its tests job saves, on the default branch after a green run. The screenshots jobs never save, since they never fill
  the directory. `ci-setup` restores too, taking `robolectric-jars`, and outputs `robolectric-versions` and
  `robolectric-matched-key`. It has no step after the tests, so a job that wants the cache filled adds
  `robolectric-cache-save` after its tests, passing those two. No restore step ever saves, so an agent's job and a pull
  request's branch cannot write an entry that other jobs restore.
- A jar the build needs that no run has downloaded yet is fetched once, and then it is in the entry. A hash of the files
  present is not known before the run, so the first run after a new SDK level still downloads it.

**`restore-avd-cache` and `save-avd-cache`** cache the Gradle Managed Device's AVD, its system
image and the emulator package for an emulator lane. The caller passes `device`, `api-level`,
`system-image-source` and its `default-branch`, and gates the save to a push to that branch with
its own `if:`. The SDK root is an input, `android-sdk-root`; left empty it is resolved from
`$ANDROID_SDK_ROOT`, then `$ANDROID_HOME`, so a caller without `android-actions/setup-android`
works too. The save step deletes the old entry first, so it needs a token with `actions: write`
(see "Writing a caller").

They are referenced by **full repo ref at an exact patch tag**, never `uses: ./`, from a
reusable workflow or another action. There a local action path resolves against the
**caller's** workspace, where these directories do not exist. `ci.yml` is the exception: it
runs only in this repository, so it uses the actionlint action by `./`, at the PR's own head.
The tag is immutable rather than `v1`, so a caller pinning `@v1.0.N` gets the actions that shipped with it; `uses:` takes no expression, so
`tools/check-internal-refs.sh` is what keeps the five in step.

## The shared CI steps

Not every repeated step is a bot. Ordinary CI pieces were pasted between the repositories and
drifted a word at a time, so they live here too:

| Piece | Kind | What it does |
| --- | --- | --- |
| `fork-review.yml` | reusable workflow | An advisory, read-only review of a fork PR, after a maintainer labels it. Two callers, one for the untrusted `pull_request` stage and one for the trusted `workflow_run` stage, both in `callers/example/`; each needs `contents: read`, `actions: read` and `pull-requests: write`. See [docs/fork-review.md](docs/fork-review.md). |
| `submodule-pins.yml` | reusable workflow | Fails a PR whose submodule pins a commit its own repository has not merged, or moves a pin to a commit that does not descend from the base branch's pin, unless the PR carries `hold`. It reads each submodule's own remote, so it takes no list of paths. Call it as a job of the required workflow, and grant `pull-requests: read`. |
| `consumer-check.yml` | reusable workflow | Compiles a consumer against the PR's head, swapping it in for the consumer's pin. It finds that submodule by URL in the consumer's `.gitmodules`. Informational: give it a workflow of its own, not named `CI`. |
| `android-app-ci.yml` | reusable workflow | The CI of an Android app: a `changes` job that says which jobs a diff can affect, then the Gradle `checks`, the unit `tests`, the screenshot validation in `screenshot_shards` shards and the release build as jobs of their own, and a `result` job that says whether each did what `changes` asked for. Pass `release_inputs`, and the modules and tasks the app needs; `runner` is a JSON array, so a move to a self-hosted runner is one input. Grant `contents: read` and `actions: read`. The required check named `build` is a job of the caller's own: see "App CI" below and `callers/example/android-app-ci.yml`. |
| `record-screenshots.yml` | reusable workflow | A maintainer runs it to record screenshot frames on a CI runner, for an app whose submodules a cloud worker cannot fetch: `updateDebugScreenshotTest --tests <filter>` on a branch with every submodule at its pin, then one commit of the changed PNGs. Dispatch only, for a person with write access, never on the default branch, no non-PNG file, no forced push. Grant `contents: read` and `pull-requests: write`; pass the author app secrets (and the reviewer app's when `private_submodules` is set). See "Recording screenshots on a runner" below. |
| `device-smoke.yml` | reusable workflow | Runs instrumentation tests on a Gradle Managed Device, on a hosted runner. Pass the device, its API level and system image, the default branch and the test `tasks`. Grant `actions: write`, for the AVD cache. See below. |
| `actions-storage-sweep.yml` | reusable workflow | Deletes the repository's Actions caches not accessed for `max_age_days` (default 3) and artifacts older than that. Give it a weekly schedule of its own. Grant `actions: write`. `dry_run` logs what it would delete. `keep_cache_key_prefixes` (default `gmd-avd-`) lists cache keys to leave alone. `cache_max_age_days` (default 0, meaning `max_age_days`) ages caches separately from artifacts. `runner` (JSON array, default `["ubuntu-latest"]`) picks where it runs, for a repository that keeps its jobs off hosted runners. It deletes artifacts by age whatever retention their uploader chose, so set `max_age_days` to the longest retention the repository keeps on purpose. |
| `upstream-watch.yml` | reusable workflow | Opens one issue for the newest new stable release of each server the app talks to (Jellyfin, Seerr, Overseerr), with a compatibility checklist. See "Upstream watch" below. Grant `issues: write`. |
| `submodule-bump.yml` | reusable workflow | Moves one submodule's pin to the head of its default branch, in a PR of its own that carries the `agent` label, and keeps that PR current on later runs. Does nothing while the pin is at the head. Give it a weekly schedule. Grant `contents: read`, and pass `AUTHOR_APP_ID` and `AUTHOR_APP_PRIVATE_KEY`. See "Submodule bump" below. |
| `nightly-report` | composite action | Keeps one issue open while a run is red and closes it on the next green one. Pass the gate job's result, a title of its own, and a note on what to suspect. Optional `labels` tag the issue and narrow the lookup for the open one; optional `assignees` assign it; optional `run-kind` is what the issue's text calls the run (default `scheduled`; when the job also runs on a push, pass a name that fits both, such as `main`, since the text reads "The <run-kind> run failed"). The job needs `issues: write`. |
| `agent-claude-cache` | composite action | Reuses one Claude Code and Bun install across jobs on a self-hosted runner that sets `BINGE_CI_CLAUDE_CODE_CACHE`; unset, it does nothing. Takes `action_ref`, the `claude-code-action` pin, and outputs `claude_path` and `bun_path`. The step that calls it carries `timeout-minutes: 10`, `continue-on-error: true` and the agent step's `if:`. Every agent job calls it, at this repository's release tag, with `action_ref` set to its `claude-code-action` pin; `tools/test-claude-code-cache.sh` holds each call to that. See "A runner-local Claude Code cache". |
| `shard-screenshots` | composite action | Splits a module's screenshot test classes into shards and prints the `--tests` filters for one, so each shard of a matrix renders in a JVM of its own. Weighs a class by its reference PNGs and places the heaviest first, so the split is stable. Fails on a top-level `@PreviewTest`, on one in a file with no `*ScreenshotTest` class, on reference PNGs no class owns and on a reference directory that does not exist, since each would leave a frame nothing validates or hide that. A second class in a file that has a `*ScreenshotTest` class is not checked. Its `empty` output is `true` for a shard with no class: skip Gradle then, because a validate task given no filter runs everything. Run it after `actions/checkout`, in the job of one matrix shard. |
| `changed-files` | composite action | Decides which jobs of a pull request's CI run a diff can affect, and prints `product`, `screens` and `release`. A job is skipped only when every changed path is in a closed set the caller lists as an input (`product_none`, `no_frames`), and the release build runs only for a path in the allow-list `release_inputs`, which is required. Every output is `true` on an event that is not a pull request, on an empty diff, and whenever no baseline or diff can be read. The baseline is the last commit of the pull request that a whole run passed on (the job named by `green_job` in `workflow` succeeded) when it is an ancestor of the head, else the merge base. Run it after `actions/checkout` with `fetch-depth: 0`; the job needs `contents: read` and `actions: read`. Patterns are bash globs, one per line, whitespace around one (and after a `!`) is ignored, a `*` crosses `/`, the first match decides, and a `!` carves a path out of the set. A path in both `product_none` and `release_inputs` does not reach the release build: `product_none` wins. |
| `pin-only` | composite action | Says whether a pull request changes nothing but its binge-ci pins, so a release's pin update can merge without a person reading its workflow edits. `pin_only` is `true` only when every change is a `uses: ScottCooper92/binge-ci/...@<sha> # v1.0.N` line (the same line, with a new commit and tag comment) or the `binge-ci` gitlink moving, every new commit is one commit, and that commit is the one the tag `v1.0.N` names in binge-ci's own repository, is on its `main` and descends from every pin it replaces (a move back to an older release is not pin-only). A workflow edit beside the pin, a pin to `v1` or to an untagged commit, an added or deleted line, any other file, or anything it cannot read is `false`; it never fails on a change that is not pin-only. Takes `base` and `head`; run it after `actions/checkout` with `fetch-depth: 0` and no submodules. Not yet called by a workflow: the reusable check that posts it as a status follows the release that holds it. |
| `actionlint` | composite action | Runs a pinned, checksum-verified actionlint over the caller's workflows, with shellcheck at warning severity. Run it after `actions/checkout`. |

The worked callers under `callers/` show each workflow in use, and `tools/check-callers.sh` checks
them like the bot callers.

### Private submodules

A checkout that fetches submodules cannot read a second private repository with the token it has: the
default `GITHUB_TOKEN` and the author app's token both reach the calling repository only. Every
workflow that checks out with submodules takes an optional input for this, `private_submodules`: the
names of the private repositories, comma- or newline-separated, under the caller's owner. Empty is the
default and changes nothing.

```yaml
with:
  private_submodules: shared-lib, other-lib
secrets: inherit
```

- It applies to `bot-review.yml`, `author-ci-fix.yml`, `author-comments.yml`, `author-conflicts.yml`,
  `author-retarget.yml`, `submodule-pins.yml`, `submodule-bump.yml`, `device-smoke.yml`, `android-app-ci.yml`, `record-screenshots.yml` and `consumer-check.yml`. In
  `consumer-check.yml` it covers the caller's own checkout, not the consumer's other submodules; see
  "Private consumers" below for those.
- The GitHub App has to be installed on every private repository listed, with read access to contents.
- A token is scoped by `repositories:`, which replaces the default of the caller alone. The read-only
  workflows list the caller as well as the private repositories, because their checkout of the caller
  uses the same token; a hand-written mint has to do the same. The author bots' read token lists the
  private repositories only, since their write token fetches the caller.
- The read-only workflows (`bot-review.yml`, `submodule-pins.yml`, `device-smoke.yml`,
  `android-app-ci.yml`, `consumer-check.yml`) mint a separate token with `permission-contents: read` for the checkout. The
  four that have no app secret today take `REVIEWER_APP_ID` and `REVIEWER_APP_PRIVATE_KEY` as optional
  secrets, needed only when the input is set. Pass them, or use `secrets: inherit`.
- The author bots and `submodule-bump.yml` check out and push with their app token, which reaches the
  calling repository alone with or without the input. For the listed repositories they mint a second
  token from the same app with `permission-contents: read` and fetch the submodules with that, so a run
  cannot write to a private submodule's repository. The read token lives in the environment of the
  fetch and is never written to a git config, so an agent cannot fetch more of a private submodule than
  the checkout did. `tools/check-token-permissions.sh` fails if a write mint in these workflows names
  `private_submodules`.
- `submodule-pins.yml` reads each private submodule's default branch with the same token, to check
  that a pin is an ancestor of it.

### Private consumers

`consumer-check.yml` compiles a consumer, and the consumer's own checkout needs a token when the consumer
is private or includes private submodules. Set `private_consumer: true` and pass the two reviewer app
secrets:

```yaml
with:
  consumer: owner/consumer
  private_consumer: true
secrets:
  REVIEWER_APP_ID: ${{ secrets.REVIEWER_APP_ID }}
  REVIEWER_APP_PRIVATE_KEY: ${{ secrets.REVIEWER_APP_PRIVATE_KEY }}
```

- The workflow mints a read-only token (`permission-contents: read`) for the caller's owner, with no
  `repositories:` list, so it reaches every repository the app is installed on. No private name appears
  here or in the caller.
- The app has to be installed on the consumer and on each of its private submodules, with read access to
  contents. A repository it is not installed on fails to clone.
- The token is used for the consumer's checkout and for its submodule fetch. Submodule URLs must be
  https. It is never printed or written to the consumer's git config.
- `private_submodules` is separate: it covers the caller's own checkout. Set both when both apply.
- Empty or false changes nothing.

### Submodule bump

`submodule-bump.yml` moves one submodule's pin to the head of that submodule's default branch. Call it
weekly and by hand, once per submodule. `callers/example/submodule-bump.yml` is the worked caller.

Inputs: `submodule_path` (required), `branch`, `private_submodules`, `agent_label`, `dry_run`, `runner`,
`timeout_minutes`. Secrets: `AUTHOR_APP_ID` and `AUTHOR_APP_PRIVATE_KEY`. The caller grants
`contents: read`: the app token does every write. Outputs: `status` and `pull_request`.

```yaml
on:
  schedule:
    - cron: '23 5 * * 1'
permissions:
  contents: read
jobs:
  bump:
    uses: ScottCooper92/binge-ci/.github/workflows/submodule-bump.yml@v1
    with:
      submodule_path: libs/shared
    secrets:
      AUTHOR_APP_ID: ${{ secrets.AUTHOR_APP_ID }}
      AUTHOR_APP_PRIVATE_KEY: ${{ secrets.AUTHOR_APP_PRIVATE_KEY }}
```

What a run does:

- **Pin at the head:** nothing. `status` is `current`.
- **Pin behind the head:** it opens a PR from `submodule-bump/<path>` whose one commit changes only the
  pin. The body lists the commits in between as short sha and subject, and quotes what the submodule's
  `docs/migrations.md` gained in that range. A submodule without that file, or a range that added
  nothing to it, gets no such section. Both lists are quoted as code, so an `@mention` in a commit
  subject notifies nobody. The PR carries `agent_label` (default `agent`), so the consumer's bots act on it.
- **A PR is already open:** a later run moves it to the new head and edits its title and body. If every
  commit on the branch is the workflow's own, the branch is rebuilt to the single commit. If someone
  else pushed to it, the new pin commit goes on top and nothing of theirs is overwritten. That holds for
  a branch whose PR was closed and not deleted, too. A PR with a
  merge conflict is left to the conflict bot.
- **A pin that is not behind the branch** (held on an unmerged branch, or ahead of it) is never moved.
  `status` is `skipped`.
- **A failure in the bump step** with a PR open comments on it, once per head. An earlier step (token, checkout) fails the run with no comment. A failed scheduled run notifies the
  repository.

It pushes and opens the PR as the author app, not `GITHUB_TOKEN`, because a PR opened with that token
starts no workflow run and nothing would check it. For a private submodule, name it in
`private_submodules`, as in "Private submodules" above; the app then needs read access to it. The
submodule is fetched with a second, read-only token, and the token that pushes reaches the calling
repository alone. When the caller is public,
the PR for a listed submodule carries short shas only: no commit subject and no migration text is quoted,
because the PR is world-readable. The workflow reads whether the caller is private with the app token,
and treats the caller as public when it cannot tell. Name the submodule by its repository name, as its
remote spells it. Run it with `dry_run` on first.

### The emulator lane

`device-smoke.yml` is the whole lane, so a consumer writes only its triggers and one `uses:`. It
holds what each consumer learned separately:

- **KVM.** A hosted Linux runner has it, but `/dev/kvm` is root-owned. A udev rule makes it
  writable, and a check fails the job in seconds if it is still not, rather than at the timeout.
- **Disk.** A stock runner has too little free for an AVD's userdata partition. The lane deletes
  preinstalled toolchains first, on a GitHub-hosted runner only, and logs `df` either side.
- **A readable boot failure.** The device setup task runs on its own, at `--info --stacktrace`
  with `showKernelLogging`. Without both switches a failed boot reports an empty error list.
- **The AVD cache**, through `restore-avd-cache` and `save-avd-cache`. It saves only on a push to
  the default branch, and only once setup succeeded.
- **A run that ran nothing.** A managed-device run whose instrumentation crashes before it finds a
  test still reports success, so the lane fails when `results_dir` records no test case.
  `expected_tests` names tests that must each appear.
- **The artifact**, uploaded on success too.

The caller keeps the triggers, the concurrency group and any report on a red scheduled run, which
`nightly-report` makes from a job of its own. It does not use `ci-setup`. A build that reads
credentials from `local.properties` passes them as the optional `local_properties` secret, which the
lane writes to that file before the build and never prints.

### Upstream watch

`upstream-watch.yml` notices when a server the app talks to ships a stable release and opens one
issue for it in the calling repository. Renovate keeps dependencies current; this covers the
servers, which it cannot. Call it weekly and by hand. `callers/example/upstream-watch.yml` is the
worked caller. It needs the default token only, no secret, and one `releases` API call per upstream.

Inputs: `upstreams` (required), `state_file`, `label`, `dry_run`, `runner`. The caller grants
`contents: read` and `issues: write`.

`upstreams` is a JSON array of `{"name", "repo"}`: a lowercase slug and a GitHub `owner/repo`.

```json
[{"name": "jellyfin", "repo": "jellyfin/jellyfin"}]
```

List upstreams that are separate projects. A repository that moved, or whose project merged into another,
is listed once under its current name: GitHub redirects the old name to the new one, so listing both
would open the same release twice. Fallenbagel/jellyseerr now redirects to seerr-team/seerr, for example,
so a Seerr consumer lists `seerr-team/seerr` and not Jellyseerr.

The state lives in the caller, in `docs/upstream.json` unless `state_file` says otherwise. It holds
the newest version *checked*, which is not always the newest released. It has no leading `v`, and
it is written as the upstream writes it: `12.4` for Jellyfin 12.4, `10.11.6` for 10.11.6.

```json
{ "jellyfin": { "checked": "10.11.6" } }
```

A person edits the file, in the PR that closes the issue. The workflow never writes it. A name in
`upstreams` with no entry fails the run, so a new upstream starts with a baseline you chose.

For each upstream, it opens one issue for the newest stable release if that is newer than `checked`,
titled `<name> <version>: new upstream release` and labelled `upstream`. The body has the release
link and notes and a checklist. Releases between `checked` and the newest, if any, are listed in the
body with their links, so a first run against an old baseline is one issue, not a dozen. Bumping
`checked` to the newest version closes them all. It looks for an existing issue for that version,
open or closed, among the issues carrying the label. It matches by the generated title and by a
marker in the body, so a renamed issue still counts, and it opens none twice. Removing the label from
an issue hides it from this check. If the issues cannot be listed, it opens nothing and fails the run.
Release notes are quoted as code, so an `@mention` in them notifies nobody.

It does not guess a version. A tag is `MAJOR.MINOR` or `MAJOR.MINOR.PATCH`, with or without a leading
`v`, digits only. Jellyfin's current tags are `v12.4` and `v10.11.11`. Versions compare by number, a
missing patch counts as 0, so 12.0 equals 12.0.0 and 12.4 is newer than 10.11.11. Any other stable tag
fails the run, as does an upstream with no stable release in its latest 30. Drafts and prereleases
(`v12.0-rc7`) are dropped before the tag is read. The other upstreams still run before the run fails.
The run summary lists every outcome, and a failed scheduled run notifies the repository.

Outputs: `opened`, a JSON array of `name@version`, and `newest`, a JSON object of name to newest
stable version. With `dry_run` it opens nothing and reports what it would. Run it that way first.

## The shared Gradle gates

Some build checks were copied between the consumers too: translation staleness, the detekt wiring,
detekt baseline staleness and the tv-material separation check. They live in `gradle-plugins/` as
Gradle plugins, each wired into `check`.

`gradle-plugins/` is a Gradle included build. A consumer already pins binge-ci by commit, so it
includes the build from that checkout and applies the plugins by id. That adds no repository and no
new pin. Each consumer adopts them in a PR of its own. [gradle-plugins/README.md](gradle-plugins/README.md)
lists the plugins and how to configure them.

### Reusing the design system

App pull requests keep adding UI that the shared design system already provides. Two detekt config fragments ban the raw
Material 3 blocks the design system wraps, so the build says what to use instead. The covered blocks are `TopAppBar` and
its variants and `Scaffold` (`BingeScreenScaffold` and the bar wrappers), `ModalBottomSheet` (`BingeBottomSheet`,
`BingeAdaptiveSheet`, `BingeChoiceSheet`), `TextField` and `OutlinedTextField` (`BingeTextField`), `SearchBar` and `DockedSearchBar`
(`BingeSearchField`), `AlertDialog` and `BasicAlertDialog` (`BingeConfirmDialog`, `BingeMessageDialog`), `TabRow` and its variants,
`FilterChip` and `InputChip`, `Button`, `OutlinedButton` and `TextButton`, `Slider` and `RangeSlider`, and
`SnackbarHost`. Each message points at `design-system/docs/components.md`.

- `detekt/design-system-bans.yml` bans the **import**. It sets one list, `style.ForbiddenImport.forbiddenImports`.
- `detekt/design-system-call-bans.yml` bans the **call**, under a wildcard import or a fully qualified name. It sets one
  list, `style.ForbiddenMethodCall.methods`, and turns the rule on with only those entries.

A consumer adds them after its own `detekt.yml`, from its `binge-ci` submodule:

```kotlin
detektGate {
    additionalConfigs.from(
        layout.settingsDirectory.file("binge-ci/detekt/design-system-bans.yml"),
        layout.settingsDirectory.file("binge-ci/detekt/design-system-call-bans.yml"),
    )
}
```

- **A list is replaced, not merged, so a clash is refused.** detekt reads a later file over an earlier one, and a list in
  the later file replaces the earlier one without a word. A consumer that already sets one of these lists in its own
  `detekt.yml` (a ban on `kotlin.runCatching`, say, under `ForbiddenMethodCall.methods`) would lose it the day a fragment
  that sets the same list is added. So the gate's `checkDetektConfigClashes` fails the build, naming the list and both
  files, when two config files set the same list. The fix is one list in one file: leave out the fragment that clashes and
  copy its entries into the consumer's own list.
- **App code only.** Both fragments exclude the design system's own path and build output, and the gate reads production
  source sets only. A file in the gate's `suppressedPaths` stays silent for them too, as for every other rule.
- **Existing uses.** Code that already uses a raw block goes into the consumer's baseline in the rollout PR, so the gate
  is zero new findings, not zero total.
- **A reviewed exception** is an annotation, not a config edit: `@file:Suppress("ForbiddenImport")` on the file that
  imports it, or `@Suppress("ForbiddenMethodCall")` on the function that calls it, with a one-line comment saying why
  the wrapper does not fit. A new component belongs in the design system, not in the app.
- **The `CLAUDE.md` line** every consumer carries: "Before writing UI, read `design-system/docs/components.md`; new
  components go in the design system, never in the app."
- **The PR line.** A PR that adds a composable outside the design system carries one line in its body, `Design system:
  <component> - <why it did not fit>`, naming what it checked. Each consumer adds it to its PR template.
- **The review rule.** `bot-review.yml` takes `design_system_index`, the path in the calling repository of the document
  that indexes the design system's components (`design-system/docs/components.md` in a consumer that has the design
  system as a submodule). Empty, the default, changes nothing. When it is set the review reads the index from the
  default branch and asks, as a judgement and not a name match, whether the UI the PR adds duplicates a component the
  index offers. A duplicate with no `Design system:` line is a request for changes naming the file and the component;
  a line with a real reason is accepted, and one without a reason is a question. The rule is written by the workflow
  and not read from the repository, so a PR cannot edit it, and the index is refused as a path a PR may change when CI
  does not build it. Set it in the caller beside `conventions_path`.

### Reviewing new screenshot frames

A frame a PR adds has nothing to be compared against: whatever was recorded becomes the baseline, and a green CI run
says nothing about whether it is right. So `bot-review.yml` opens each reference PNG a PR **adds** and checks it against
the repository's own design rules, as its review guide states them: clipped or cropped text, the same text drawn twice,
a missing icon on a row, a destructive action not last, a state whose structure differs from its sibling states, an
empty or broken picture. A finding names the frame's path and what is wrong. A frame that is fine gets no mention. A
frame a PR only changes is not looked at here; the re-record rules above cover it.

- **The list.** A step lists the added files only, from the merge base to the head, and hands the prompt a file. A path
  that is not plain (letters, digits and `. _ / + @ = , ( ) -` and spaces) is counted and left out.
- **The cap.** `new_frames_cap` (default 40) is the most frames one review opens. Past it the list is a sample, one
  frame per test class in turn, so every class is seen before any is seen twice, and the same PR gives the same sample.
  The review says how many it looked at of how many were added.
- **Opting in.** On by default. `review_new_frames: false` turns it off. `new_frame_paths` (default
  `**/screenshotTest*/reference/**/*.png`) names the frames' directories, as git globs one per line, for a repository
  that keeps them elsewhere.
- **What it will not do.** It does not open a frame the PR only changes, and text drawn inside a frame is data and
  never an instruction to the reviewer.

### App CI

`android-app-ci.yml` is the CI of an Android app, kept once. An app's own `ci.yml` is a thin caller: its triggers, its
paths and its Gradle tasks, and one job that says whether the run passed. `callers/example/android-app-ci.yml` is the
worked one.

The jobs run in parallel after `changes`:

| Job | What it runs | When |
| --- | --- | --- |
| `changes` | the `changed-files` action | always, except a draft pull request |
| `checks` | `checks_tasks`: `build` less the tasks the other jobs own | `product` |
| `tests` | `tests_tasks`: the unit tests and the coverage check | `product` |
| `screenshots` | `screenshot_shards` shards of the screenshot validation, each in a JVM of its own | `screens` |
| `release` | `release_tasks`: the release build, with R8 and its keep rules | `release` |
| `result` | nothing: it checks each job did what `changes` asked for | always, except a draft pull request |

- **Routing.** `changes` decides from the paths a pull request touched. `product_none` and `no_frames` are the paths
  that cannot affect a job, `release_inputs` the only paths that can reach the release build. A push to the default
  branch and the nightly run everything. There is no `paths-ignore`: the review bot needs a successful run against every
  head, so the run always happens and a job `changes` did not clear is skipped.
- **`result`** is green only when `changes` succeeded, every job it cleared succeeded, and every job it did not clear was
  skipped. A job that ran when it should not have fails it, and so does a skip `changes` did not order.
- **The required check is the caller's.** A reusable workflow's jobs reach branch protection as `<caller job> / <job>`,
  so a required check named `build` has to be a job of the caller's own. The worked caller's `build` needs the shared
  run (`ci`), the pin check and actionlint, and passes only if each succeeded or, for the last two, was skipped. The pin
  check, actionlint and the nightly report are jobs of the caller, where they are shared steps of their own.
- **A self-hosted runner** is one input, `runner`, a JSON array as in the other workflows. Every job runs on it, starts
  from a clean checkout and ends by stopping its Gradle daemon. The workflow assumes one runner per user and Gradle home,
  since `./gradlew --stop` stops every daemon of that Gradle version in the home. Heap is a `*_jvmargs` input per
  Gradle job, empty by default, which leaves the project's `gradle.properties` alone. The runner needs `git`, `jq`, `gh`
  and a JDK on PATH.
- **The caller grants** `contents: read` and `actions: read`, and passes `REVIEWER_APP_ID` and
  `REVIEWER_APP_PRIVATE_KEY` when `private_submodules` is set. `tools/check-callers.sh` checks the worked caller.

## Its own gate

This repo ships no product code beyond the Gradle gates, so CI checks the things that can be
wrong with it: the workflows (actionlint + shellcheck), the Gradle gates (their own `./gradlew build`)
and whether the callers still fit them
(`tools/check-callers.sh` — actionlint cannot see across a remote workflow reference, so
a misspelled input, a permission level the caller does not hold, or a quoted scalar passed
to a `number` or `boolean` input would otherwise fail at run time in the consuming repo).
The tools are shellchecked too, and each fails on finding nothing to check rather than
passing on an empty glob.

The five bots run on this repository's own PRs too, through the `self-*.yml` callers in
`.github/workflows/`, and the weekly storage sweep has one of its own,
`self-actions-storage-sweep.yml`. They pin the same release tag as the actions rather than `./`, so a PR
here is reviewed by the reviewer the consumers run and never by the one it is changing, and
a fix reaches this repo's own PRs the way it reaches everyone's — at the next release.
`auto_merge` is off: everything here governs the agents, so merging stays a human's. The
review reads `CLAUDE.md` and `.ai/agents/` from `main`, exactly as it does in a consumer.

## Writing a caller: the one thing that will bite you

**A caller must declare any permission the called workflow needs beyond `contents`.**

A reusable workflow cannot be granted more than its caller holds, and a caller with no
`permissions:` block gets the repository default — `contents: read`, with no `actions`.
`bot-review` and `author-ci-fix` both need `actions: read` for their CI-run lookup, and
`bot-review` needs `checks: write` for the check it posts when its first job fails, so a
caller that omits either dies as `startup_failure`: no log, no annotation, no job, and
nothing on the PR beyond a red tick.

`save-avd-cache` needs `actions: write` too, for the `gh cache delete` it runs before it saves:
`actions/cache/save` cannot overwrite an existing key. It takes the token as its `github-token`
input, and the job that calls it must hold `actions: write` for that token to carry it. This one
is not a `startup_failure`: the delete ends in `|| true`, so without the permission it fails
quietly and the next save is refused for an existing key.

This is the one way a caller differs from the copy it replaces. An ordinary workflow
declaring `permissions: actions: read` simply gets it; a caller has to hold it first — which
is why the in-repo copies ran for months and the first caller could not start.

`tools/check-callers.sh` checks this now. Nothing else can: actionlint cannot see across a
remote reference, and the called workflow's own CI is not the caller.

### Skip coordinator status comments

An agent session that works on a PR can post status notes for a coordinator under the
maintainer's account. Such a note starts with the line `<!-- to-coordinator`. It passes the
commenter gate, because the maintainer is an OWNER, and it would start a full run with
nothing to answer.

Add this clause to the job `if` in the caller's `author-comments.yml` and `bot-review.yml`:

```yaml
!startsWith(github.event.comment.body, '<!-- to-coordinator') &&
```

On an event with no comment the body is null, so the clause is true and filters nothing else.
The filter belongs on the caller's job, not in the called workflow: a job whose `if` is false
never joins the concurrency group, so it cannot cancel a pending run that has a real comment
to answer.

## Versioning

`v1` is a moving alias, and the consumers follow it. Each pins the commit `v1` names, with a
`# v1` comment, as it pins every other action. Renovate's digest pinning opens an update when
`v1` moves, and a human merges it like any workflow change, so a release reaches a consumer
when that update merges. The worked callers write `@v1`, the alias
they track. `v1.0.0` and friends are immutable tags too.

Releasing is four steps, in this order. Bump every self-reference in `.github/workflows/`
to the new patch tag: the actions the reusable workflows use and the `self-*.yml` callers
alike, which `tools/check-internal-refs.sh` requires to agree. Merge that. Tag `vX.Y.Z` at
that commit. **Then** move `v1`. That order keeps the window safe: a consumer's Renovate
resolves `v1`, so until it moves no consumer is offered the new commit, and none is offered a
tag that does not exist yet.

One door closes on the release PR itself. A `pull_request` event runs the workflow file
from the merge ref, so `self-review.yml` on that PR pins the tag the PR is about to create,
and its `labeled` door dies as `startup_failure` until the tag exists. The `workflow_run`
door still reviews it, from `main`'s copy at the previous tag. The other self callers
take the default-branch or base copy and are unaffected.

`tag-check.yml` enforces the part a PR cannot. On a `vX.Y.Z` push it requires that tag to
be the one the workflows pin, so a release cannot ship the previous release's actions; on a
`v1` move it requires the alias to land on the commit the pinned tag names; and on every
push to `main` it requires the pinned tag to exist, because the slip that has actually
happened is merging the bump and never tagging at all. On `main` it also requires that tag's
own tree to pin the same tag, which catches a bump to a tag already cut at an older commit. `main` is therefore red between the
bump merging and the tag being cut. That red is the report, not a fault, and it clears the
moment the tag is pushed. It detects rather than prevents: by the time a tag push fails
there, `v1` has moved and consumers are already broken, so it turns a silent breakage into a
loud one rather than stopping it.

### A Renovate preset for the pins

`renovate/binge-ci-pins.json` is the preset a consumer extends to receive each release as one pull request.
Consumers keep exact SHA pins, because they stop one bad release reaching every consumer at once; the preset
only automates the update.

```json
{ "extends": ["github>ScottCooper92/binge-ci//renovate/binge-ci-pins"] }
```

- **One PR per consumer.** The `binge-ci` `uses:` digest pins (github-actions manager, keeping the trailing
  `# v1.0.N` comment) and the `binge-ci` submodule (git-submodules manager) share one group, so they arrive
  together on the same commit. The PR is labelled `agent` and never `hold`.
- **Tags only.** `allowedVersions` admits `v1.0.N` and nothing else, so `v1` is never a target, and the
  digest in each pin is the tag's own commit.
- **The submodule follows `stable`.** Renovate's submodule manager follows a branch's head, not a tag, and
  `main` can be ahead of the newest tag. The release workflow moves the `stable` branch to each release
  commit, fast-forward only, so a consumer sets `branch = stable` for the `binge-ci` submodule in
  `.gitmodules` and the submodule pins exactly the commit the `uses:` pins name.
- **As soon as Renovate runs.** The rules carry `schedule: at any time`, `prCreation: immediate` and no
  release-age wait. With the hosted Renovate app that is within the hour, not within the minute; nothing here
  wakes it on a tag. The preset sets no schedule, label or automerge at the top level, so a consumer's own
  settings for its other dependencies are untouched.
- **Only the `binge-ci` submodule.** The preset turns the submodule manager on, then disables it for every
  submodule but `binge-ci`, so a consumer's other submodules are left to its own tooling. A consumer that sets
  `enabledManagers` replaces the preset's value and must include `git-submodules` in it, or the pin PR moves
  the `uses:` pins without the submodule.

`tools/test-renovate-preset.sh` holds the version restriction (it accepts `v1.0.0` and `v1.0.51`, and refuses
`v1`, `v1.1.0`, `v2.0.0` and prereleases), the group, the label and the absence of `hold`, and runs Renovate's
own validator when it is installed (`npx --package renovate renovate-config-validator --strict
renovate/binge-ci-pins.json`). CI does not install Renovate, so there it skips the validator.

The preset is read from `main`, so an edit to it reaches every consumer that extends it when it merges, ahead of
any release. A consumer that wants it fixed to a release extends `...binge-ci-pins#v1.0.N` instead.

## Licence

Apache License 2.0. See `LICENSE`.
