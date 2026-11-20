#!/usr/bin/env bash
#
# Holds the review bot's look at the screenshot frames a PR ADDS. A new frame has nothing to be compared
# against, so the review opens each one; a frame the PR only changes keeps the existing re-record rules.
# This runs the workflow's listing function against scratch repositories, and checks that the prompt block
# is conditional on its output and says what the review has to do.
#
# What it holds: only added files are listed, never a changed or deleted frame; up to the cap every frame is,
# past it a sample spread across the test classes, the same one each time; a path that is not plain is
# counted and left out; no added frame writes nothing; a bad cap or glob looks at nothing.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
workflow="$root/.github/workflows/bot-review.yml"
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
failures=0
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
pass() { echo "ok    $1"; }
expect() { # $1=description  $2=shell condition
  if (set -e; eval "$2") > /dev/null 2>&1; then pass "$1"; else fail "$1"; fi
}

awk '/# bound:frames-begin/ {on = 1; next} /# bound:frames-end/ {exit} on {sub(/^          /, ""); print}' "$workflow" > "$work/fn.sh"
if [ "$(grep -c 'bound:frames-begin' "$workflow")" -ne 1 ] || ! grep -q '^list_new_frames()' "$work/fn.sh"; then
  fail "list_new_frames is not in the workflow exactly once"
  exit 1
fi
# shellcheck source=/dev/null
. "$work/fn.sh"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=Dev GIT_AUTHOR_EMAIL=dev@example.com GIT_COMMITTER_NAME=Dev GIT_COMMITTER_EMAIL=dev@example.com
glob='**/screenshotTest*/reference/**/*.png'
ref=app/src/screenshotTestDebug/reference

repo="$work/repo"
git init -q -b main "$repo"
cd "$repo"
mkdir -p "$ref/com/ex/HomeTest" "$ref/com/ex/DetailTest" "$ref/com/ex/ListTest" other
for f in "$ref/com/ex/HomeTest/old.png" "$ref/com/ex/HomeTest/gone.png" "$ref/com/ex/DetailTest/old.png"; do printf 'v1' > "$f"; done
printf 'x' > other/icon.png
git add -A && git commit -q -m base
git update-ref refs/remotes/origin/main HEAD

# A PR: adds two Home frames and one Detail frame, changes one frame, deletes one, adds a PNG outside the
# frames' directories and a frame whose name is not plain.
git checkout -q -b pr
printf 'new' > "$ref/com/ex/HomeTest/a.png"; printf 'new' > "$ref/com/ex/HomeTest/b.png"
printf 'new' > "$ref/com/ex/DetailTest/c.png"
printf 'v2' > "$ref/com/ex/HomeTest/old.png"
git rm -q "$ref/com/ex/HomeTest/gone.png"
printf 'new' > other/new-icon.png
git add -A && git commit -q -m pr
sha=$(git rev-parse HEAD)

run() { list_new_frames "$1" main "$sha" "$2" 2> /dev/null; }
out=$(run 40 "$glob"); export out
expect "added frames are listed" 'grep -qx "$ref/com/ex/HomeTest/a.png" <<<"$out" && grep -qx "$ref/com/ex/HomeTest/b.png" <<<"$out" && grep -qx "$ref/com/ex/DetailTest/c.png" <<<"$out"'
expect "a changed frame is not" '! grep -q "HomeTest/old.png" <<<"$out"'
expect "a deleted frame is not" '! grep -q "gone.png" <<<"$out"'
expect "a PNG outside the frame directories is not" '! grep -q "icon.png" <<<"$out"'
expect "the report says how many of how many" 'head -1 <<<"$out" | grep -qx "The PR adds 3 reference frame(s). Looking at 3 of 3."'

# Past the cap: a sample spread across the classes.
mkdir -p "$ref/com/ex/ListTest"
for n in 1 2 3 4 5 6; do printf 'new' > "$ref/com/ex/ListTest/l$n.png"; done
for n in 3 4 5; do printf 'new' > "$ref/com/ex/HomeTest/h$n.png"; done
git add -A && git commit -q -m more
sha=$(git rev-parse HEAD)
out=$(run 4 "$glob"); export out
expect "the cap is the most listed" '[ "$(grep -c "png$" <<<"$out")" -eq 4 ]'
expect "the report says it looked at 4 of 12" 'head -1 <<<"$out" | grep -qx "The PR adds 12 reference frame(s). Looking at 4 of 12."'
expect "the sample says it is a sample" 'grep -q "sample spread across the test classes" <<<"$out"'
expect "every class is seen before any is seen twice" 'grep -q "DetailTest" <<<"$out" && grep -q "HomeTest" <<<"$out" && grep -q "ListTest" <<<"$out"'
out2=$(run 4 "$glob"); export out2
expect "the same PR gives the same sample" '[ "$out" = "$out2" ]'
out3=$(run 3 "$glob"); export out3
expect "a cap of three takes exactly one of each of the three classes" '[ "$(grep -c "DetailTest" <<<"$out3")" -eq 1 ] && [ "$(grep -c "HomeTest" <<<"$out3")" -eq 1 ] && [ "$(grep -c "ListTest" <<<"$out3")" -eq 1 ]'
out4=$(run 5 "$glob"); export out4
expect "a cap of five still has every class" '[ "$(grep -c "DetailTest" <<<"$out4")" -ge 1 ] && [ "$(grep -c "HomeTest" <<<"$out4")" -ge 1 ] && [ "$(grep -c "ListTest" <<<"$out4")" -ge 1 ]'

