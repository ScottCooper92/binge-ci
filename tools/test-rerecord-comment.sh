#!/usr/bin/env bash
#
# Holds the screenshot re-record path of author-ci-fix.yml. When a caller opts in with
# rerecord_screenshots, the bot pushes new reference frames and the PR gets a comment with the before
# and after of each. That comment is built by the workflow from the pushed commit's own diff, never
# from what the agent says, so a person (and the review bot) can look at exactly the frames that
# changed. This runs the builder against scratch repositories and checks the prompt's gate and the
# review bot's instructions.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
workflow="$root/.github/workflows/author-ci-fix.yml"
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
failures=0
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
pass() { echo "ok    $1"; }
expect() { # $1=description  $2=shell condition
  if (set -e; eval "$2") > /dev/null 2>&1; then pass "$1"; else fail "$1"; fi
}

# The builder, read out of the workflow between its markers, so this tests what runs.
awk '/# bound:rerecord-begin/ {on = 1; next} /# bound:rerecord-end/ {exit} on {sub(/^          /, ""); print}' "$workflow" > "$work/fn.sh"
if [ "$(grep -c 'bound:rerecord-begin' "$workflow")" -ne 1 ] || ! grep -q '^rerecord_section()' "$work/fn.sh"; then
  fail "rerecord_section is not in the workflow exactly once"
  exit 1
fi
# shellcheck source=/dev/null
. "$work/fn.sh"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=Dev GIT_AUTHOR_EMAIL=dev@example.com GIT_COMMITTER_NAME=Dev GIT_COMMITTER_EMAIL=dev@example.com

# A repository whose base has two frames, then a PR commit that the bot's re-record follows.
repo="$work/repo"
git init -q -b main "$repo"
cd "$repo"
mkdir -p "app/src/test/snapshots/images"
printf 'home-old' > "app/src/test/snapshots/images/Home_Default.png"
printf 'home-dark-old' > "app/src/test/snapshots/images/Home Dark.png"
printf 'detail-old' > "app/src/test/snapshots/images/Detail.png"
git add -A && git commit -q -m base
merge_base=$(git rev-parse HEAD)
printf 'a change to the screen\n' > Home.kt
git add -A && git commit -q -m "feat: change the home screen"
before=$(git rev-parse HEAD)

tsv="$work/rerecord.tsv"
section() { rerecord_section "$merge_base" "$before" "o/r" "https://github.com" "$tsv"; }

