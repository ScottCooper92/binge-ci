#!/usr/bin/env bash
#
# Runs author-comments.yml's PR-body check against fixture bodies. The agent may un-tick a checklist
# box and reword the "Left to CI" line, and nothing else: a body that does more must be refused whole,
# because the push step applies it with a write token. The function is read out of the workflow
# between its bound markers, so this tests what runs.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
workflow="$root/.github/workflows/author-comments.yml"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
pass() { echo "ok    $1"; }

awk '/# bound:begin/ {on = 1} on {sub(/^          /, ""); print} /# bound:end/ {exit}' "$workflow" > "$work/fn.sh"
if [ "$(grep -c 'bound:begin' "$workflow")" -ne 1 ] || ! grep -q '^body_edit_allowed()' "$work/fn.sh"; then
  fail "body_edit_allowed is not in the workflow exactly once"
  exit 1
fi
# shellcheck source=/dev/null
. "$work/fn.sh"

body='## What and why

Moves a thing.

## Checked before pushing

- [x] actionlint over the workflows
- [x] `./gradlew build`, if the gates changed
- [ ] The worked callers follow any signature change
- [ ] Left to CI, and why: nothing
'
printf '%s' "$body" > "$work/orig.md"

# $1=description  $2=expected (allowed|refused)  $3...=sed arguments that turn the body into the proposal
case_() {
  local what=$1 want=$2
  shift 2
  printf '%s' "$body" | sed "$@" > "$work/new.md"
  if body_edit_allowed "$work/orig.md" "$work/new.md"; then got=allowed; else got=refused; fi
  if [ "$got" = "$want" ]; then pass "$what"; else fail "$what (got $got)"; fi
}

case_ "a ticked box un-ticked" allowed -e 's/^- \[x\] actionlint/- [ ] actionlint/'
case_ "two ticked boxes un-ticked" allowed -e 's/^- \[x\]/- [ ]/'
case_ "the Left to CI line reworded" allowed -e 's/Left to CI, and why: nothing/Left to CI, and why: actionlint is not installed here/'
case_ "the Left to CI line un-ticked and reworded" allowed -e 's/^- \[ \] Left to CI, and why: nothing/- [ ] Left to CI, and why: the build/'
case_ "no change at all" allowed -e 's/zzz/zzz/'
case_ "CRLF line endings do not matter" allowed -e 's/$/\r/'
case_ "an unticked box ticked" refused -e 's/^- \[ \] The worked/- [x] The worked/'
case_ "the Left to CI line ticked" refused -e 's/^- \[ \] Left to CI/- [x] Left to CI/'
case_ "a line added" refused -e '$a - [ ] one more'
case_ "a line removed" refused -e '/^- \[x\] actionlint/d'
case_ "the text of a checklist line changed" refused -e 's/actionlint over the workflows/nothing at all/'
case_ "the prose above the checklist changed" refused -e 's/Moves a thing\./Moves a different thing./'
case_ "a box un-ticked and its text changed" refused -e 's/^- \[x\] actionlint over the workflows/- [ ] actionlint, skipped/'
case_ "a box un-ticked and the prose changed" refused -e 's/^- \[x\] actionlint/- [ ] actionlint/' -e 's/Moves a thing/Moves it/'
case_ "an empty file" refused -e 'd'

if [ "$failures" -gt 0 ]; then echo "$failures failure(s)"; exit 1; fi
echo "all passed"
