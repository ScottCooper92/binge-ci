# CI triage

Maps a red CI run to its correct fix. `author-ci-fix.yml` reads this file from `main` and
works from the table below; it gets a bounded number of repair attempts, so a guess is
expensive and stopping is cheap.

CI is two jobs. The first, `lint`, runs these steps in order:

| Step | Runs |
| --- | --- |
| `actionlint` | actionlint, with shellcheck at `--severity=warning`, over `.github/workflows/*.yml` and `callers/*/*.yml` |
| Check the draft callers | `tools/check-callers.sh` - each caller's inputs, secrets and permissions against the workflow it calls, the worked ones under `callers/` and this repository's own `self-*.yml` alike |
| shellcheck the composite actions | `tools/check-action-shell.sh` - every `run:` block in `.github/actions/*/action.yml` |
| Check composite-action env references | `tools/check-action-env.sh` - every `${{ env.X }}` in an `action.yml` is set by an `env:` key or a `$GITHUB_ENV` write in that action |
| Check this repo's references | `tools/check-internal-refs.sh` - no `uses: ./` in a reusable workflow or composite action, one immutable tag on every self-reference |
| Test the references check | `tools/test-internal-refs.sh` - `check-internal-refs.sh` against fixture trees: `./` fails in a `workflow_call` file and an action, and passes in a workflow that runs only here |
| Check the token mints | `tools/check-token-permissions.sh` - every `permission-*` a `create-github-app-token` step asks for is one its app's installation grants, as recorded in the script |
| Test the token check | `tools/test-token-permissions.sh` - `check-token-permissions.sh` against fixture workflows: a granted mint passes; an ungranted permission, an unrecorded app, and a step that a `- uses:` line opens or a `with:` comes before, each fail with the line that names it |
| Test the caller check | `tools/test-check-callers.sh` - `check-callers.sh` against fixture callers: a grant at the top level or on the calling job passes; a job block that narrows or omits what the workflow declares, an empty block, and a grant on some other job each fail with the permission named |
| Test the merge guards | `tools/test-merge-guards.sh` - `merge-guards.sh buildable` against fixed path lists in Binge's regex: which paths CI would build, both sides of a rename, anchored directories, and `method` |
| Test the governed-paths script | `tools/test-governed-paths.sh` - `restore-agent-governed-paths.sh` against scratch repositories: what it restores, merges, discards and keeps, the markers each case leaves, and the paths its prompt note names |
| Test the submodule-pin check | `tools/test-submodule-pins.sh` - the pin check's step in `submodule-pins.yml` against scratch repositories, one case per outcome: unchanged, same pin, forward and merged, rolled back, forward and unmerged, off the base, and a base pin missing upstream, and the failing ones again with the hold label |
| Test the fork-review workflow | `tools/test-fork-review.sh` - the tripwires `fork-review.yml`'s safety rests on (no checkout and no `pull_request_target`, no `${{ }}` inside a `run:` block, no skip-permissions flag, no shell or write tool for the agent, each job holding only the permissions and secret it was given) and its shared `collect_pr` function, whose two copies must be identical |
| Test the actionlint download | `tools/test-download-actionlint.sh` - `download-actionlint.sh` against a stubbed `gh`: a good tarball, a checksum mismatch (one re-fetch, then failure), an HTML error page, and a transfer that keeps failing |
| Test the upstream-watch script | `tools/test-upstream-watch.sh` - `upstream-watch.sh` against a stubbed `gh`: a newer stable release, an equal or older one, drafts and prereleases, two- and three-part tags (`v12.4`, `v10.11.11`) kept as written, a tag that is neither, a missing state entry or file, one issue naming the releases in between, a duplicate by title or marker, a failed issue lookup, a dry run, and version order by number rather than text |
| Test the submodule-bump script | `tools/test-submodule-bump.sh` - `submodule-bump.sh` against scratch repositories and a stubbed `gh`: a pin at the head, a new bump, a re-run, a PR whose commits are all the bot's, one with a commit pushed by someone else, a conflicted PR, a pin that is not behind the branch, a dry run, text that tries to forge the marker, and a failure reported once per head |
| Test the author bot's PR body check | `tools/test-body-checklist.sh` - the body-edit function in `author-comments.yml` against fixture bodies: a box un-ticked, the "Left to CI" line reworded, and every other change (a box ticked, a line added or removed, prose edited) refused |
| Test the review bot's rebuttal cap | `tools/test-rebuttal-cap.sh` - the cap function in `bot-review.yml` on fixed counts (the first rebuttal reconsidered at the default, later ones not, `0` never), and the input's default |
| Test the agent jobs' limits | `tools/test-agent-limits.sh` - every agent job uses the network-limit and tool-call actions, with no inline copy, and their scripts behave on fixtures |
| Test the screenshot sharding | `tools/test-shard-screenshots.sh` - every class lands in exactly one shard for any shard count, the split is the same each time, and a stray frame, an orphaned reference or a bad argument fails instead of passing |
| Test the changed-files action | `tools/test-changed-files.sh` - a path in no set runs the Gradle jobs and the frames, the release build runs only for its allow-list, and a missing baseline or an unreadable diff runs everything |
| Test the Renovate preset | `tools/test-renovate-preset.sh` - the preset offers only `v1.0.N` tags (never `v1`), puts the actions and the submodule in one `agent` pull request, never adds `hold`, and sets nothing at the top level that would override a consumer |
| Test the release tagging | `tools/test-release-tag.sh` - a merge that is not a release does nothing, a release is tagged only when the branch name, the tree and the diff agree, the writes go release tag, `v1`, `stable` in that order and stop at a failed check, and the workflow asks the App for contents alone |
| Test the screenshot re-record comment | `tools/test-rerecord-comment.sh` - the comment lists the frames the pushed commit changed with before and after, the prompt keeps its gate (40 frames, no render errors), and the review rules look at the frames |
| Test the runner-local Claude Code cache step | `tools/test-claude-code-cache.sh` - the cache step is the same in every agent job, tied to the agent step's pin, and installs once, reuses, and falls back on fixtures |
| Check the gate lists | `tools/check-gate-lists.sh` - every list of gate tests (CLAUDE.md, the review guide, this file's three parts, the PR template, `gated_checks` and `verify_guidance`) names each `tools/test-*.sh` and `tools/check-*.sh` that `ci.yml` runs |
| Test the gate-lists check | `tools/test-check-gate-lists.sh` - `check-gate-lists.sh` against fixture trees: a complete set passes, a script missing from each list fails naming that list, and a longer name does not stand in for a shorter one |
| shellcheck the action scripts and the tools | shellcheck on every `.github/actions/*/*.sh` (`restore-agent-governed-paths.sh`, `merge-guards.sh`, `download-actionlint.sh`, `upstream-watch.sh`) and `tools/*.sh` |
| Workflows and callers are .yml | `find .github callers -name '*.yaml'` - every check here globs `.yml` only, so a `.yaml` file would be seen by none of them |

The second, `gradle-plugins`, is the one thing that builds. It runs `./gradlew build` in
`gradle-plugins/`: the shared Gradle gates' Kotlin compile, plugin validation (`validatePlugins`,
with stricter validation and warnings as failures), and their unit and TestKit tests. The TestKit
tests run each gate in a real fixture build, and the detekt gate's Android case builds against the
runner's own SDK.

