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
if grep -q 'Only a push, or a dismissal followed by a new run, re-opens it' <<<"$capped"; then
  pass "the stall note says what re-opens the review: a push, or a dismissal and a new run"
else
  fail "the stall note does not say what re-opens the review"
fi

# Which reviews pin a head. The filter is read out of the workflow between its own markers, and run on
# fixture reviews: a live one counts, a dismissed one does not, and neither does another app's, a
# human's, or one for another commit.
awk '/# bound:pin-begin/ {on = 1; next} /# bound:pin-end/ {exit} on {sub(/^          /, ""); print}' "$workflow" > "$work/pin.sh"
if [ "$(grep -c 'bound:pin-begin' "$workflow")" -ne 1 ] || ! grep -q '^pinned_filter=' "$work/pin.sh"; then
  fail "the pin filter is not in the workflow exactly once"
else
  pinned_filter=""
  # shellcheck source=/dev/null
  . "$work/pin.sh"
  review() { # $1=login  $2=type  $3=state  $4=sha7  $5=submitted_at
    jq -nc --arg l "$1" --arg t "$2" --arg s "$3" --arg h "$4" --arg at "$5" \
      '{user: {login: $l, type: $t}, state: $s, body: ("Reviewed `" + $h + "`. Findings."), submitted_at: $at}'
  }
  count() { jq -s --arg pin 'Reviewed `abc1234`' --arg login 'reviewer[bot]' "$pinned_filter" | jq 'length'; }
  n=$({ review 'reviewer[bot]' Bot CHANGES_REQUESTED abc1234 2026-01-01T00:00:01Z
        review 'reviewer[bot]' Bot DISMISSED abc1234 2026-01-01T00:00:02Z
        review 'reviewer[bot]' Bot APPROVED abc1234 2026-01-01T00:00:03Z
        review 'other-app[bot]' Bot APPROVED abc1234 2026-01-01T00:00:04Z
        review 'someone' User APPROVED abc1234 2026-01-01T00:00:05Z
        review 'reviewer[bot]' Bot APPROVED fffffff 2026-01-01T00:00:06Z; } | count)
  [ "$n" -eq 2 ] && pass "a dismissed review, another app's, a human's and another commit's pin nothing" \
    || fail "the pin filter counted $n reviews, expected the 2 live ones"
  n=$(review 'reviewer[bot]' Bot DISMISSED abc1234 2026-01-01T00:00:01Z | count)
  [ "$n" -eq 0 ] && pass "a head whose only review was dismissed is not pinned, so it is reviewed again" \
    || fail "a dismissed review still pins its head"
fi

# Whether THIS run's review landed after a failed POST. The lookup is read out of the workflow between its
# markers and run on fixtures: an earlier review on the head (a CHANGES_REQUESTED one, or a dismissed one)
# is not this run's, and neither is another run's, another attempt's or another app's. Only a review
# carrying this run's marker counts.
awk '/# bound:landed-begin/ {on = 1; next} /# bound:landed-end/ {exit} on {sub(/^            /, ""); print}' "$workflow" > "$work/landed.sh"
if [ "$(grep -c 'bound:landed-begin' "$workflow")" -ne 1 ] || ! grep -q '^landed_filter=' "$work/landed.sh"; then
  fail "the landed filter is not in the workflow exactly once"
else
  landed_filter=""
  # shellcheck source=/dev/null
  . "$work/landed.sh"
  mine() { # $1=login  $2=state  $3=run marker suffix, or empty for none
    jq -nc --arg l "$1" --arg s "$2" --arg m "${3:+<!-- review-run:$3 -->}" \
      '{user: {login: $l, type: "Bot"}, state: $s, body: ("Reviewed `abc1234`.\n\nFindings.\n\n" + $m)}'
  }
  landed() { jq -s --arg pin 'Reviewed `abc1234`' --arg login 'reviewer[bot]' --arg run '<!-- review-run:42-1 -->' "$landed_filter"; }
  n=$({ mine 'reviewer[bot]' CHANGES_REQUESTED ""; mine 'reviewer[bot]' DISMISSED 41-1; mine 'reviewer[bot]' APPROVED 42-2
        mine 'reviewer[bot]' APPROVED 42-10; mine 'reviewer[bot]' APPROVED 4-1; } | landed)
  [ "$n" -eq 0 ] && pass "an earlier review on the head, or another run's or attempt's, is not this run's" \
    || fail "the lookup counted $n reviews that this run did not post"
  n=$({ mine 'reviewer[bot]' CHANGES_REQUESTED ""; mine 'reviewer[bot]' APPROVED 42-1; } | landed)
  [ "$n" -eq 1 ] && pass "a review carrying this run's marker landed" || fail "this run's own review was not found"
  n=$(mine 'other-app[bot]' APPROVED 42-1 | landed)
  [ "$n" -eq 0 ] && pass "another app's review with this run's marker does not count" || fail "another app's review counted"
fi
# The marker is written where the review body is built, from the same two variables the lookup reads.
if grep -q "review-run:%s-%s -->" "$workflow" && grep -q '"\$GITHUB_RUN_ID" "\$GITHUB_RUN_ATTEMPT"' "$workflow"; then
  pass "the posted review carries the run's marker"
else
  fail "the posted review no longer carries the run's marker"
fi

if [ "$failures" -gt 0 ]; then echo "$failures failure(s)"; exit 1; fi
echo "all passed"
