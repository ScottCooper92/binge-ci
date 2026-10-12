## What and why

<!-- One short paragraph, then `Closes #N` (or `Part of #N`). Say what a change to a public signature means for consumers. -->

## Checked before pushing

<!-- Tick what you ran locally on the final head. If you couldn't run one (it runs out of memory, or needs the network), leave it unticked and say so. Don't tick a box you didn't run. -->
- [ ] actionlint (with shellcheck at warning) over `.github/workflows` and `callers/`
- [ ] `shellcheck --severity=warning .github/actions/*/*.sh tools/*.sh`
- [ ] `tools/check-callers.sh`, `tools/check-action-shell.sh`, `tools/check-action-env.sh`, `tools/check-internal-refs.sh`
- [ ] `tools/test-internal-refs.sh`
- [ ] `./gradlew build` in `gradle-plugins/`, if the gates changed
- [ ] The worked callers under `callers/` follow any signature change
- [ ] Left to CI, and why: <!-- e.g. `./gradlew build` needs the network and I have none -->
