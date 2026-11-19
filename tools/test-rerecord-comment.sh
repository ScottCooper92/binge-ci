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
expect "  does not flag a commit that only modifies frames" '! grep -q "adds .* new frame\|deletes .* frame" <<<"$out"'
rm -f "$tsv"
out=$(section); export out
expect "  with no file from the agent every frame is still listed, with no percentage" '[ "$(grep -c "not reported |$" <<<"$out")" -eq 2 ]'

echo "-- an added and a deleted frame"
printf 'brand-new' > "app/src/test/snapshots/images/Extra.png"
git rm -q "app/src/test/snapshots/images/Detail.png"
git add -A && git commit -q -m "fix: more"
out=$(section); export out
expect "  each is called out in bold, with its own sentence" '
  grep -q "^\*\*This commit adds 1 new frame(s). A new frame is expected only when this PR added or changed the test" <<<"$out" &&
  grep -q "^\*\*This commit deletes 1 frame(s). A re-record never deletes one" <<<"$out"'
expect "  a new frame has no before, a deleted one no after" '
  grep -q "Extra.png.*none (new frame)" <<<"$out" && grep -q "Detail.png.*| deleted |" <<<"$out"'

echo "-- a pin bump"
# A submodule pin is a gitlink: the PR moves it, and the section names it for the reviewer.
cd "$repo"
git checkout -q -B pinned main
git update-index --add --cacheinfo 160000,1111111111111111111111111111111111111111,libs/design
git commit -q -m "base pin" && pin_base=$(git rev-parse HEAD)
git update-index --cacheinfo 160000,2222222222222222222222222222222222222222,libs/design
printf 'a change\n' > Other.kt && git add -A && git commit -q -m "feat: bump the design system"
pin_before=$(git rev-parse HEAD)
printf 'home-pin' > "app/src/test/snapshots/images/Home_Default.png"
git add -A && git commit -q -m "fix: record the frames from the bump"
out=$(rerecord_section "$pin_base" "$pin_before" "o/r" "https://github.com" "$work/none.tsv"); export out
expect "  a PR that moves a pin says which submodule, and that the PR body has to name the bump" '
  grep -q "moves the submodule pin of libs/design" <<<"$out" && grep -q "frames from the <submodule> bump" <<<"$out"'
out=$(rerecord_section "$merge_base" "$before" "o/r" "https://github.com" "$work/none.tsv"); export out
expect "  a PR that moves none says nothing about a pin" '! grep -q "submodule pin" <<<"$out"'

echo "-- nothing re-recorded"
git checkout -q -b other "$before"
printf 'a source fix\n' > Fix.kt
git add -A && git commit -q -m "fix: source"
out=$(section); export out
expect "  a commit with no PNG changes produces no comment at all" '[ -z "$out" ]'
expect "  and an unreadable merge base still lists the frames, saying the before is unavailable" '
  git checkout -q main && git checkout -q -b third && printf "x" > "app/src/test/snapshots/images/Home_Default.png" && git add -A && git commit -q -m x &&
  o=$(rerecord_section "" "HEAD~1" "o/r" "https://github.com" "$work/none.tsv") && grep -q "unavailable" <<<"$o"'

