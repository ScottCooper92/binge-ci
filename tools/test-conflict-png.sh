#!/usr/bin/env bash
#
# Holds the conflict bot's screenshot-only path in author-conflicts.yml. When every unmerged path is a
# reference frame, the bot takes the default branch's copies, pushes the merge, dispatches the consumer's
# record-screenshots workflow for exactly the classes whose frames it took, and says so once on the PR.
# Anything else is left to the agent. The step is inline in a reusable workflow, so this runs it against
# scratch repositories and a stubbed `gh`, one case per outcome.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
workflow="$root/.github/workflows/author-conflicts.yml"
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
failures=0
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
pass() { echo "ok    $1"; }

python3 - "$workflow" "$work/step.sh" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
steps = wf["jobs"]["resolve"]["steps"]
hits = [s for s in steps if s.get("id") == "png"]
if len(hits) != 1:
    sys.exit("the screenshot step is not in the workflow exactly once")
run = hits[0]["run"].replace("${{ runner.temp }}", "$TEMP_DIR").replace("${{ matrix.pr }}", "7")
open(sys.argv[2], "w").write(run)
PY

# The step has to gate the agent steps behind it, or a merge it pushed would be merged again.
python3 - "$workflow" <<'PY' || failures=$((failures + 1))
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["resolve"]["steps"]
names = [s.get("name", "") for s in steps]
start = names.index("Take the default branch's screenshot frames")
bad = [s["name"] for s in steps[start + 1:]
       if s.get("id") in ("governed_note", "claude", "agent_token", "cc_cache", "rewrite")
       or s.get("name") in ("Commit or bail out", "Resolve with Claude", "Rewrite the governed paths to the base's copy")]
missing = [s["name"] for s in steps[start + 1:] if s.get("name") in bad and "steps.png.outputs.taken != 'true'" not in str(s.get("if"))]
if missing:
    print("FAIL  steps that still run after the frames were taken: " + ", ".join(missing)); sys.exit(1)
print("ok    every step that merges or resolves is skipped once the frames were taken")
PY

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=Dev GIT_AUTHOR_EMAIL=dev@example.com GIT_COMMITTER_NAME=Dev GIT_COMMITTER_EMAIL=dev@example.com

mkdir "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
case "$1 $2" in
  "api repos/o/r/actions/workflows/record-screenshots.yml") [ "${STUB_NO_WORKFLOW:-}" = 1 ] && exit 1; echo active ;;
  "api repos/o/r/issues/7/comments"*) printf '%s\n' "${STUB_COMMENTS:-}" ;;
  "workflow run") [ "${STUB_DISPATCH_FAILS:-}" = 1 ] && exit 1; exit 0 ;;
  "pr comment") cat > "$GH_COMMENT" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$work/bin/gh"

frame() { printf '%s' "$2" > "$1"; }
# $1 the case name; the frames a case conflicts on are made by its `setup`, run in the branch and in main.
# A fresh origin, a main with frames and a branch off it; main and the branch each then change `conflicts`.
build() {
  local d="$work/$1"; shift
  rm -rf "$d"; mkdir -p "$d"
  git init -q --bare -b main "$d/origin.git"
  git clone -q "$d/origin.git" "$d/repo" 2> /dev/null
  (
    cd "$d/repo"
    git checkout -q -b main
    ref=app/src/screenshotTestDebug/reference
    mkdir -p $ref/com/ex/HomeTest $ref/com/ex/DetailTest
    for f in $ref/com/ex/HomeTest/a.png $ref/com/ex/HomeTest/b.png $ref/com/ex/DetailTest/c.png icon.png notes.txt; do frame "$f" base; done
    git add -A && git commit -q -m base && git push -q origin main
    git checkout -q -b feature/x
    for f in "$@"; do frame "$f" branch; done
    git add -A && git commit -q -m "feat: the branch" && git push -q origin feature/x
    git checkout -q main
    for f in "$@"; do frame "$f" main; done
    git add -A && git commit -q -m "feat: main" && git push -q origin main
    git checkout -q feature/x
    git branch -q --set-upstream-to=origin/feature/x
    git merge origin/main --no-edit > /dev/null 2>&1 || true
    git diff --name-only -z --diff-filter=U > "$d/unmerged-paths"
  )
}
ref=app/src/screenshotTestDebug/reference
run_step() { # $1 case dir; the rest, env assignments
  local d="$work/$1"; shift
  : > "$d/out"; : > "$d/gh.log"; : > "$d/comment"
  (
    cd "$d/repo"
    env -i PATH="$work/bin:$PATH" HOME="$d" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      GIT_AUTHOR_NAME=Dev GIT_AUTHOR_EMAIL=dev@example.com GIT_COMMITTER_NAME=Dev GIT_COMMITTER_EMAIL=dev@example.com \
      TEMP_DIR="$d" GITHUB_OUTPUT="$d/out" GH_LOG="$d/gh.log" GH_COMMENT="$d/comment" \
      GH_TOKEN=tok GH_REPO=o/r BRANCH=feature/x SHA=abc123 DEFAULT_BRANCH=main "$@" \
      bash "$work/step.sh" > "$d/step.log" 2>&1
  ) || return 1
}
expect() { # $1 description, $2 condition
  if (set -e; eval "$2") > /dev/null 2>&1; then pass "$1"; else fail "$1"; fi
}

