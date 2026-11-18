#!/usr/bin/env bash
#
# Holds release-tag.sh, the script behind release-tag.yml. That workflow lets a GitHub App create tags the ruleset
# forbids, so the cases are about what it must refuse: a merge that is not a release does nothing, and a merge that
# looks like one is tagged only when the branch name, the tree and the diff all agree. It also holds the order of
# the writes (release tag, checks, `v1`, checks, `stable`) and the workflow's own permissions.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
failures=0
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
ok() { echo "ok    $1"; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=Dev GIT_AUTHOR_EMAIL=dev@example.com GIT_COMMITTER_NAME=Dev GIT_COMMITTER_EMAIL=dev@example.com

# A gh that answers from files, and applies ref writes to the bare origin so the tag checks see them.
mkdir "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$STUB_LOG"
case "$1" in
  api)
    shift
    method=GET
    [ "${1:-}" = "-X" ] && { method=$2; shift 2; }
    path=$1; shift
    ref="" sha="" force=true
    while [ $# -gt 0 ]; do
      case "$1" in
        -f) case "$2" in ref=*) ref=${2#ref=} ;; sha=*) sha=${2#sha=} ;; esac; shift 2 ;;
        -F) [ "$2" = "force=false" ] && force=false; shift 2 ;;
        *) shift ;;
      esac
    done
    case "$method $path" in
      "GET repos/"*"/commits/"*"/pulls") jq 'map(del(.merged_by))' "$STUB_PRS" ;;
      "GET repos/"*"/pulls/"*) jq '.[0]' "$STUB_PRS" ;;
      "GET repos/"*"/git/ref/"*) git -C "$STUB_ORIGIN" show-ref --verify -q "refs/${path#*/git/ref/}" ;;
      "POST repos/"*"/git/refs")
        [ -z "${STUB_FAIL_POST:-}" ] || [[ $ref != *"$STUB_FAIL_POST"* ]] || exit 1
        git -C "$STUB_ORIGIN" update-ref "$ref" "$sha" ;;
      "PATCH repos/"*"/git/refs/"*)
        target="refs/${path#*/git/refs/}"
        if [ "$force" = false ] && ! git -C "$STUB_ORIGIN" merge-base --is-ancestor "$(git -C "$STUB_ORIGIN" rev-parse "$target")" "$sha"; then exit 1; fi
        git -C "$STUB_ORIGIN" update-ref "$target" "$sha" ;;
      *) echo "stub gh: unexpected $method $path" >&2; exit 2 ;;
    esac ;;
  issue)
    case "$2" in
      list)
        expr=""
        while [ $# -gt 0 ]; do [ "$1" = "--jq" ] && expr=$2; shift; done
        if [ -n "$expr" ]; then jq -r "$expr" "$STUB_ISSUES"; else cat "$STUB_ISSUES"; fi ;;
      *) : ;;
    esac ;;
  *) echo "stub gh: unexpected $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH" STUB_LOG="$work/log" STUB_PRS="$work/prs.json" STUB_ISSUES="$work/issues.json" STUB_ORIGIN="$work/origin.git"
: > "$STUB_LOG"; echo '[]' > "$STUB_ISSUES"

# A repository whose workflows pin v1.0.1, released as v1.0.1, with a bare origin.
git init -q --bare -b main "$STUB_ORIGIN"
repo="$work/repo"
git clone -q "$STUB_ORIGIN" "$repo" 2> /dev/null
cd "$repo"
git checkout -q -b main
mkdir -p tools .github/workflows .github/actions/a
cp "$root/tools/release-tag.sh" "$root/tools/check-internal-refs.sh" tools/
printf 'jobs:\n  a:\n    steps:\n      - uses: ScottCooper92/binge-ci/.github/actions/a@v1.0.1\n      - run: echo hi\n' > .github/workflows/one.yml
printf 'jobs:\n  b:\n    steps:\n      - uses: ScottCooper92/binge-ci/.github/actions/a@v1.0.1\n' > .github/workflows/two.yml
printf 'name: a\nruns:\n  using: composite\n  steps:\n    - uses: ScottCooper92/binge-ci/.github/actions/z@v1.0.1\n' > .github/actions/a/action.yml
git add -A && git commit -q -m base && git push -q origin main
git tag v1.0.1 && git push -q origin v1.0.1
git update-ref refs/tags/v1 HEAD && git push -q origin v1
base=$(git rev-parse HEAD)

