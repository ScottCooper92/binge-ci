#!/usr/bin/env bash
#
# Holds the pin-only action: the answer that lets a consumer's pin update merge without a human reading its workflow
# edits. A false `true` here lets an arbitrary workflow change through, so the cases are about what must stay false:
# a pin to a commit no release tag names, a pin to `v1`, a workflow edit beside the pin, and every other kind of
# change. Anything it cannot read has to be `false` too.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/.github/actions/pin-only/pin-only.sh"
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
failures=0
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
ok() { echo "ok    $1"; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=Dev GIT_AUTHOR_EMAIL=dev@example.com GIT_COMMITTER_NAME=Dev GIT_COMMITTER_EMAIL=dev@example.com

# binge-ci's own repository: c1 and c2 are tagged releases on main, c3 is a commit on main no tag names, and
# c4 carries a tag on a side branch that never reached main.
up="$work/binge-ci.git"
src="$work/src"
git init -q -b main "$src"
cd "$src"
n=0
commit() { n=$((n + 1)); echo "$n" > f; git add -A; git commit -q -m "c$n"; last=$(git rev-parse HEAD); }
commit; c1=$last; git tag v1.0.1
commit; c2=$last; git tag v1.0.2
commit; c3=$last
commit; c5=$last; git tag v1.0.3
git checkout -q -b side
commit; c4=$last; git tag v1.0.9
git checkout -q main
git clone -q --bare "$src" "$up"
git -C "$up" fetch -q "$src" 'refs/tags/*:refs/tags/*' 'refs/heads/side:refs/heads/side'

# A consumer repository that pins binge-ci at c1.
repo="$work/repo"
git init -q -b main "$repo"
cd "$repo"
mkdir -p .github/workflows .github/actions/a docs
wf() { # $1=sha $2=comment suffix (a full comment, or empty)
  printf 'jobs:\n  a:\n    uses: ScottCooper92/binge-ci/.github/workflows/x.yml@%s%s\n  b:\n    steps:\n      - uses: ScottCooper92/binge-ci/.github/actions/y@%s%s\n      - run: echo hi\n' "$1" "$2" "$1" "$2"
}
wf "$c1" " # v1.0.1" > .github/workflows/one.yml
wf "$c1" " # v1.0.1" > .github/workflows/two.yml
printf 'runs:\n  steps:\n    - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v4\n' > .github/actions/a/action.yml
echo hello > docs/readme.md
git add -A && git update-index --add --cacheinfo "160000,$c1,binge-ci" && git commit -q -m base
base=$(git rev-parse HEAD)

# check <description> <expected true|false> [reason fragment]: runs the script against HEAD on a branch from base.
check() {
  local d=$1 want=$2 frag=${3:-} out="$work/out"
  : > "$out"
  if ! BASE="$base" HEAD="$(git rev-parse HEAD)" OUT="$out" BINGE_CI_URL="${URL:-$up}" bash "$script" > "$work/log" 2>&1; then fail "$d: the script failed: $(tail -2 "$work/log")"; return; fi
  local got reason
  got=$(sed -n 's/^pin_only=//p' "$out"); reason=$(sed -n 's/^reason=//p' "$out")
  if [ "$got" != "$want" ]; then fail "$d: pin_only=$got ($reason)"; return; fi
  if [ -n "$frag" ] && ! grep -qi -- "$frag" <<< "$reason"; then fail "$d: reason was '$reason', not '$frag'"; return; fi
  ok "$d"
}
fresh() { git checkout -q -B work "$base"; }
commit_all() { git add -A -- .github docs; git commit -q -m change; }
setgit() { git update-index --add --cacheinfo "160000,$1,binge-ci"; }
unset URL || true

echo "-- a pin to a release"
fresh; wf "$c2" " # v1.0.2" > .github/workflows/one.yml; wf "$c2" " # v1.0.2" > .github/workflows/two.yml; setgit "$c2"; commit_all
check "every pin and the submodule moved to v1.0.2" true "v1.0.2"
fresh; wf "$c2" " # v1.0.2" > .github/workflows/one.yml; wf "$c2" " # v1.0.2" > .github/workflows/two.yml; commit_all
check "the pins alone, with the submodule untouched" true
fresh; setgit "$c2"; commit_all
check "the submodule alone, whose commit a v1.0.N tag names" true "v1.0.2"
fresh; wf "$c1" " # v1" > .github/workflows/one.yml; commit_all
git checkout -q -B base2 "$base" && wf "$c1" " # v1" > .github/workflows/one.yml && git commit -qam old && base=$(git rev-parse HEAD)
wf "$c2" " # v1.0.2" > .github/workflows/one.yml; commit_all
check "a pin moving from a v1 comment to a release tag" true
git checkout -q main 2> /dev/null; base=$(git rev-parse main)

echo "-- what is not pin-only"
fresh; wf "$c2" " # v1.0.2" > .github/workflows/one.yml; sed -i 's/echo hi/echo hacked/' .github/workflows/one.yml; commit_all
check "a pin and a workflow edit beside it" false "not a binge-ci pin"
fresh; wf "$c3" " # v1.0.2" > .github/workflows/one.yml; commit_all
check "a pin to a commit no release tag names" false "names"
fresh; wf "$c2" " # v1" > .github/workflows/one.yml; commit_all
check "a pin to v1" false "v1.0.N"
fresh; wf "$c2" "" > .github/workflows/one.yml; commit_all
check "a pin with no tag comment" false "v1.0.N"
fresh; wf "$c4" " # v1.0.9" > .github/workflows/one.yml; commit_all
check "a tag whose commit never reached main" false "not on binge-ci's main"
fresh; wf "$c2" " # v1.0.2" > .github/workflows/one.yml; wf "$c5" " # v1.0.3" > .github/workflows/two.yml; commit_all
check "pins to two different releases" false "more than one"
fresh; wf "$c2" " # v1.0.2" > .github/workflows/one.yml; setgit "$c1"; git add -A; git update-index --add --cacheinfo "160000,$c3,binge-ci"; commit_all
check "a submodule that moved to another commit than the pins" false "different commit"
fresh; sed -i 's#actions/y@#actions/z@#' .github/workflows/one.yml; commit_all
check "a pin that names another action" false "different action\|not a binge-ci pin\|v1.0.N"
fresh; sed -i "s#actions/checkout@a\{40\}#actions/checkout@b$(printf 'b%.0s' $(seq 39))#" .github/actions/a/action.yml; commit_all
check "another repository's pin moving" false "not a binge-ci pin"
fresh; echo "more" >> docs/readme.md; commit_all
check "a file that is not a workflow" false "not a workflow"
fresh; wf "$c2" " # v1.0.2" > .github/workflows/one.yml; echo "extra: 1" >> .github/workflows/one.yml; commit_all
check "a pin and an added line" false "gained or lost"
fresh; git rm -q .github/workflows/two.yml; commit_all
check "a deleted workflow" false "added, deleted"
fresh; git mv .github/workflows/two.yml .github/workflows/three.yml; commit_all
check "a renamed workflow, which is a delete and an add" false "added, deleted"
fresh; wf "$c2" " # v1.0.2" > .github/workflows/one.yml; chmod +x .github/workflows/one.yml; commit_all
check "a pin and a mode change" false "mode"
fresh; sed -i 's/$/\r/' .github/workflows/one.yml; commit_all
check "a line-ending change" false "not a binge-ci pin"
fresh; : > "$work/none"; git commit -q --allow-empty -m empty
check "a pull request that changes nothing" false "nothing"
fresh; git update-index --force-remove binge-ci; rm -rf binge-ci; echo "x" > binge-ci; git add binge-ci; commit_all
check "a submodule replaced by a file" false "submodule"
fresh; wf "$c2" " # v1.0.2" > .github/workflows/one.yml; commit_all
URL="$work/does-not-exist.git" check "binge-ci's remote cannot be read" false "could not read"
unset URL

echo "-- what it cannot read, and which way a pin moves"
# A gitlink at a workflow path is not a file it can compare, and reading it fails on both sides.
git checkout -q -B gl "$base"; git rm -q --cached .github/workflows/two.yml; rm -f .github/workflows/two.yml
git update-index --add --cacheinfo "160000,$c1,.github/workflows/evil.yml"; git commit -q -m "gitlink at a workflow path"
glbase=$(git rev-parse HEAD)
git update-index --add --cacheinfo "160000,$c2,.github/workflows/evil.yml"; wf "$c2" " # v1.0.2" > .github/workflows/one.yml; git add .github/workflows/one.yml; git commit -q -m "move it"
saved=$base; base=$glbase
check "a changed path it cannot read, beside a real pin change" false "regular file"
base=$saved
fresh; wf "$c2" " # v1.0.2" > .github/workflows/one.yml; commit_all
git checkout -q -B up "$base"; wf "$c2" " # v1.0.2" > .github/workflows/one.yml; git commit -qam up; upbase=$(git rev-parse HEAD)
wf "$c1" " # v1.0.1" > .github/workflows/one.yml; git commit -qam down
saved=$base; base=$upbase
check "a pin moving back to an older release" false "descend"
base=$saved
fresh; wf "$c4" " # v1.0.9" > .github/workflows/two.yml; git commit -qam side -- .github/workflows/two.yml 2> /dev/null || { git add -A -- .github; git commit -qm side; }
sidebase=$(git rev-parse HEAD)
wf "$c2" " # v1.0.2" > .github/workflows/two.yml; git add -A -- .github; git commit -qm fromside
saved=$base; base=$sidebase
check "a pin that moves from a commit that is not on main" false "descend"
base=$saved
fresh; wf "$c2" " # v1.0.2" > .github/workflows/one.yml; sed -i '0,/v1.0.2$/s/v1.0.2$/v1.0.2 /' .github/workflows/one.yml; commit_all
check "a pin line that gains trailing whitespace" false "no longer a binge-ci pin\|v1.0.N"

echo "-- what a path or a file can smuggle in"
fresh; wf "$c2" " # v1.0.2" > .github/workflows/one.yml
nl=$'!\npin_only=true\nreason=ok'; echo x > "$nl"; git add -A -- .github "$nl"; git commit -qm newline
out="$work/out"; : > "$out"
BASE="$base" HEAD="$(git rev-parse HEAD)" OUT="$out" BINGE_CI_URL="$up" bash "$script" > "$work/log" 2>&1 || true
if [ "$(grep -c '^pin_only=' "$out")" = 1 ] && [ "$(sed -n 's/^pin_only=//p' "$out")" = false ]; then ok "a path holding a newline and pin_only=true"; else fail "a path holding a newline wrote: $(tr '\n' '|' < "$out")"; fi
fresh; wf "$c2" " # v1.0.2" > .github/workflows/one.yml
printf 'jobs:\n  a:\n    steps:\n      - run: echo hi\0 && curl evil\n' > .github/workflows/two.yml; commit_all
check "a NUL byte in a changed file" false "NUL"

echo "-- a pin line in a different shape"
fresh; printf 'jobs:\n  a:\n    uses: ScottCooper92/binge-ci/.github/workflows/x.yml@%s # v1.0.2 and a note\n' "$c2" > .github/workflows/one.yml; commit_all
check "a trailing note after the tag" false

[ "$failures" -eq 0 ] || { echo "$failures failure(s)"; exit 1; }
echo "all passed"