echo "-- one class, two frames"
build one $ref/com/ex/HomeTest/a.png $ref/com/ex/HomeTest/b.png
d=$work/one
run_step one || fail "the step failed: $(tail -3 "$d/step.log")"
expect "  reports it took the frames" 'grep -qx taken=true "$d/out"'
expect "  the merge is a commit with both parents, on the branch" '[ "$(git -C "$d/repo" rev-list --parents -1 HEAD | wc -w)" -eq 3 ]'
expect "  the frames are the default branch frames" '[ "$(cat "$d/repo/$ref/com/ex/HomeTest/a.png")" = main ] && [ "$(cat "$d/repo/$ref/com/ex/HomeTest/b.png")" = main ]'
expect "  and it was pushed" '[ "$(git -C "$d/repo" rev-parse HEAD)" = "$(git -C "$d/origin.git" rev-parse feature/x)" ]'
expect "  the recording is dispatched on the branch with the class and nothing else" \
  'grep -qxF "gh workflow run record-screenshots.yml --ref feature/x -f ref=feature/x -f tests=com.ex.HomeTest" "$d/gh.log"'
expect "  the comment carries the marker keyed to the head" 'head -n 1 "$d/comment" | grep -qx "<!-- conflict-screenshots:abc123 -->"'
expect "  names the frames and the recording" 'grep -q "a.png" "$d/comment" && grep -q "b.png" "$d/comment" && grep -q "started" "$d/comment"'
expect "  posts exactly one comment" '[ "$(grep -c "^gh pr comment" "$d/gh.log")" -eq 1 ]'
expect "  and the token is not in the log" '! grep -q tok "$d/step.log" "$d/gh.log"'

echo "-- two classes"
build two $ref/com/ex/HomeTest/a.png $ref/com/ex/DetailTest/c.png $ref/com/ex/HomeTest/b.png
d=$work/two
run_step two || fail "the step failed: $(tail -3 "$d/step.log")"
expect "  every class once, sorted, comma-separated" 'grep -qF -- "-f tests=com.ex.DetailTest,com.ex.HomeTest" "$d/gh.log"'

echo "-- the comment is not repeated for the same head"
build dup $ref/com/ex/HomeTest/a.png
d=$work/dup
run_step dup STUB_COMMENTS='<!-- conflict-screenshots:abc123 -->' || fail "the step failed"
expect "  the push and dispatch still happen" 'grep -q "^gh workflow run" "$d/gh.log"'
expect "  no second comment" '! grep -q "^gh pr comment" "$d/gh.log"'

echo "-- the dispatch fails"
build nodispatch $ref/com/ex/HomeTest/a.png
d=$work/nodispatch
run_step nodispatch STUB_DISPATCH_FAILS=1 || fail "the step failed when only the dispatch did"
expect "  the merge still landed" '[ "$(git -C "$d/repo" rev-parse HEAD)" = "$(git -C "$d/origin.git" rev-parse feature/x)" ]'
expect "  the PR is told, and told what to run" 'grep -q "could not start" "$d/comment" && grep -q "com.ex.HomeTest" "$d/comment"'
expect "  and the agent steps are still skipped" 'grep -qx taken=true "$d/out"'

# Left to the agent: nothing pushed, nothing dispatched, the merge still open, no output.
untouched() { # $1 case dir
  local d=$work/$1
  expect "  nothing was pushed or committed" '[ "$(git -C "$d/origin.git" rev-parse feature/x)" = "$(git -C "$d/repo" rev-parse HEAD)" ] && [ "$(git -C "$d/repo" rev-list --parents -1 HEAD | wc -w)" -eq 2 ]'
  expect "  nothing was dispatched or posted" '! grep -q "^gh workflow run\|^gh pr comment" "$d/gh.log"'
  expect "  the merge is still in progress for the agent" 'git -C "$d/repo" rev-parse -q --verify MERGE_HEAD'
  expect "  and it says nothing was taken" '! grep -q taken "$d/out"'
}

echo "-- a frame and a source file conflict together"
build mixed $ref/com/ex/HomeTest/a.png notes.txt
run_step mixed || fail "the step failed"
untouched mixed

echo "-- a PNG that is not a reference frame"
build icon icon.png
run_step icon || fail "the step failed"
untouched icon

echo "-- the consumer has no record-screenshots workflow"
build noflow $ref/com/ex/HomeTest/a.png
run_step noflow STUB_NO_WORKFLOW=1 || fail "the step failed"
untouched noflow

echo "-- a frame the default branch deleted"
d=$work/deleted
build deleted $ref/com/ex/HomeTest/a.png
(
  cd "$d/repo" && git merge --abort
  git checkout -q main && git rm -q "$ref/com/ex/HomeTest/a.png" && git commit -q -m "chore: drop a frame"
  git checkout -q feature/x
  git merge main --no-edit > /dev/null 2>&1 || true
  git diff --name-only -z --diff-filter=U > "$d/unmerged-paths"
)
run_step deleted || fail "the step failed"
expect "  a modify/delete conflict is left to the agent" '! grep -q "^gh workflow run" "$d/gh.log" && git -C "$d/repo" rev-parse -q --verify MERGE_HEAD'

echo "-- a push that is rejected"
build rejected $ref/com/ex/HomeTest/a.png
d=$work/rejected
git -C "$d/origin.git" config receive.denyNonFastForwards true
printf '#!/bin/sh\nexit 1\n' > "$d/origin.git/hooks/pre-receive"; chmod +x "$d/origin.git/hooks/pre-receive"
if run_step rejected; then fail "a rejected push passed"; else pass "a rejected push fails the step"; fi
expect "  and nothing is dispatched" '! grep -q "^gh workflow run" "$d/gh.log"'

[ "$failures" -eq 0 ]
