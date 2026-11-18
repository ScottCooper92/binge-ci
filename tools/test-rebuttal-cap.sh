#!/usr/bin/env bash
#
# Runs bot-review.yml's rebuttal cap on fixed counts. The fourth door re-reviews a head each time the
# author bot answers a CHANGES_REQUESTED verdict, and without a cap an author that cannot act on a
# finding loops the review forever. The function is read out of the workflow between its bound
# markers, so this tests what runs. Also holds the input to the default the consumers rely on.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
workflow="$root/.github/workflows/bot-review.yml"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
pass() { echo "ok    $1"; }

awk '/# bound:begin/ {on = 1} on {sub(/^          /, ""); print} /# bound:end/ {exit}' "$workflow" > "$work/fn.sh"
if [ "$(grep -c 'bound:begin' "$workflow")" -ne 1 ] || ! grep -q '^rebuttal_cap_reached()' "$work/fn.sh"; then
  fail "rebuttal_cap_reached is not in the workflow exactly once"
  exit 1
fi
# shellcheck source=/dev/null
. "$work/fn.sh"

# $1=description  $2=expected (reached|open)  $3=pinned reviews on the head  $4=max_rebuttals
case_() {
  if rebuttal_cap_reached "$3" "$4"; then got=reached; else got=open; fi
  if [ "$got" = "$2" ]; then pass "$1"; else fail "$1 (got $got)"; fi
}

case_ "the first rebuttal is reconsidered at the default of 1" open 1 1
case_ "the second is not: the head has had its one reconsideration" reached 2 1
case_ "nor the third" reached 3 1
case_ "0 never reconsiders" reached 1 0
case_ "3 allows three reconsiderations" open 3 3
case_ "and not a fourth" reached 4 3

if grep -A8 '^      max_rebuttals:' "$workflow" | grep -q '^        default: 1$'; then
  pass "max_rebuttals defaults to 1"
else
  fail "max_rebuttals does not default to 1"
fi
# Only the lines from the marker to the capped branch's `exit 0`: `skip=true` is written elsewhere in
# the step too, so a grep over the whole file would pass if this branch stopped skipping.
capped=$(awk '/review-stalled:/ { on = 1 } on { print } on && /exit 0/ { exit }' "$workflow")
if grep -q 'review-stalled:' <<<"$capped" && grep -q '"skip=true" >> "$GITHUB_OUTPUT"' <<<"$capped"; then
  pass "a capped head posts its marked note and skips the review"
else
  fail "the capped path no longer posts its note and skips"
fi
if grep -q 'Only a push or a dismissal re-opens the review' <<<"$capped"; then
  pass "the stall note says only a push or a dismissal re-opens the review"
else
  fail "the stall note does not say what re-opens the review"
fi

if [ "$failures" -gt 0 ]; then echo "$failures failure(s)"; exit 1; fi
echo "all passed"