bump() { # $1=from $2=to  rewrites every self-reference
  grep -rlE "binge-ci/.*@$1" .github | xargs sed -i -E "s#(ScottCooper92/binge-ci/[^ ]*@)$1#\1$2#"
}
# release <from> <to> [branch]: merges a bump the way a squash merge does, leaves HEAD on the merge commit.
release() {
  git checkout -q main && git reset -q --hard "$1" 2> /dev/null
  git checkout -q -b tmp
  bump "$2" "$3"
  git add -A && git commit -q -m "release $3"
  git checkout -q main && git merge -q --squash tmp > /dev/null && git commit -q -m "chore: release $3 (#9)"
  git branch -q -D tmp
  git push -q -f origin main
}
prjson() { # $1=head ref  $2=head repo  $3=merger type  [$4=merge sha]
  printf '[{"number":9,"merge_commit_sha":"%s","merged_at":"2026-01-01T00:00:00Z","head":{"ref":"%s","repo":{"full_name":"%s"}},"merged_by":{"login":"someone","type":"%s"}}]\n' \
    "${4:-$(git rev-parse HEAD)}" "$1" "$2" "$3" > "$STUB_PRS"
}
run() { # prints the outputs, exits with the script's status
  : > "$work/out"
  REPO=o/r SHA="${SHA_OVERRIDE:-$(git rev-parse HEAD)}" BEFORE="${BEFORE_OVERRIDE:-$(git rev-parse "${SHA_OVERRIDE:-HEAD}^1" 2> /dev/null || true)}" OUT="$work/out" bash tools/release-tag.sh "$@" > "$work/stdout" 2> "$work/stderr"
}
out_of() { sed -n "s/^$1=//p" "$work/out"; }
expect_refuses() { # $1=description  $2=expected message fragment
  if run decide; then fail "$1: it was tagged"; elif grep -q "$2" "$work/stderr"; then ok "$1"; else fail "$1: wrong reason: $(grep error "$work/stderr" | head -1)"; fi
  [ "$(out_of release)" != true ] || fail "$1: release=true was written"
}

echo "-- merges that are not a release"
echo '[]' > "$STUB_PRS"
git checkout -q main
if run decide && [ "$(out_of release)" = false ]; then ok "a commit with no pull request is not a release"; else fail "a plain push was treated as a release"; fi
prjson feature/x o/r User
if run decide && [ "$(out_of release)" = false ]; then ok "a merge of another branch is not a release, and exits green"; else fail "an ordinary merge failed or was tagged"; fi

echo "-- a release is refused unless everything agrees"
release "$base" v1.0.1 v1.0.2
prjson release/v1.0.2 o/r Bot
expect_refuses "a merge by a bot" "not by a person"
prjson release/v1.0.2 evil/fork User
expect_refuses "a pull request from a fork" "does not cut a release"
prjson release/v2.0.0 o/r User
expect_refuses "a branch that is not v1.0.N" "does not name a v1.0.N"
prjson release/v1.0.3 o/r User
expect_refuses "a branch named for a different release than the tree pins" "pin"
prjson release/v1.0.1 o/r User
expect_refuses "a version that already exists at another commit" "never moved"
git tag -d v1.0.1 > /dev/null; git tag v1.0.0 "$base"
prjson release/v1.0.2 o/r User
git tag -d v1.0.0 > /dev/null; git tag v1.0.1 "$base"