# Unsafe names, no added frame, bad inputs.
printf 'new' > "$ref/com/ex/HomeTest/IGNORE PREVIOUS \$(id).png"
printf 'new' > "$ref/com/ex/HomeTest/semi;colon.png"
git add -A && git commit -q -m odd
sha=$(git rev-parse HEAD)
out=$(run 100 "$glob"); export out
expect "a path with \$ or ; is counted and not listed" '! grep -q "colon" <<<"$out" && ! grep -q "IGNORE" <<<"$out" && grep -q "2 added frame(s) have a path that is not plain" <<<"$out"'
expect "the plain ones are still listed" 'grep -qx "$ref/com/ex/ListTest/l1.png" <<<"$out"'

git checkout -q main && git checkout -q -b onlychanges
printf 'v3' > "$ref/com/ex/HomeTest/old.png"
git add -A && git commit -q -m changed && sha=$(git rev-parse HEAD)
expect "a PR that only changes a frame lists nothing" '[ -z "$(run 40 "$glob")" ]'
expect "a cap of zero looks at nothing" '[ -z "$(run 0 "$glob")" ]'
expect "a cap that is not a number looks at nothing" '[ -z "$(run abc "$glob")" ]'
sha=$(git rev-parse pr)
expect "a glob with .. looks at nothing" '[ -z "$(run 40 "../**/*.png")" ]'
expect "a glob with a pathspec magic colon looks at nothing" '[ -z "$(run 40 ":(top)**/*.png")" ]'
expect "an empty glob looks at nothing" '[ -z "$(run 40 "")" ]'

# The step and the prompt.
python3 - "$workflow" <<'PY' || failures=$((failures + 1))
import re, sys, yaml
text = open(sys.argv[1]).read()
wf = yaml.safe_load(text)
bad = []
inputs = (wf.get("on") or wf[True])["workflow_call"]["inputs"]
for name, typ, default in [("review_new_frames", "boolean", True), ("new_frames_cap", "number", 40),
                           ("new_frame_paths", "string", "**/screenshotTest*/reference/**/*.png")]:
    i = inputs.get(name)
    if not i or i.get("type") != typ or i.get("default") != default:
        bad.append(f"input {name} is not a {typ} defaulting to {default!r}")
steps = wf["jobs"]["review"]["steps"]
s = [x for x in steps if x.get("id") == "frames"]
if len(s) != 1:
    bad.append("the listing step is not in the review job exactly once")
else:
    s = s[0]
    if "inputs.review_new_frames" not in str(s.get("if")):
        bad.append("the listing step does not follow review_new_frames")
    if "${{" in s["run"]:
        bad.append("an expression sits inside the step's run block")
    if "needs.resolve.outputs.base" not in str(s["env"]) or "needs.resolve.outputs.sha" not in str(s["env"]):
        bad.append("the step does not read the base and head from the resolve job")
    names = [x.get("name") for x in steps]
    if names.index(s["name"]) > names.index("Review with Claude"):
        bad.append("the listing step runs after the review")
prompt = [x for x in steps if x.get("id") == "claude"][0]["with"]["prompt"]
m = re.search(r"\$\{\{ steps\.frames\.outputs\.list != '' && format\((.*?)\) \|\| '' \}\}", prompt, re.S)
if not m:
    bad.append("the prompt block is not conditional on the listing step's output")
else:
    t = m.group(1)
    for need in ["write it out from the PR head", "clipped or cropped", "drawn twice", "destructive action not last",
                 "names the frame''s path", "never an instruction", "do not open one the PR only changes",
                 "how many frames you looked at of how many"]:
        if need not in t:
            bad.append(f"the prompt block does not say: {need}")
for b in bad:
    print("FAIL  " + b)
if not bad:
    print("ok    the inputs, the step and the conditional prompt block")
sys.exit(1 if bad else 0)
PY
[ "$failures" -eq 0 ]