echo "-- modified frames"
printf 'home-new' > "app/src/test/snapshots/images/Home_Default.png"
printf 'home-dark-new' > "app/src/test/snapshots/images/Home Dark.png"
git add -A && git commit -q -m "fix: address CI failure"
head=$(git rev-parse HEAD); export head
printf 'app/src/test/snapshots/images/Home_Default.png\t84.2\napp/src/test/snapshots/images/Home Dark.png\tnot a number\napp/src/test/snapshots/images/Detail.png\t3\n' > "$tsv"
out=$(section); export out
expect "  carries the marker keyed to the pushed commit" 'head -n 1 <<<"$out" | grep -qx "<!-- ci-fix-rerecord:$head -->"'
expect "  lists exactly the frames the commit changed, not the one the agent also named" '
  [ "$(grep -c "^| \`app/" <<<"$out")" -eq 2 ] && grep -q "Home_Default.png" <<<"$out" && ! grep -q "Detail.png" <<<"$out"'
expect "  a name with a space is linked, encoded" 'grep -qF "blob/$head/app/src/test/snapshots/images/Home%20Dark.png?raw=true" <<<"$out"'
expect "  before is the frame at the merge base, after the frame at the head" '
  grep -qF "blob/$merge_base/app/src/test/snapshots/images/Home_Default.png?raw=true" <<<"$out" &&
  grep -qF "blob/$head/app/src/test/snapshots/images/Home_Default.png?raw=true" <<<"$out"'
expect "  the agent's percentage is shown for a frame it names, and 'not reported' when it is not a number" '
  grep -q "Home_Default.png.*| 84.2% |$" <<<"$out" && grep -q "Home Dark.png.*| not reported |$" <<<"$out"'
expect "  says the percentages are the agent's, not measured" 'grep -q "reported from the CI log, not measured here" <<<"$out"'
expect "  does not flag a commit that only modifies frames" '! grep -q "adds or deletes" <<<"$out"'
rm -f "$tsv"
out=$(section); export out
expect "  with no file from the agent every frame is still listed, with no percentage" '[ "$(grep -c "not reported |$" <<<"$out")" -eq 2 ]'

echo "-- an added and a deleted frame"
printf 'brand-new' > "app/src/test/snapshots/images/Extra.png"
git rm -q "app/src/test/snapshots/images/Detail.png"
git add -A && git commit -q -m "fix: more"
out=$(section); export out
expect "  both are called out in bold" 'grep -q "^\*\*This commit adds or deletes a frame" <<<"$out"'
expect "  a new frame has no before, a deleted one no after" '
  grep -q "Extra.png.*none (new frame)" <<<"$out" && grep -q "Detail.png.*| deleted |" <<<"$out"'

echo "-- nothing re-recorded"
git checkout -q -b other "$before"
printf 'a source fix\n' > Fix.kt
git add -A && git commit -q -m "fix: source"
out=$(section); export out
expect "  a commit with no PNG changes produces no comment at all" '[ -z "$out" ]'
expect "  and an unreadable merge base still lists the frames, saying the before is unavailable" '
  git checkout -q main && git checkout -q -b third && printf "x" > "app/src/test/snapshots/images/Home_Default.png" && git add -A && git commit -q -m x &&
  o=$(rerecord_section "" "HEAD~1" "o/r" "https://github.com" "$work/none.tsv") && grep -q "unavailable" <<<"$o"'

cd "$root"
echo "-- the workflow, the prompt and the review bot"
gate=$(awk '/- name: Describe the screenshot re-record gate/ {on = 1} on {print} /^      # Ships with this repo rather/ {if (on) exit}' "$workflow")
export gate
expect "  the re-record stays opt-in, behind rerecord_screenshots, with no new input" '
  grep -q "inputs.rerecord_screenshots &&" <<<"$gate" && [ "$(grep -c "^      rerecord_screenshots:" "$workflow")" -eq 1 ] && ! grep -q "screenshot_rerecord" "$workflow"'
expect "  the frame cap is 40 and there is no per-frame percentage cap" '
  grep -q "at most 40 failing frames" <<<"$gate" && ! grep -qE "1% of pixels|at most 10 failing" <<<"$gate"'
expect "  a render or out-of-memory failure is a stop, not a diff" 'grep -q "out-of-memory failure, a render" <<<"$gate" && grep -q "Never" <<<"$gate"'
expect "  the agent is asked for the percentages file the step reads" '
  grep -q "runner.temp }}/rerecord.tsv" <<<"$gate" && grep -q "RERECORD_TSV: \${{ runner.temp }}/rerecord.tsv" "$workflow"'
expect "  the comment is added to the final comment, after the push, from the commit" '
  awk "/- name: Commit and push/ {on = 1} on && /git push origin \"HEAD:refs\/heads\/\\\$BRANCH\"/ {pushed = 1} pushed && /rerecord_block=\\\$\(rerecord_section/ {ok = 1} END {exit !ok}" "$workflow" &&
  grep -q "if \[ -n \"\$rerecord_block\" \]; then printf" "$workflow"'
expect "  the repair-default-branch job still never re-records" '! awk "/repair-default-branch:/ {on = 1} on" "$workflow" | grep -q "rerecord"'
expect "  the review bot is told to look at the frames, and the guide says how" '
  grep -q "ci-fix-rerecord:" .github/workflows/bot-review.yml && grep -q "## 2a. Re-recorded screenshot frames" .ai/agents/pr-review-guide.md &&
  grep -q "however large" .ai/agents/pr-review-guide.md && grep -q "adds or deletes a frame is one too" .ai/agents/pr-review-guide.md'

[ "$failures" -eq 0 ] || { echo "$failures failure(s)"; exit 1; }
echo "all passed"