If the log shows a failure that is not in the table below, that is a **stop**, not an invitation
to improvise.

## The table

| Failure | Why | Fix |
| --- | --- | --- |
| actionlint: `unknown input` / `input is required but not given` / `undefined secret` on a caller | The caller and the workflow disagree | Fix whichever side this PR changed. If the PR changed the workflow, make the caller fit it; if it changed a caller, make it match the workflow. Never change the workflow's signature to match a stale caller |
| actionlint: `property "x" is not defined in object type` on a `${{ }}` expression | A misspelt context key or an output no step sets | Fix the reference. If the output is genuinely missing, add the `>> "$GITHUB_OUTPUT"` line that sets it |
| actionlint: `permissions` / `scope name` error | A permission name or level that does not exist | Correct the name. Do not widen a permission to make it parse |
| actionlint: `workflow_call` input `type` mismatch | A caller passes a quoted scalar to a `number` or `boolean` | Unquote it in the caller |
| shellcheck warning in a `run:` block or script (SC2086, SC2155, SC2181, …) | Ordinary | Fix the shell. Quote the variable, split the declaration, test the command directly. Never add `# shellcheck disable=` |
| `check-callers.sh`: `does not declare permission X: Y` | The called workflow needs a permission the caller does not hold | Add it to the caller's `permissions:` block at the level named. This is the single most common consumer breakage; see README.md, "Writing a caller" |
| `check-callers.sh`: unknown input or secret | The caller names something the workflow does not declare | Fix the side this PR changed, as for the actionlint case above |
| `check-callers.sh`: quoted scalar | `'true'` or `'10'` passed to a `boolean` or `number` input | Unquote it |
| `check-action-shell.sh` failure | A composite action's `run:` block has a shellcheck warning | Fix the shell as above. The script extracts the blocks; edit `action.yml`, not the extract |
| `check-action-env.sh` failure | A composite action reads `${{ env.X }}` that no `env:` key or `$GITHUB_ENV` write in it sets, so it expands to nothing on the runner | Set `X` in the step's `env:`, write it to `$GITHUB_ENV` in an earlier step (`echo "X=…" >> "$GITHUB_ENV"`, quoted or not, in a one-line `run:` or any block scalar, or the `X<<delim` heredoc form), or take it as an input; the runner's own environment is not in the `env` context. The check looks only for the name in the same action file, not for the write coming first or the `env:` key being on the reading step |
| `check-internal-refs.sh`: `cannot reference a local action` | A `uses: ./` inside a reusable workflow (one that declares `workflow_call`) or a composite action | Replace it with the full `ScottCooper92/binge-ci/...@vX.Y.Z` reference at the tag every other self-reference uses |
| `Workflows and callers are .yml`: `invisible to every check here` | A workflow, caller or action file under `.github/` or `callers/` was added as `.yaml` | Rename it to `.yml` with `git mv`, and change any reference to its path. Do not widen a glob to accept `.yaml` |
| `check-token-permissions.sh`: `is not granted to the … installation` | A mint asks for a permission its app does not have, so it would fail at run time and the job would die before its agent ran | Drop that `permission-*` input, or ask for one the app has. Never add a permission to the script's grant to make it pass: it records the installation's settings, and only a human changing those moves it |
| `check-token-permissions.sh`: `has no grant recorded` | A mint narrows its token for an app the script does not know | **Stop.** Recording an app's grant is a human's call, made from that installation's settings |
| `test-token-permissions.sh`: a case FAILs | `check-token-permissions.sh` no longer reads a step's app and permissions the way that case expects | Fix the check if this PR changed it. Never delete a case or loosen the line it expects |
| `test-check-callers.sh`: a case FAILs | `check-callers.sh` no longer reads a caller's permissions grant the way that case expects | Fix `check-callers.sh` if this PR changed it. Never delete a case or loosen the text it expects |
| `test-internal-refs.sh`: a case FAILs | `check-internal-refs.sh` no longer treats a fixture tree the way that case expects | Fix `check-internal-refs.sh` if this PR changed it. Never delete a case or loosen what it expects |
| `test-download-actionlint.sh`: a case FAILs | `download-actionlint.sh` no longer reaches the outcome that case expects against the stubbed `gh` | Fix the script if this PR changed it. A bad tarball wrongly accepted puts an unverified binary in every consumer's CI. Never delete a case or loosen what it expects |
| `test-upstream-watch.sh`: a case FAILs | `upstream-watch.sh` no longer reaches the outcome that case expects against the stubbed `gh` | Fix the script if this PR changed it. A tag it skips instead of failing hides a release in every consumer. Never delete a case or loosen what it expects |
| `test-submodule-bump.sh`: a case FAILs | `submodule-bump.sh` no longer reaches the outcome that case expects against the scratch repositories | Fix the script if this PR changed it. A branch force-pushed over someone else's commits, or a held pin moved, damages every consumer on its next scheduled run. Never delete a case or loosen what it expects |
| `test-body-checklist.sh`: a case FAILs | The body-edit check in `author-comments.yml` allows or refuses a body it should not | Fix the function if this PR changed it. It guards a write-token edit of the PR author's own text: never loosen it to pass a case, and never delete one |
| `test-rebuttal-cap.sh`: a case FAILs | The cap in `bot-review.yml` reconsiders a head more or fewer times than `max_rebuttals` allows, or its input default moved | Fix the function if this PR changed it. A cap that never holds restores the review loop on every consumer; one that is too tight leaves a disputed verdict with no way back. Never delete a case or loosen what it expects |
| `test-agent-limits.sh`: a case FAILs | An agent job lost, or stopped using, the action that bounds the agent's network calls or the one that prints its last tool calls (or an inline copy came back), or a script no longer behaves on its fixtures, or the review prompt lost its URL rule | Put the `uses:` of both actions back in every agent job. Never raise a limit to get past a slow call or delete a case |
| `test-shard-screenshots.sh`: a case FAILs | A class lands in no shard or two, the split changed between runs, an error became an empty result, or the action no longer hands the script its inputs through env | Fix the script or the action. A frame no shard names is a frame nothing validates, so never loosen a fail-closed case or delete one |
| `test-changed-files.sh`: a case FAILs | A job was skipped for a path in no set, an empty or unset release allow-list was accepted, a run that did not pass or is not an ancestor became the baseline, or an error became a skip | Fix the script. A skipped job cannot fail, so never loosen a case to let a skip through; the safe answer to anything unreadable is to run everything |
| `test-renovate-preset.sh`: a case FAILs | The version restriction admits `v1` or a prerelease, the two rules no longer share a group, the label changed or gained `hold`, or the validator rejects the file | Fix the preset. Never widen `allowedVersions`: the exact pins to tagged releases are what stop one bad release reaching every consumer |
| `test-release-tag.sh`: a case FAILs | A merge that is not an exact self-reference bump was tagged, `v1` moved before its checks passed, a tag was moved or created twice, a failed release opened no issue, or the workflow gained a trigger, a permission or a secret outside the `release` environment | Fix the script or the workflow. The App can create tags the ruleset forbids, so never loosen a refusal to get a release through; make the release PR what the script accepts |
| `test-rerecord-comment.sh`: a case FAILs | The comment builder lists a frame the commit did not change, drops one it did, links the wrong commits, or no longer flags an added or deleted frame; or the prompt's gate or the review rules lost a condition | Fix the builder or restore the condition. The list must come from the commit's diff, never from the agent. Never delete a case or loosen the gate to pass |
| `test-claude-code-cache.sh`: a case FAILs | A copy of the cache step differs, its `ACTION_REF` is not the pin of the claude-code-action step beside it, it moved after the curl-limits step, or it no longer installs once, reuses a warm cache, or falls back to the action's own install | Make the copies agree and re-point `ACTION_REF` at the pin; the step must never fail the job. Never delete a case or make a failed install fail the run |
| `check-gate-lists.sh`: `does not name tools/X.sh` | A list of gate tests was not updated when `ci.yml` gained or renamed a script | Add `X.sh` to the list the line names, in that list's own style. Never remove the script from `ci.yml`, or the check, to make it pass. The exception is a line naming `CLAUDE.md` in your own run: it is reset to the base branch's copy before you start, so an edit there is undone before it is committed and the failure is expected on a PR that adds a gate. Say so in your reply, leave `CLAUDE.md` alone, and leave that check to CI, which reads the PR's own copy. Every other list keeps the PR's copy, so a failure naming one is real |
| `test-check-gate-lists.sh`: a case FAILs | `check-gate-lists.sh` no longer reads the lists the way that case expects | Fix the check if this PR changed it. Never delete a case or loosen what it expects |
| `test-merge-guards.sh`: a case FAILs | `buildable` no longer separates the paths CI builds from the ones it ignores the way that case expects | Fix `merge-guards.sh` if this PR changed it. A path wrongly read as unbuilt lets the review bot merge code no build vouched for. Never delete a case or loosen what it expects |
| `test-governed-paths.sh`: a case FAILs | The governed-paths script no longer leaves the note, marker or file that case expects | Fix the script if this PR changed it. If the PR deliberately changed what a case expects, change that case and say so; never delete one or loosen what it asserts |
| `test-submodule-pins.sh`: a case FAILs | The pin check no longer reaches the outcome that case expects for that pin | Fix the `run:` block in `submodule-pins.yml` if this PR changed it. A pin wrongly passed lets a consumer merge a submodule commit its upstream does not have. Never delete a case or loosen what it expects |
| `test-fork-review.sh`: a `FAIL` line | `fork-review.yml` lost a property its safety rests on, or its two `collect_pr` copies differ | Restore the property in the workflow if this PR changed it, and keep the two copies identical. **Stop** if the only fix would add a checkout, `pull_request_target`, a skip-permissions flag, a shell or write tool for the agent, or a `${{ }}` inside a `run:` block: those are the properties the test exists to hold. Never delete a check or loosen what it expects |
| `check-internal-refs.sh`: `self-references disagree` or `moving alias` | One reference was bumped, or points at `v1` | **Stop** unless this PR is the release bump itself. A pin is bumped in a release commit that does nothing else; a repair must not do it |
| `gradle-plugins`: Kotlin compile error | The PR changed a gate's code, or a test, and it no longer compiles | Fix the code this PR changed. A gate's plugin id, extension or task name is its public signature, so do not rename one to make a call site compile |
| `gradle-plugins`: `validatePlugins` failure | A task property is missing its input or output annotation, or a plugin's metadata is wrong | Add the annotation the message names (`@Input`, `@InputFiles` with a `@PathSensitive`, `@OutputFile`, `@Internal` for what is not an input), or fix the `gradlePlugin {}` entry. Never turn off `enableStricterValidation` or `failOnWarning` |
| `gradle-plugins`: a unit or TestKit test fails on code this PR changed | The gate no longer does what the test says it must | Fix the gate. The test is the gate's contract: never loosen an assertion, swap `buildAndFail()` for `build()`, delete a case or add `@Disabled` to make it pass. Change a test only where this PR deliberately changed the behaviour it pins, and say so |
| `gradle-plugins`: a test fails on a PR that does not touch `gradle-plugins/` | A flaky test, or a fault in the gates that this PR only exposed | **Stop.** It is not this PR's to fix, and a re-run is a human's call. Say which test failed and quote its error |
| `gradle-plugins`: dependency resolution fails (`Could not resolve`, HTTP 429, a timeout) | The network or a repository, not the code | **Stop.** Nothing in the PR fixes it |
| `tag-check.yml` red on `main` | The pinned tag does not exist or does not name this release | **Stop.** This runs after a merge, not on a PR; cutting the tag is a human's step and no PR fixes it |
| Empty or unreadable log | Nothing to triage from | **Stop.** The workflow already handles this and comments on the PR |

