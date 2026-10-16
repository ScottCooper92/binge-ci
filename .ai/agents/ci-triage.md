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
| Test the governed-paths script | `tools/test-governed-paths.sh` - `restore-agent-governed-paths.sh` against scratch repositories: what it restores, merges, discards and keeps, and the markers each case leaves |
| shellcheck the action scripts and the tools | shellcheck on every `.github/actions/*/*.sh` (`restore-agent-governed-paths.sh`, `merge-guards.sh`) and `tools/*.sh` |
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
| `test-governed-paths.sh`: a case FAILs | The governed-paths script no longer leaves the note, marker or file that case expects | Fix the script if this PR changed it. If the PR deliberately changed what a case expects, change that case and say so; never delete one or loosen what it asserts |
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
./tools/test-governed-paths.sh
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

A workflow's signature is an interface four repositories build against. A red gate is not
permission to redesign it. Leaving the working tree clean and saying why is a valid and
preferred outcome; a wrong guess costs more than stopping.
