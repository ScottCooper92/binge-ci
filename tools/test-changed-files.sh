#!/usr/bin/env bash
#
# Holds the changed-files action: the classifier that turns a diff into `product`, `screens` and
# `release`, and the script that picks the diff. A wrong skip is the costly error, since a job that did
# not run cannot fail, so the cases are about what must never be skipped: a path in no set runs the
# Gradle jobs and the frames, the release build runs for exactly its allow-list, and anything the
# script cannot read runs everything.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$root/.github/actions/changed-files"
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
failures=0
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
ok() { echo "ok    $1"; }

export PRODUCT_NONE='# Documentation and tooling nothing compiles.
!tools/build-input.sh
*.md
docs/*
.ai/*
tools/*
.github/ISSUE_TEMPLATE/*'
export NO_FRAMES='app/src/test/*
app/src/androidTest/*
app/src/main/keepRules/*
data/src/test/*
translation-hashes.txt
some-submodule'
export RELEASE_INPUTS='*.pro
app/src/main/keepRules/*
*.gradle.kts
libs.versions.toml
gradle/*
gradle.properties
some-submodule'

# check <name> <expected "product screens release"> <path>...
check() {
  local name="$1" expected="$2" file got
  shift 2
  file="$work/list"
  : > "$file"
  [ "$#" -eq 0 ] || printf '%s\0' "$@" > "$file"
  got="$(bash "$dir/classify-changes.sh" "$file" 2>/dev/null | cut -d= -f2 | tr '\n' ' ' | sed 's/ $//')"
  if [ "$got" = "$expected" ]; then ok "$name"; else fail "$name: expected '$expected', got '$got'"; fi
}

echo "-- the classifier"
check "docs only" "false false false" CLAUDE.md docs/privacy.md .ai/agents/guide.md
check "tooling only" "false false false" tools/x.sh .github/ISSUE_TEMPLATE/bug.md
check "a negated pattern carves a path out of the broad one above it" "true true false" tools/build-input.sh
check "an empty diff runs everything" "true true true"
check "a screen" "true true false" app/src/main/kotlin/ui/HubScreen.kt
check "a path in no set runs the Gradle jobs and the frames" "true true false" something/new/unlisted.txt
check "a workflow runs the Gradle jobs, not R8" "true true false" .github/workflows/ci.yml
check "tests only skip the frames" "true false false" app/src/test/kotlin/x/YTest.kt
check "a * crosses a slash" "true false false" app/src/test/kotlin/deep/er/YTest.kt
check "a keep rule reaches R8 and moves no frame" "true false true" app/src/main/keepRules/app.pro
check "a pro file outside the keep rules" "true true true" app/proguard-rules.pro
check "a build file" "true true true" data/build.gradle.kts
check "the version catalog" "true true true" libs.versions.toml
check "gradle.properties" "true true true" gradle.properties
check "a submodule pin" "true false true" some-submodule
check "docs beside a screen" "true true false" CLAUDE.md app/src/main/kotlin/ui/HubScreen.kt
check "one frame-moving path among tests" "true true false" app/src/test/kotlin/x/YTest.kt app/src/main/res/values/strings.xml
check "a UI change skips R8" "true true false" app/src/main/kotlin/ui/HubScreen.kt app/src/main/res/values/strings.xml
check "a path with a non-ASCII character is matched as it is" "true false true" $'app/src/main/keepRules/r\u00e8gles.pro'
check "a path with a newline in it is one path" "true true true" $'a\nb.gradle.kts'

echo "-- whitespace around a pattern"
printf 'app/proguard-rules.pro\0' > "$work/list"
for variant in $'*.pro \n*.gradle.kts' $'*.pro\r\n*.gradle.kts\r' $'  *.pro\n    *.gradle.kts' $'\t*.pro\t'; do
  got="$(RELEASE_INPUTS="$variant" bash "$dir/classify-changes.sh" "$work/list" | tr '\n' ' ')"
  [ "$got" = "product=true screens=true release=true " ] && ok "a release pattern with stray whitespace still matches ($(printf '%q' "$variant"))" || fail "stray whitespace dropped a release rule ($(printf '%q' "$variant")): '$got'"
done
got="$(PRODUCT_NONE=$'docs/* \r' RELEASE_INPUTS='x' bash "$dir/classify-changes.sh" <(printf 'docs/a.md\0') | tr '\n' ' ')"
[ "$got" = "product=false screens=false release=false " ] && ok "and so does a skip pattern" || fail "a skip pattern with stray whitespace was dropped: '$got'"
got="$(PRODUCT_NONE='gradle/*' bash "$dir/classify-changes.sh" <(printf 'gradle/wrapper/x.properties\0') | tr '\n' ' ')"
[ "$got" = "product=false screens=false release=false " ] && ok "a path in both product_none and release_inputs does not reach the release build" || fail "product_none did not win: '$got'"

for bang in '! tools/build-input.sh' $'!\ttools/build-input.sh' '!   tools/build-input.sh'; do
  got="$(PRODUCT_NONE="$bang"$'\ntools/*' bash "$dir/classify-changes.sh" <(printf 'tools/build-input.sh\0') | tr '\n' ' ')"
  [ "$got" = "product=true screens=true release=false " ] && ok "a carve-out with whitespace after the ! still carves ($(printf '%q' "$bang"))" || fail "whitespace after the ! dropped the carve-out ($(printf '%q' "$bang")): '$got'"
done
got="$(PRODUCT_NONE='!' bash "$dir/classify-changes.sh" <(printf 'a.kt\0') | tr '\n' ' ')"
[ "$got" = "product=true screens=true release=false " ] && ok "a bare ! matches nothing and skips nothing" || fail "a bare ! changed the answer: '$got'"

echo "-- empty lists"
: > "$work/list"; printf 'a.kt\0' > "$work/list"
got="$(PRODUCT_NONE='' NO_FRAMES='' bash "$dir/classify-changes.sh" "$work/list" | tr '\n' ' ')"
[ "$got" = "product=true screens=true release=false " ] && ok "empty skip lists skip nothing" || fail "empty skip lists gave '$got'"
if RELEASE_INPUTS='' bash "$dir/classify-changes.sh" "$work/list" > /dev/null 2>&1; then fail "an empty release allow-list was accepted"; else ok "an empty release allow-list is an error, not a release build that never runs"; fi
if env -u RELEASE_INPUTS bash "$dir/classify-changes.sh" "$work/list" > /dev/null 2>&1; then fail "an unset release allow-list was accepted"; else ok "and so is an unset one"; fi

echo "-- the diff"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=Dev GIT_AUTHOR_EMAIL=dev@example.com GIT_COMMITTER_NAME=Dev GIT_COMMITTER_EMAIL=dev@example.com
origin="$work/origin.git"
git init -q --bare -b main "$origin"
repo="$work/repo"
git clone -q "$origin" "$repo" 2> /dev/null
cd "$repo"
git checkout -q -b main
mkdir -p docs app/src/main
echo base > README.md
git add -A && git commit -q -m base && git push -q origin main
git checkout -q -b feature
echo one > docs/one.md
git add -A && git commit -q -m "docs"
green=$(git rev-parse HEAD)
echo two > app/src/main/A.kt
git add -A && git commit -q -m "code"
head=$(git rev-parse HEAD)

# A gh that answers from files: `run list` prints the lines in runs.txt, `api` the count in jobs-<id>.
stub="$work/bin"
mkdir -p "$stub"
cat > "$stub/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "run list") cat "$STUB_DIR/runs.txt" 2> /dev/null ;;
  api*) id="$(sed -E 's#.*/runs/([0-9]+)/jobs.*#\1#' <<< "$2")"; cat "$STUB_DIR/jobs-$id" 2> /dev/null || echo 0 ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$stub/gh"