## Verifying

Run only what failed, scoped. shellcheck is on the runner; actionlint is not, and
`.github/actions/actionlint/action.yml` shows the version and checksum to fetch.

```sh
shellcheck --severity=warning <the file you changed>
./tools/check-callers.sh
./tools/check-action-shell.sh
./tools/check-action-env.sh
./tools/check-internal-refs.sh
./tools/test-internal-refs.sh
./tools/check-token-permissions.sh
./tools/test-token-permissions.sh
./tools/test-check-callers.sh
./tools/test-merge-guards.sh
./tools/test-governed-paths.sh
./tools/test-submodule-pins.sh
./tools/test-fork-review.sh
./tools/test-download-actionlint.sh
./tools/test-upstream-watch.sh
./tools/test-submodule-bump.sh
./tools/test-body-checklist.sh
./tools/test-rebuttal-cap.sh
./tools/test-agent-limits.sh
./tools/test-claude-code-cache.sh
./tools/test-rerecord-comment.sh
./tools/test-shard-screenshots.sh
./tools/test-changed-files.sh
./tools/test-renovate-preset.sh
./tools/test-release-tag.sh
./tools/check-gate-lists.sh
./tools/test-check-gate-lists.sh
./actionlint -shellcheck 'shellcheck --severity=warning' .github/workflows/*.yml
./actionlint -shellcheck 'shellcheck --severity=warning' callers/*/*.yml
(cd gradle-plugins && ./gradlew test --tests '<the failing test class>')
(cd gradle-plugins && ./gradlew validatePlugins)
```

Do not run the full gate. CI does that on push.

## Never

- Add a `# shellcheck disable=` comment or lower the severity.
- Remove, weaken or skip a step in `ci.yml` or a check in `tools/`.
- Change a `uses:` pin outside a release commit.
- Widen a `permissions:` block beyond what the called workflow's header says it needs.
- Loosen, skip or delete a `gradle-plugins` test, or relax `validatePlugins`, to make the build pass.

## When in doubt

A workflow's signature is an interface six repositories build against. A red gate is not
permission to redesign it. Leaving the working tree clean and saying why is a valid and
preferred outcome; a wrong guess costs more than stopping.
