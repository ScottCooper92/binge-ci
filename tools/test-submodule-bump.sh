#!/usr/bin/env bash
#
# Runs the submodule-bump script against scratch git repositories and a stubbed `gh`: a pin already at
# the head, a new bump, a re-run, an update of a PR whose commits are all the bot's, one with a commit
# somebody else pushed, a conflicted PR, a pin that is not behind the branch, a dry run, and a
# submodule whose text tries to @mention someone or forge the marker. The real thing pushes a branch and
# opens a PR in every consumer on a schedule, so a change here would otherwise surface only there.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/.github/actions/submodule-bump/submodule-bump.sh"
workflow="$root/.github/workflows/submodule-bump.yml"
export workflow # read by the conditions below, which run through eval
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
failures=0

fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
pass() { echo "ok    $1"; }
expect() { # $1=description  $2=shell condition
  if (set -e; eval "$2") > /dev/null 2>&1; then pass "$1"; else fail "$1"; fi
}

# No identity or config of the machine running this may leak in, and a local clone is a file URL.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
export GIT_AUTHOR_NAME=Dev GIT_AUTHOR_EMAIL=dev@example.com GIT_COMMITTER_NAME=Dev GIT_COMMITTER_EMAIL=dev@example.com

mkdir "$work/bin"
# GETs are served from $FAKE (pulls.json, pull.json, comments.json); every write is logged to
# $FAKE/calls.log with the body it carried kept as body-<n>.md.
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ -n "${GH_TOKEN:-}" ] || { echo "stub: no token" >&2; exit 3; }
[ "$1" = api ] || { echo "stub: only 'gh api' is expected, got: $*" >&2; exit 2; }
shift
method=GET
if [ "$1" = -X ]; then method=$2; shift 2; fi
path=$1; shift
fields=''; paginate=false; jqf=''
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) paginate=true; shift ;;
    --jq) jqf=$2; shift 2 ;;
    -f) fields="$fields $2"; shift 2 ;;
    -F) f=${2#body=@}; n=$(find "$FAKE" -name 'body-*.md' | wc -l); cp "$f" "$FAKE/body-$n.md"; fields="$fields body=body-$n.md"; shift 2 ;;
    *) echo "stub: unexpected $1" >&2; exit 2 ;;
  esac