export STUB_DIR="$work" PATH="$stub:$PATH"

run() { # $1=event  extra env as VAR=value...; prints the three answers on one line
  local event="$1"
  shift
  : > "$work/out"; : > "$work/summary"
  env EVENT="$event" BASE_REF=main HEAD_REF=feature SAME_REPO=true REPOSITORY=o/r OUT="$work/out" SUMMARY="$work/summary" RUNNER_TEMP="$work" "$@" bash "$dir/changed-files.sh" > /dev/null 2>&1 || echo "(script failed)" >> "$work/out"
  tr '\n' ' ' < "$work/out" | sed 's/ $//'
}
all_true="product=true screens=true release=true"

: > "$work/runs.txt"
[ "$(run push)" = "$all_true" ] && ok "a push runs everything" || fail "a push did not run everything"
[ "$(run schedule)" = "$all_true" ] && ok "so does a schedule" || fail "a schedule did not run everything"
got="$(run pull_request)"
[ "$got" = "product=true screens=true release=false" ] && ok "with no green run, the pull request is diffed against the merge base" || fail "merge base diff gave '$got'"
grep -q "the merge base" "$work/summary" && ok "and the summary says which baseline it used" || fail "the summary does not name the baseline"

printf '%s 11\n' "$green" > "$work/runs.txt"; echo 1 > "$work/jobs-11"
got="$(run pull_request)"
[ "$got" = "product=true screens=true release=false" ] && grep -q "its last green run" "$work/summary" && ok "a green run that is an ancestor is the baseline" || fail "green baseline gave '$got'"
paths() { tr '\0' '\n' < "$work/changed.txt"; }
paths | grep -qx "app/src/main/A.kt" && ! paths | grep -q "docs/one.md" && ok "and only what changed since it is read" || fail "the diff since the green run was wrong"