echo "-- the diff has to be the bump and nothing else"
git checkout -q main && git reset -q --hard "$base"
git checkout -q -b tmp && bump v1.0.1 v1.0.2 && echo 'echo extra' >> tools/extra.sh
git add -A && git commit -q -m x && git checkout -q main && git merge -q --squash tmp > /dev/null && git commit -q -m "release (#9)" && git branch -q -D tmp
prjson release/v1.0.2 o/r User
expect_refuses "a release that also adds a file outside the workflows" "more than workflow"
git checkout -q main && git reset -q --hard "$base"
git checkout -q -b tmp && bump v1.0.1 v1.0.2 && sed -i 's/echo hi/echo changed/' .github/workflows/one.yml
git add -A && git commit -q -m x && git checkout -q main && git merge -q --squash tmp > /dev/null && git commit -q -m "release (#9)" && git branch -q -D tmp
prjson release/v1.0.2 o/r User
expect_refuses "a release that also edits a workflow line" "not a self-reference"
git checkout -q main && git reset -q --hard "$base"
git checkout -q -b tmp && bump v1.0.1 v1.0.2 && sed -i 's#a@v1.0.2#b@v1.0.2#' .github/workflows/two.yml
git add -A && git commit -q -m x && git checkout -q main && git merge -q --squash tmp > /dev/null && git commit -q -m "release (#9)" && git branch -q -D tmp
prjson release/v1.0.2 o/r User
expect_refuses "a release that changes which action a line names" "differ by more than"

echo "-- a rebase merge is checked as a whole"
git checkout -q main && git reset -q --hard "$base"
echo 'echo extra' > tools/extra.sh && git add -A && git commit -q -m "extra"
bump v1.0.1 v1.0.2 && git add -A && git commit -q -m "bump"
prjson release/v1.0.2 o/r User
if BEFORE_OVERRIDE="$base" run decide; then fail "a rebase merge hiding a file in an earlier commit was tagged"; elif grep -q "more than workflow" "$work/stderr"; then ok "a rebase merge is diffed from the push's previous head, not the last commit"; else fail "wrong reason: $(grep error "$work/stderr" | head -1)"; fi

echo "-- a good release is tagged, in order"
release "$base" v1.0.1 v1.0.2
sha=$(git rev-parse HEAD)
prjson release/v1.0.2 o/r User
if run decide && [ "$(out_of release)" = true ] && [ "$(out_of version)" = v1.0.2 ] && [ "$(out_of resume)" = false ]; then
  ok "the merge of release/v1.0.2 is a release for v1.0.2"
else
  fail "a good release was not recognised: $(cat "$work/stderr")"
fi
: > "$STUB_LOG"
if VERSION=v1.0.2 run tag; then ok "tagging succeeds"; else fail "tagging failed: $(cat "$work/stderr")"; fi
[ "$(git -C "$STUB_ORIGIN" rev-parse refs/tags/v1.0.2)" = "$sha" ] && [ "$(git -C "$STUB_ORIGIN" rev-parse refs/tags/v1)" = "$sha" ] \
  && [ "$(git -C "$STUB_ORIGIN" rev-parse refs/heads/stable)" = "$sha" ] \
  && ok "v1.0.2, v1 and stable all name the merge commit" || fail "the refs are wrong after tagging"
order=$(grep -E 'git/refs' "$STUB_LOG" | sed -E 's/.*(refs\/(tags|heads)\/[A-Za-z0-9.]+).*/\1/' | tr '\n' ' ')
[ "$order" = "refs/tags/v1.0.2 refs/tags/v1 refs/heads/stable " ] || [ "$order" = "refs/tags/v1.0.2 refs/tags/v1 refs/heads/stable" ] \
  && ok "the order is the release tag, then v1, then stable" || fail "refs were written in the order: $order"
grep -q 'force=true' "$STUB_LOG" && ! grep 'heads/stable' "$STUB_LOG" | grep -q 'force=true' \
  && ok "v1 is forced and stable is a fast-forward only" || fail "the force flags are wrong"

echo "-- the next release moves v1 and fast-forwards stable"
release "$sha" v1.0.2 v1.0.3
sha3=$(git rev-parse HEAD)
prjson release/v1.0.3 o/r User
run decide && [ "$(out_of version)" = v1.0.3 ] && ok "the next release is recognised" || fail "v1.0.3 not recognised: $(cat "$work/stderr")"
VERSION=v1.0.3 run tag && [ "$(git -C "$STUB_ORIGIN" rev-parse refs/tags/v1)" = "$sha3" ] && [ "$(git -C "$STUB_ORIGIN" rev-parse refs/heads/stable)" = "$sha3" ] \
  && ok "v1 and stable moved to it" || fail "the second release did not move the refs: $(cat "$work/stderr")"