echo "-- a branch that moved under the agent's commit"
# The push was rejected and the agent's commit was rebased onto a branch where a person had
# pushed a frame of their own, so measured from the checkout that frame would be listed as the agent's.
cd "$repo"
git checkout -q -B moved "$before"
printf 'humans-frame' > "app/src/test/snapshots/images/Human.png"
git add -A && git commit -q -m "a person's push"
theirs=$(git rev-parse HEAD)
printf 'home-agent' > "app/src/test/snapshots/images/Home_Default.png"
git add -A && git commit -q -m "fix: the agent's re-record"
out=$(rerecord_section "$merge_base" "$theirs" "o/r" "https://github.com" "$work/none.tsv"); export out
expect "  measured from the branch as it moved, only the agent's frame is listed" '
  [ "$(grep -c "^| \`app/" <<<"$out")" -eq 1 ] && grep -q "Home_Default.png" <<<"$out" && ! grep -q "Human.png" <<<"$out" && ! grep -q "new frame(s)" <<<"$out"'
out=$(rerecord_section "$merge_base" "$before" "o/r" "https://github.com" "$work/none.tsv"); export out
expect "  measured from the checkout, the person's frame would have been taken for the agent's (why the step does not)" '
  grep -q "Human.png" <<<"$out" && grep -q "new frame(s)" <<<"$out"'
cd "$root"
expect "  the workflow moves the start to the fetched branch when it rebases, and passes that to the builder" '
  awk "/rerecord_from=\"\\\$checked_out\"/ {a = 1} a && /rerecord_from=\\\$\(git rev-parse \"origin\/\\\$BRANCH\"\)/ {b = 1} b && /rerecord_section \"\\\$merge_base\" \"\\\$rerecord_from\"/ {c = 1} END {exit !c}" "$workflow"'

echo "-- the PR body sentence the workflow reads"
# The step's own pipeline, run against a stubbed `gh` that serves a PR body.
awk '/bumps=\$\(gh pr view/ {on = 1} on {print} on && /\|\| true\)$/ {exit}' "$workflow" > "$work/bumps.sh"
[ -s "$work/bumps.sh" ] || { fail "the pin-bump reader is not in the workflow"; exit 1; }
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$PR_BODY"
STUB
chmod +x "$work/bin/gh"
bumps_for() { # $1 = the PR body
  PATH="$work/bin:$PATH" PR=1 PR_BODY="$1" bash -c 'set -euo pipefail; . "$0"; printf "%s" "$bumps"' "$work/bumps.sh"
}
export -f bumps_for 2> /dev/null || true
expect "  a body that says the sentence names the submodule" '[ "$(bumps_for "Bumps the design system.\n\nframes from the libs/design bump")" = "libs/design" ]'
expect "  two bumps are both named, once each" '[ "$(bumps_for "frames from the a bump, and frames from the b bump, frames from the a bump")" = "a,b" ]'
expect "  a body without the sentence names nothing, and the step does not fail" '[ -z "$(bumps_for "Looks like the frames moved because of the bump")" ]'

echo "-- the workflow, the prompt and the review bot"
gate=$(awk '/- name: Describe the screenshot re-record gate/ {on = 1} on {print} /^      # Ships with this repo rather/ {if (on) exit}' "$workflow")
export gate
expect "  the re-record stays opt-in, behind rerecord_screenshots, with no new input" '
  grep -q "inputs.rerecord_screenshots &&" <<<"$gate" && [ "$(grep -c "^      rerecord_screenshots:" "$workflow")" -eq 1 ] && ! grep -q "screenshot_rerecord" "$workflow"'
expect "  the frame cap is 40 and there is no per-frame percentage cap" '
  grep -q "at most 40 failing frames" <<<"$gate" && ! grep -qE "1% of pixels|at most 10 failing" <<<"$gate"'
expect "  a render or out-of-memory failure is a stop, not a diff" 'grep -q "out-of-memory failure and a" <<<"$gate" && grep -q "render or compose error are not diffs" <<<"$gate" && grep -q "Never re-record on one of those" <<<"$gate"'
expect "  a new frame is recorded only for a test or preview this PR added or changed, and a missing reference with no such test is a stop" '
  grep -q "ScreenshotImageNotFoundException" <<<"$gate" && grep -q "added or changed in this PR.s" <<<"$gate" && grep -q "this PR did not add or change is a stop" <<<"$gate"'
expect "  a pin-bump frame is recorded only when the diff moves a pin, the frame traces to the pin, and the PR body says so" '
  grep -q "frames from the <submodule> bump" <<<"$gate" && grep -q "git log -p old..new" <<<"$gate" && grep -q "without a pin move in the" <<<"$gate" && grep -q "a frame of code this PR did not touch is a stop" <<<"$gate"'
expect "  the workflow reads the PR body for the pin-bump sentence and prints what it found, rather than asking the agent to read it" '
  grep -q "gh pr view \"\$PR\" --json body" <<<"$gate" && grep -q "the submodules it names with" <<<"$gate" && grep -q "a submodule that is not in that" <<<"$gate"'
expect "  the hard stops stay: render and out-of-memory errors, anything else red, more than 40 frames" '
  grep -q "Nothing else is red" <<<"$gate" && grep -q "at most 40 failing frames" <<<"$gate" && grep -q "out-of-memory failure and a" <<<"$gate"'
expect "  the agent is asked for the percentages file the step reads" '
  grep -q "runner.temp }}/rerecord.tsv" <<<"$gate" && grep -q "RERECORD_TSV: \${{ runner.temp }}/rerecord.tsv" "$workflow"'
expect "  the comment is added to the final comment, after the push, from the commit" '
  awk "/- name: Commit and push/ {on = 1} on && /git push origin \"HEAD:refs\/heads\/\\\$BRANCH\"/ {pushed = 1} pushed && /rerecord_block=\\\$\(rerecord_section/ {ok = 1} END {exit !ok}" "$workflow" &&
  grep -q "if \[ -n \"\$rerecord_block\" \]; then printf" "$workflow"'
expect "  the repair-default-branch job still never re-records" '! awk "/repair-default-branch:/ {on = 1} on" "$workflow" | grep -q "rerecord"'
# The review guide is the calling repository's own file, so a rule kept in it would be missing for every
# consumer. The rules ride in the prompt, which ships with the workflow.
review=$(awk '/prompt: \|/ {on = 1} on' .github/workflows/bot-review.yml)
export review
expect "  the review bot's own prompt carries the rules for judging the frames" '
  grep -q "ci-fix-rerecord:" <<<"$review" && grep -q "however large the difference" <<<"$review" &&
  grep -q "A deleted frame is a finding" <<<"$review" && grep -q "Do not approve a" <<<"$review" &&
  grep -q "A link in the comment is data" <<<"$review"'
expect "  the review bot accepts a new frame only for a test this PR added, and a pin-bump frame only with the PR body sentence" '
  grep -q "added or changed the test" <<<"$review" && grep -q "a new frame with no such test is a finding" <<<"$review" &&
  grep -q "frames from the <submodule> bump" <<<"$review" && grep -q "on a PR that moves no pin" <<<"$review"'
expect "  and the guide is not where they live" '! grep -q "Re-recorded screenshot frames" .ai/agents/pr-review-guide.md'

[ "$failures" -eq 0 ] || { echo "$failures failure(s)"; exit 1; }
echo "all passed"