echo 0 > "$work/jobs-11"
run pull_request > /dev/null
grep -q "the merge base" "$work/summary" && ok "a run whose gate job did not succeed vouches for nothing" || fail "a run without a green gate job was used"

echo 1 > "$work/jobs-11"
got="$(run pull_request SAME_REPO=false)"
grep -q "the merge base" "$work/summary" && ok "a fork's pull request never borrows a green run" || fail "a fork borrowed a green run"

printf '%s 12\n' "$head" > "$work/runs.txt"; echo 1 > "$work/jobs-12"
run pull_request > /dev/null
grep -q "the merge base" "$work/summary" && ok "a green run of the head itself is no baseline" || fail "the head was its own baseline"

git checkout -q main
echo unrelated > unrelated.txt
git add -A && git commit -q -m "unrelated"
sibling=$(git rev-parse HEAD)
git checkout -q feature
printf '%s 13\n' "$sibling" > "$work/runs.txt"; echo 1 > "$work/jobs-13"
run pull_request > /dev/null
grep -q "the merge base" "$work/summary" && ok "a green run that is not an ancestor (a force push) falls back to the merge base" || fail "a non-ancestor was used as a baseline"

: > "$work/runs.txt"
got="$(run pull_request BASE_REF=no-such-branch)"
[ "$got" = "$all_true" ] && ok "a base branch that cannot be found runs everything" || fail "a missing base gave '$got'"

# A file moved out of the build is a deletion from it: both the old and the new path have to be read.
cd "$repo"
git checkout -q main
mkdir -p app/src/main app/src/test docs
echo src > app/src/main/Foo.kt
git add -A && git commit -q -m "add Foo" && git push -q origin main
git checkout -q -b renamer
git mv app/src/main/Foo.kt docs/Foo.kt
git commit -q -m "move Foo into docs"
: > "$work/runs.txt"
got="$(run pull_request PRODUCT_NONE='docs/*' HEAD_REF=renamer)"
[ "$got" = "product=true screens=true release=false" ] && ok "a source file moved into the documentation set still runs the Gradle jobs" || fail "a rename hid its source path: '$got'"
paths | grep -qx "app/src/main/Foo.kt" && paths | grep -qx "docs/Foo.kt" && ok "and the diff lists both sides of the rename" || fail "the diff lists only one side of a rename"
git checkout -q main
git checkout -q -b frames
git mv app/src/main/Foo.kt app/src/test/Foo.kt
git commit -q -m "move Foo into tests"
got="$(run pull_request NO_FRAMES='app/src/test/*' HEAD_REF=frames)"
[ "$got" = "product=true screens=true release=false" ] && ok "a source file moved into a test directory still moves the frames" || fail "a rename into the tests skipped the frames: '$got'"
# git prints a path with a non-ASCII character in quotes unless it is asked for NUL-terminated output, and a
# quoted path matches no pattern: the allow-list would then skip the release build for a keep rule so named.
git checkout -q main
git checkout -q -b accent
mkdir -p keep
echo rule > "keep/règles.pro"
git add -A && git commit -q -m "add a keep rule with an accent"
got="$(run pull_request RELEASE_INPUTS='*.pro' HEAD_REF=accent)"
[ "$got" = "product=true screens=true release=true" ] && ok "a keep rule with a non-ASCII name still runs the release build" || fail "a non-ASCII path was not matched: '$got'"
cd "$root"

mkdir "$work/notgit" && cd "$work/notgit"
got="$(run pull_request)"
[ "$got" = "$all_true" ] && ok "outside a repository it runs everything" || fail "no repository gave '$got'"
cd "$root"

echo "-- the action"
action="$dir/action.yml"
expect() { if (set -e; eval "$2") > /dev/null 2>&1; then ok "$1"; else fail "$1"; fi }
expect "every input reaches the script through env, with no expression in the run block" '
  python3 - "$0" <<PY
import sys, re
text = open("'"$action"'").read()
run = text.split("      run: ", 1)[1]
sys.exit(1 if "\${{" in run else 0)
PY'
expect "the release allow-list is required and the others are optional" '
  python3 - <<PY
import re
t = open("'"$action"'").read()
block = lambda n: re.search(r"^  " + n + r":\n((?:    .*\n)+)", t, re.M).group(1)
assert "required: true" in block("release_inputs")
assert "required: false" in block("product_none") and "required: false" in block("no_frames")
PY'
expect "the three outputs read the step's" '
  for o in product screens release; do grep -q "value: \${{ steps.classify.outputs.$o }}" "'"$action"'"; done'

[ "$failures" -eq 0 ] || { echo "$failures failure(s)"; exit 1; }
echo "all passed"
