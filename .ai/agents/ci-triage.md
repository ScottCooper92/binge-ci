# CI triage

Maps a red CI run to its correct fix. `author-ci-fix.yml` reads this file from `main` and
works from the table below; it gets a bounded number of repair attempts, so a guess is
expensive and stopping is cheap.

CI is one job, `lint`, with these steps in order:

| Step | Runs |
| --- | --- |
| `actionlint` | actionlint, with shellcheck at `--severity=warning`, over `.github/workflows/*.yml` and `callers/*/*.yml` |
| Check the draft callers | `tools/check-callers.sh` - each caller's inputs, secrets and permissions against the workflow it calls, the worked ones under `callers/` and this repository's own `self-*.yml` alike |
| shellcheck the composite actions | `tools/check-action-shell.sh` - every `run:` block in `.github/actions/*/action.yml` |
| Check this repo's references | `tools/check-internal-refs.sh` - no `uses: ./`, one immutable tag on every self-reference |
| shellcheck the governed-paths script | shellcheck on `restore-agent-governed-paths.sh` |

Nothing builds. If the log shows a failure that is not in the table below, that is a
**stop**, not an invitation to improvise.

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
| `check-internal-refs.sh`: `cannot reference a local action` | A `uses: ./` inside a reusable workflow or action | Replace it with the full `ScottCooper92/binge-ci/...@vX.Y.Z` reference at the tag every other self-reference uses |
| `check-internal-refs.sh`: `self-references disagree` or `moving alias` | One reference was bumped, or points at `v1` | **Stop** unless this PR is the release bump itself. A pin is bumped in a release commit that does nothing else; a repair must not do it |
| `tag-check.yml` red on `main` | The pinned tag does not exist or does not name this release | **Stop.** This runs after a merge, not on a PR; cutting the tag is a human's step and no PR fixes it |
| Empty or unreadable log | Nothing to triage from | **Stop.** The workflow already handles this and comments on the PR |

## Verifying

Run only what failed, scoped. shellcheck is on the runner; actionlint is not, and the
`actionlint` step in `.github/workflows/ci.yml` shows the version and checksum to fetch.

```sh
shellcheck --severity=warning <the file you changed>
./tools/check-callers.sh
./tools/check-action-shell.sh
./tools/check-internal-refs.sh
./actionlint -shellcheck 'shellcheck --severity=warning' .github/workflows/*.yml
./actionlint -shellcheck 'shellcheck --severity=warning' callers/*/*.yml
```

Do not run the full gate. CI does that on push.

## Never

- Add a `# shellcheck disable=` comment or lower the severity.
- Remove, weaken or skip a step in `ci.yml` or a check in `tools/`.
- Change a `uses:` pin outside a release commit.
- Widen a `permissions:` block beyond what the called workflow's header says it needs.

## When in doubt

A workflow's signature is an interface three repositories build against. A red gate is not
permission to redesign it. Leaving the working tree clean and saying why is a valid and
preferred outcome; a wrong guess costs more than stopping.