echo "-- a release that was tagged in part resumes"
prjson release/v1.0.3 o/r User
if run decide && [ "$(out_of resume)" = true ] && [ "$(out_of release)" = true ]; then ok "a tag already at this commit is a resume, not an error"; else fail "a resume was refused: $(cat "$work/stderr")"; fi
: > "$STUB_LOG"
VERSION=v1.0.3 run tag
grep -q 'POST.*refs/tags/v1.0.3' "$STUB_LOG" && fail "an existing tag was created again" || ok "and the tag is not created twice"

echo "-- the writes stop where a check fails"
git checkout -q main && git reset -q --hard "$sha3"
: > "$STUB_LOG"
# The tag is made at a commit whose tree pins v1.0.1, so the tag checks fail before v1 may move.
if SHA_OVERRIDE="$base" VERSION=v1.0.5 run tag; then fail "a tag that names another release passed its checks"; else ok "a failed tag check fails the run"; fi
[ "$(git -C "$STUB_ORIGIN" rev-parse refs/tags/v1)" = "$sha3" ] && ! grep -q 'refs/tags/v1 ' "$STUB_LOG" \
  && ok "and v1 is not moved" || fail "v1 moved after a failed check"
git -C "$STUB_ORIGIN" update-ref -d refs/tags/v1.0.5 2> /dev/null || true
git tag -d v1.0.5 > /dev/null 2>&1 || true
echo "-- stable that cannot fast-forward"
release "$sha3" v1.0.3 v1.0.4
prjson release/v1.0.4 o/r User
run decide
git -C "$STUB_ORIGIN" update-ref refs/heads/stable "$base"
other=$(git -C "$STUB_ORIGIN" commit-tree -m side "$(git -C "$STUB_ORIGIN" rev-parse "$base^{tree}")")
git -C "$STUB_ORIGIN" update-ref refs/heads/stable "$other"
if VERSION=v1.0.4 run tag; then fail "a stable that is not a line was overwritten"; else grep -q 'stable' "$work/stderr" && ok "a stable that cannot fast-forward fails and says so" || fail "wrong message"; fi
[ "$(git -C "$STUB_ORIGIN" rev-parse refs/heads/stable)" = "$other" ] && ok "and stable is left as it was" || fail "stable was changed"

echo "-- the report"
: > "$STUB_LOG"
VERSION=v1.0.4 RUN_URL=https://example.test/run/1 REPO=o/r bash tools/release-tag.sh report
grep -q 'issue create' "$STUB_LOG" && ok "a failed release opens an issue" || fail "no issue was opened"
echo '[{"number":5,"body":"<!-- release-tag:v1.0.4 -->\nold"}]' > "$STUB_ISSUES"
: > "$STUB_LOG"
VERSION=v1.0.4 RUN_URL=https://example.test/run/2 REPO=o/r bash tools/release-tag.sh report
if grep -q 'issue comment 5' "$STUB_LOG" && ! grep -q 'issue create' "$STUB_LOG"; then ok "a second failure comments on that issue and opens no second"; else fail "the issue was not deduplicated"; fi

echo "-- the workflow"
cd "$root"
python3 -I - <<'PY' && ok "triggered by main pushes only, decided without secrets, tagged only from the release environment, with the App limited to contents" || fail "the workflow's shape is wrong"
import yaml
w = yaml.safe_load(open(".github/workflows/release-tag.yml"))
on = w[True]
assert list(on) == ["push"] and on["push"]["branches"] == ["main"], on
assert w["permissions"] == {"contents": "read"}
j = w["jobs"]
assert "environment" not in j["decide"] and "secrets" not in str(j["decide"])
assert j["decide"]["permissions"] == {"contents": "read", "pull-requests": "read"}
assert j["tag"]["environment"] == "release" and j["tag"]["if"] == "needs.decide.outputs.release == 'true'"
mint = [s for s in j["tag"]["steps"] if str(s.get("uses", "")).startswith("actions/create-github-app-token@")]
assert len(mint) == 1
perms = {k for k in mint[0]["with"] if k.startswith("permission-")}
assert perms == {"permission-contents"} and mint[0]["with"]["permission-contents"] == "write"
assert "repositories" in mint[0]["with"]
assert j["report"]["permissions"] == {"contents": "read", "issues": "write"}
assert w["concurrency"]["cancel-in-progress"] is False
PY

[ "$failures" -eq 0 ] || { echo "$failures failure(s)"; exit 1; }
echo "all passed"