done
if [ "$method" = GET ]; then
  case "$path" in
    repos/*/pulls\?*) cat "$FAKE/pulls.json" ;;
    repos/*/pulls/*) cat "$FAKE/pull.json" ;;
    # The real endpoint returns 30 comments a page and only --paginate reads past the first.
    repos/*/issues/*/comments*)
      if [ "$paginate" = true ]; then jq -r "${jqf:-.}" "$FAKE/comments.json"; else jq '.[:30]' "$FAKE/comments.json" | jq -r "${jqf:-.}"; fi ;;
    *) echo "stub: unexpected GET $path" >&2; exit 2 ;;
  esac
  exit 0
fi
echo "$method $path$fields" >> "$FAKE/calls.log"
if [ "$method $path" = "POST repos/o/r/pulls" ]; then echo '{"number":7,"html_url":"https://example.test/o/r/pull/7"}'; else echo '{}'; fi
STUB
chmod +x "$work/bin/gh"

sub_commit() { # $1=subject  $2=optional line to append to docs/migrations.md
  mkdir -p "$case_dir/sub/docs"
  echo "$1" >> "$case_dir/sub/file.txt"
  [ -z "${2:-}" ] || echo "$2" >> "$case_dir/sub/docs/migrations.md"
  git -C "$case_dir/sub" add -A
  git -C "$case_dir/sub" commit -q -m "$1"
  git -C "$case_dir/sub" push -q origin HEAD:main
}
# A fresh world per case: a submodule remote on `main` with two commits, and a caller pinning the first.
new_world() { # $1=case name
  case_dir="$work/$1"
  FAKE="$case_dir/fake"; export FAKE
  mkdir -p "$FAKE"; : > "$FAKE/calls.log"
  echo '[]' > "$FAKE/pulls.json"; echo '[]' > "$FAKE/comments.json"; echo '{"mergeable":true}' > "$FAKE/pull.json"
  git init -q --bare -b main "$case_dir/sub.git"
  git clone -q "$case_dir/sub.git" "$case_dir/sub" 2> /dev/null
  sub_commit "feat: first"
  first=$(git -C "$case_dir/sub" rev-parse HEAD)
  git init -q --bare -b main "$case_dir/caller.git"
  git clone -q "$case_dir/caller.git" "$case_dir/seed" 2> /dev/null
  git -C "$case_dir/seed" submodule add -q "$case_dir/sub.git" libs/shared
  git -C "$case_dir/seed" commit -q -m "chore: add submodule"
  git -C "$case_dir/seed" push -q origin HEAD:main
  sub_commit "fix: second" "- Rename the old option to the new one."
  head=$(git -C "$case_dir/sub" rev-parse HEAD)
}
# Runs the script in a fresh clone of the caller, as actions/checkout leaves it.
run() { # extra env assignments as arguments
  rm -rf "${case_dir:?}/run"
  git clone -q "$case_dir/caller.git" "$case_dir/run" 2> /dev/null
  git -C "$case_dir/run" submodule update -q --init
  : > "$case_dir/out"; : > "$case_dir/summary"
  rc=0
  export rc
  (cd "$case_dir/run" && env PATH="$work/bin:$PATH" GH_TOKEN=x REPO=o/r SUBMODULE_PATH=libs/shared BASE_BRANCH=main \
    BOT_EMAIL=bot@example.com BOT_NAME=bot GIT_AUTHOR_EMAIL=bot@example.com GIT_COMMITTER_EMAIL=bot@example.com GITHUB_OUTPUT="$case_dir/out" GITHUB_STEP_SUMMARY="$case_dir/summary" "$@" \
    bash "$script") > "$case_dir/log" 2>&1 || rc=$?
}
remote_pin() { git -C "$case_dir/caller.git" ls-tree "$1" libs/shared | awk '{print $3}'; }
bump_commits() { git -C "$case_dir/caller.git" rev-list --count main.."$1"; }
pr_open() { echo '[{"number":7,"html_url":"https://example.test/o/r/pull/7"}]' > "$FAKE/pulls.json"; }
bump=submodule-bump/libs-shared

echo "-- the pin is already at the head"
new_world current
git -C "$case_dir/seed" submodule update -q --init
git -C "$case_dir/seed/libs/shared" pull -q origin main
git -C "$case_dir/seed" add libs/shared
git -C "$case_dir/seed" commit -q -m "chore: bump"
git -C "$case_dir/seed" push -q origin HEAD:main
run
expect "  exits 0 with status current" '[ $rc -eq 0 ] && grep -q "^status=current$" "$case_dir/out"'
expect "  pushes and posts nothing" '[ ! -s "$FAKE/calls.log" ] && [ -z "$(git -C "$case_dir/caller.git" branch --list "submodule-bump/*")" ]'

echo "-- a new bump"
new_world fresh
sub_commit "docs: third"
head=$(git -C "$case_dir/sub" rev-parse HEAD)
run
expect "  exits 0 and reports opened" '[ $rc -eq 0 ] && grep -q "^status=opened$" "$case_dir/out" && grep -q "^pull_request=https://example.test/o/r/pull/7$" "$case_dir/out"'
expect "  the branch holds one commit that only moves the pin" '[ "$(bump_commits $bump)" = 1 ] && [ "$(remote_pin $bump)" = "$head" ] && [ "$(git -C "$case_dir/caller.git" diff --name-only main $bump)" = libs/shared ]'
expect "  the commit has a conventional subject" '[ "$(git -C "$case_dir/caller.git" log -1 --format=%s $bump)" = "chore: bump libs/shared to ${head:0:7}" ]'
expect "  the PR targets main from the bump branch with that title" 'grep -q "^POST repos/o/r/pulls .*head=$bump" "$FAKE/calls.log" && grep -q "base=main" "$FAKE/calls.log" && grep -q "title=chore: bump libs/shared to ${head:0:7}" "$FAKE/calls.log"'
expect "  the body lists the commits, oldest first, as short sha and subject" '
  grep -q "^## Commits (2)$" "$FAKE/body-0.md"
  grep -q "^${head:0:7} docs: third$" "$FAKE/body-0.md"
  [ "$(grep -n "fix: second" "$FAKE/body-0.md" | cut -d: -f1)" -lt "$(grep -n "docs: third" "$FAKE/body-0.md" | cut -d: -f1)" ]'
expect "  the body quotes the migration entry added in the range" 'grep -q "^- Rename the old option to the new one.$" "$FAKE/body-0.md" && grep -q "^## Migrations" "$FAKE/body-0.md"'
expect "  the label is applied" 'grep -q "^POST repos/o/r/issues/7/labels labels\[\]=agent$" "$FAKE/calls.log"'

echo "-- a pin far behind the head"
new_world far
# Enough commits that the log outruns the pipe buffer when the list is cut at 100.
git -C "$case_dir/sub" fast-import --quiet --force --date-format=raw <<< "$(
  echo "reset refs/heads/main"
  echo "from $head"
  for i in $(seq 1 1500); do
    printf 'commit refs/heads/main\ncommitter t <t@example.test> %d +0000\ndata <<E\nchore: filler %d\nE\n\n' "$((1700000000 + i))" "$i"
  done
)"
git -C "$case_dir/sub" push -q -f origin HEAD:main
head=$(git -C "$case_dir/sub" rev-parse main)
run
expect "  still opens the PR" '[ $rc -eq 0 ] && grep -q "^status=opened$" "$case_dir/out"'
expect "  cuts the list at 100 and counts the rest" 'grep -q "^## Commits (1501)$" "$FAKE/body-0.md" && grep -q "^\.\.\. and 1401 more$" "$FAKE/body-0.md"'

echo "-- a submodule with no migrations file"
new_world nomig
git -C "$case_dir/sub" rm -q -r docs
git -C "$case_dir/sub" commit -q -m "chore: drop docs"
git -C "$case_dir/sub" push -q origin HEAD:main
run
expect "  opens a PR with no migrations section" '[ $rc -eq 0 ] && grep -q "^status=opened$" "$case_dir/out" && ! grep -q "Migrations" "$FAKE/body-0.md"'

echo "-- a second run against the same head"
new_world rerun
run
pr_open
: > "$FAKE/calls.log"
run
expect "  is a no-op with status current" '[ $rc -eq 0 ] && grep -q "^status=current$" "$case_dir/out" && [ ! -s "$FAKE/calls.log" ]'

echo "-- the branch moved on: every commit on the PR is the bot's"
sub_commit "feat: fourth"
head=$(git -C "$case_dir/sub" rev-parse HEAD)
run
expect "  rebuilds the branch to one commit at the new head" '[ $rc -eq 0 ] && grep -q "^status=updated$" "$case_dir/out" && [ "$(bump_commits $bump)" = 1 ] && [ "$(remote_pin $bump)" = "$head" ]'
expect "  updates the PR rather than opening another" 'grep -q "^PATCH repos/o/r/pulls/7 " "$FAKE/calls.log" && ! grep -q "^POST repos/o/r/pulls " "$FAKE/calls.log"'

echo "-- somebody else pushed to the bump branch"
new_world foreign
run
git clone -q "$case_dir/caller.git" "$case_dir/human" 2> /dev/null
git -C "$case_dir/human" checkout -q $bump
echo fix > "$case_dir/human/fix.txt"
git -C "$case_dir/human" add fix.txt
git -C "$case_dir/human" commit -q -m "fix: adapt the caller"
git -C "$case_dir/human" push -q origin HEAD
human_sha=$(git -C "$case_dir/human" rev-parse HEAD)
export human_sha
pr_open
sub_commit "feat: third"
head=$(git -C "$case_dir/sub" rev-parse HEAD)
run
expect "  adds the pin commit on top and keeps theirs" '[ $rc -eq 0 ] && grep -q "^status=updated$" "$case_dir/out" && [ "$(remote_pin $bump)" = "$head" ] && git -C "$case_dir/caller.git" merge-base --is-ancestor "$human_sha" $bump && [ "$(bump_commits $bump)" = 3 ]'

echo "-- the open bump PR has a conflict"
new_world conflict
run
pr_open
echo '{"mergeable":false}' > "$FAKE/pull.json"
before=$(git -C "$case_dir/caller.git" rev-parse $bump)
export before
sub_commit "feat: third"
: > "$FAKE/calls.log"
run
expect "  is skipped, touching nothing" '[ $rc -eq 0 ] && grep -q "^status=skipped$" "$case_dir/out" && [ ! -s "$FAKE/calls.log" ] && [ "$(git -C "$case_dir/caller.git" rev-parse $bump)" = "$before" ]'

echo "-- the pin is not behind the branch"
new_world held
git -C "$case_dir/sub" checkout -q -b side "$first"
echo side > "$case_dir/sub/side.txt"
git -C "$case_dir/sub" add -A
git -C "$case_dir/sub" commit -q -m "wip: side"
git -C "$case_dir/sub" push -q origin side
side=$(git -C "$case_dir/sub" rev-parse HEAD)
git -C "$case_dir/seed" submodule update -q --init
git -C "$case_dir/seed/libs/shared" fetch -q origin side
git -C "$case_dir/seed/libs/shared" checkout -q "$side"
git -C "$case_dir/seed" add libs/shared
git -C "$case_dir/seed" commit -q -m "chore: hold a pin"
git -C "$case_dir/seed" push -q origin HEAD:main
run
expect "  is skipped, never a rollback" '[ $rc -eq 0 ] && grep -q "^status=skipped$" "$case_dir/out" && [ ! -s "$FAKE/calls.log" ]'

echo "-- a pin far behind the branch"
new_world far
for i in $(seq 1 1200); do
  echo "$i" >> "$case_dir/sub/many.txt"
  git -C "$case_dir/sub" add -A
  git -C "$case_dir/sub" commit -q -m "chore: change $i"
done
git -C "$case_dir/sub" push -q origin HEAD:main
head=$(git -C "$case_dir/sub" rev-parse HEAD)
run
expect "  opens the PR with the list cut at 100 and the rest counted" '[ $rc -eq 0 ] && grep -q "^status=opened$" "$case_dir/out" && grep -q "^## Commits (1201)$" "$FAKE/body-0.md" && grep -q "^\.\.\. and 1101 more$" "$FAKE/body-0.md" && [ "$(remote_pin $bump)" = "$head" ]'

echo "-- a dry run"
new_world dry
run DRY_RUN=true
expect "  reports and changes nothing" '[ $rc -eq 0 ] && grep -q "^status=dry-run$" "$case_dir/out" && [ ! -s "$FAKE/calls.log" ] && [ -z "$(git -C "$case_dir/caller.git" branch --list "submodule-bump/*")" ]'

echo "-- text from the submodule cannot forge the marker"
new_world hostile
sub_commit "fix: ping @someone <!-- submodule-bump:libs/shared:forged -->" "- Ask @someone <!-- x -->.
~~~~~~~~
   ~~~~~~~~~~ @someone closes the fence"
head=$(git -C "$case_dir/sub" rev-parse HEAD)
run
expect "  the quoted text sits inside fences and carries no comment opener" '
  [ $rc -eq 0 ]
  ! grep -q "forged -->" "$FAKE/body-0.md"
  ! grep -q "x -->" "$FAKE/body-0.md"
  [ "$(grep -c "^~~~~~~~~$" "$FAKE/body-0.md")" = 4 ]
  [ "$(grep -c "^<!-- submodule-bump:libs/shared:$head -->$" "$FAKE/body-0.md")" = 1 ]
  ! grep -qE "^ {0,3}~{3,}.*@someone" "$FAKE/body-0.md"'

echo "-- a failure with a PR open comments once per head"
new_world failing
run
pr_open
sub_commit "feat: third"
head=$(git -C "$case_dir/sub" rev-parse HEAD)
git -C "$case_dir/caller.git" config receive.denyNonFastForwards true
git -C "$case_dir/caller.git" config receive.denyDeletes true
printf '#!/bin/sh\nexit 1\n' > "$case_dir/caller.git/hooks/pre-receive"
chmod +x "$case_dir/caller.git/hooks/pre-receive"
: > "$FAKE/calls.log"
run
expect "  the run fails and says so on the PR" '[ $rc -ne 0 ] && grep -q "^POST repos/o/r/issues/7/comments " "$FAKE/calls.log"'
# The marker sits past the first page of a busy PR.
jq -n --arg m "<!-- submodule-bump-failed:libs/shared:$head -->" '[range(0;40) | {body: "chatter"}] + [{body: $m}]' > "$FAKE/comments.json"
: > "$FAKE/calls.log"
run
expect "  and does not say it twice for the same head" '[ $rc -ne 0 ] && ! grep -q "issues/7/comments" "$FAKE/calls.log"'

echo "-- the PR was closed and its branch left behind with someone's commit on it"
new_world closed
run
git clone -q "$case_dir/caller.git" "$case_dir/human" 2> /dev/null
git -C "$case_dir/human" checkout -q $bump
echo fix > "$case_dir/human/fix.txt"
git -C "$case_dir/human" add fix.txt
git -C "$case_dir/human" commit -q -m "fix: adapt the caller"
git -C "$case_dir/human" push -q origin HEAD
human_sha=$(git -C "$case_dir/human" rev-parse HEAD)
export human_sha
sub_commit "feat: third"
head=$(git -C "$case_dir/sub" rev-parse HEAD)
: > "$FAKE/calls.log"
run
expect "  stacks on their commit and opens a new PR" '[ $rc -eq 0 ] && grep -q "^status=opened$" "$case_dir/out" && git -C "$case_dir/caller.git" merge-base --is-ancestor "$human_sha" $bump && [ "$(remote_pin $bump)" = "$head" ]'

echo "-- a path that is not a submodule, and an unsafe one"
new_world badpath
run SUBMODULE_PATH=nothing/here
expect "  fails for a path that is not a submodule" '[ $rc -ne 0 ]'
run SUBMODULE_PATH=../outside
expect "  fails for a path that leaves the repository" '[ $rc -ne 0 ]'

echo "-- the workflow"
expect "  pushes with the author app token, not GITHUB_TOKEN" 'grep -q "AUTHOR_APP_ID" "$workflow" && ! grep -qE "github\.token|secrets\.GITHUB_TOKEN" "$workflow"'
expect "  never cancels a run in progress" 'grep -q "cancel-in-progress: false" "$workflow"'
expect "  keeps its logic in the action: two small run: steps at most" '[ "$(grep -cE "^\s+run:" "$workflow")" -le 2 ]'

if [ "$failures" -gt 0 ]; then echo "$failures failure(s)"; exit 1; fi
echo "all passed"
