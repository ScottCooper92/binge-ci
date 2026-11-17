#!/usr/bin/env bash
#
# Moves one submodule's pin in the calling repository to the head of that submodule's default
# branch, in a pull request that holds one commit changing nothing else.
#
# Run from the root of the caller's checkout, on its default branch, with the submodules initialised
# and the checkout's credentials able to push. Environment: SUBMODULE_PATH, BASE_BRANCH, REPO,
# GH_TOKEN; optional PRIVATE_SUBMODULES (the caller's `private_submodules`), BRANCH (the submodule's branch; empty means its remote's default), AGENT_LABEL,
# DRY_RUN, BOT_NAME, BOT_EMAIL. GITHUB_OUTPUT and GITHUB_STEP_SUMMARY are written when set.
#
# What it does, by what it finds:
#   pin is the head                 nothing: status `current`
#   pin is not behind the head      skipped: a held pin or one ahead of the branch is not ours to move
#   no open bump PR                 branch rebuilt from the base tip with one commit, PR opened
#   open bump PR, all commits ours  branch rebuilt the same way, PR updated
#   a bump branch with a commit not ours, PR open or not: the new pin commit is added on top; nobody's work is force-pushed over
#   open bump PR with a conflict    left alone: the conflict bot owns it
# A second run against the same head changes nothing.
export LC_ALL=C
set -euo pipefail

: "${SUBMODULE_PATH:?SUBMODULE_PATH is required}"
: "${BASE_BRANCH:?BASE_BRANCH is required}"
: "${REPO:?REPO is required}"
BRANCH=${BRANCH:-}
AGENT_LABEL=${AGENT_LABEL:-agent}
PRIVATE_SUBMODULES=${PRIVATE_SUBMODULES:-}
DRY_RUN=${DRY_RUN:-false}
BOT_NAME=${BOT_NAME:-github-actions[bot]}
BOT_EMAIL=${BOT_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
out=${GITHUB_OUTPUT:-/dev/null}
max_commits=100
max_migration_chars=20000

path=$SUBMODULE_PATH
status=failed
detail=''
pr_number=''
pr_url=''
head=''
work=$(mktemp -d)

# Every outcome reports, and a failure with a PR already open says so on it, once per head: a run
# that dies silently leaves a week-old pin that nobody is told is stuck.
finish() {
  local rc=$?
  set +e
  {
    echo "### Submodule bump: \`$path\`"
    echo "- Status: **$status**${detail:+, $detail}"
    [ -z "$pr_url" ] || echo "- Pull request: $pr_url"
  } >> "$summary"
  {
    echo "status=$status"
    echo "pull_request=$pr_url"
  } >> "$out"
  if [ "$rc" -ne 0 ] && [ -n "$pr_number" ] && [ "$DRY_RUN" != true ]; then
    local marker="<!-- submodule-bump-failed:$path:${head:-unknown} -->"
    # Paginated, and captured before it is searched: the endpoint returns 30 comments a page, oldest first,
    # and a bump PR the bots comment on freely outgrows that.
    existing=$(gh api "repos/$REPO/issues/$pr_number/comments?per_page=100" --paginate --jq '.[].body' 2> /dev/null)
    if ! grep -qF -- "$marker" <<< "$existing"; then
      printf '%s\nThe submodule bump for `%s` failed on this PR: %s/%s/actions/runs/%s\n' \
        "$marker" "$path" "${GITHUB_SERVER_URL:-https://github.com}" "$REPO" "${GITHUB_RUN_ID:-0}" > "$work/failed.md"
      gh api -X POST "repos/$REPO/issues/$pr_number/comments" -F body=@"$work/failed.md" > /dev/null 2>&1
    fi
  fi
  rm -rf "$work"
  exit "$rc"
}
trap finish EXIT

die() {
  detail=$1
  echo "::error::$1" >&2
  exit 1
}

if ! [[ $path =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]*$ ]] || [[ $path == *..* ]]; then
  die "submodule_path '$path' is not a plain relative path"
fi
pinned=$(git ls-tree HEAD -- "$path" | awk '$2 == "commit" {print $3}')
[ -n "$pinned" ] || die "$path is not a submodule of the checked-out commit"
git -C "$path" rev-parse --git-dir > /dev/null 2>&1 || die "$path is not checked out: initialise the submodule first"

branch=$BRANCH
if [ -z "$branch" ]; then
  url=$(git -C "$path" config --get remote.origin.url)
  branch=$(git ls-remote --symref "$url" HEAD | awk 'NR == 1 {print $2}')
  branch=${branch#refs/heads/}
  [ -n "$branch" ] || die "could not read the default branch of the submodule's remote"
fi
# actions/checkout leaves a submodule shallow; the commit list and the ancestry check need the history.
git -C "$path" fetch --quiet --depth=2147483647 origin "+refs/heads/$branch:refs/remotes/origin/$branch" \
  || die "could not fetch branch '$branch' of the submodule"
head=$(git -C "$path" rev-parse "refs/remotes/origin/$branch")
short() { printf '%.7s' "$1"; }

if [ "$pinned" = "$head" ]; then
  status=current
  detail="pinned at the head of $branch"
  exit 0
fi

git -C "$path" cat-file -e "$pinned^{commit}" 2> /dev/null || git -C "$path" fetch --quiet origin "$pinned" 2> /dev/null || true
rc=0
git -C "$path" merge-base --is-ancestor "$pinned" "$head" 2> /dev/null || rc=$?
if [ "$rc" -eq 1 ]; then
  status=skipped
  detail="the pin $(short "$pinned") is not an ancestor of $branch (held, or ahead of it), so it is not moved"
  echo "::notice::$detail"
  exit 0
elif [ "$rc" -ne 0 ]; then
  die "could not compare the pin $(short "$pinned") with $branch (git exited $rc)"
fi

bump_branch="submodule-bump/$(printf '%s' "$path" | tr -c 'A-Za-z0-9._\n-' '-')"
owner=${REPO%%/*}
prs=$(gh api "repos/$REPO/pulls?head=$owner:$bump_branch&state=open") || die "could not list the open pull requests"
pr_number=$(jq -r '.[0].number // empty' <<< "$prs")
pr_url=$(jq -r '.[0].html_url // empty' <<< "$prs")

git config user.name "$BOT_NAME"
git config user.email "$BOT_EMAIL"
git fetch --quiet --depth=2147483647 origin "$BASE_BRANCH" || die "could not fetch $BASE_BRANCH"
old_remote=''
if [ -n "$(git ls-remote --heads origin "$bump_branch")" ]; then
  git fetch --quiet --depth=2147483647 origin "+refs/heads/$bump_branch:refs/remotes/origin/$bump_branch" || die "could not fetch $bump_branch"
  old_remote=$(git rev-parse "refs/remotes/origin/$bump_branch")
fi

mode=rebuild
if [ -n "$pr_number" ]; then
  mergeable=$(gh api "repos/$REPO/pulls/$pr_number" | jq -r '.mergeable')
  if [ "$mergeable" = false ]; then
    status=skipped
    detail="the open bump PR has a merge conflict, which is left to the conflict bot"
    exit 0
  fi
  branch_pin=$(git ls-tree "$old_remote" -- "$path" | awk '$2 == "commit" {print $3}')
  if [ "$branch_pin" = "$head" ]; then
    status=current
    detail="the open bump PR already pins $(short "$head")"
    exit 0
  fi
fi

# Whether or not a PR is open: a branch left behind by a closed PR may still hold someone's work.
if [ -n "$old_remote" ]; then
  foreign=0
  while IFS='|' read -r email subject; do
    if [ "$email" != "$BOT_EMAIL" ] || [[ $subject != "chore: bump "* ]]; then foreign=$((foreign + 1)); fi
  done < <(git log --format='%ae|%s' "origin/$BASE_BRANCH..$old_remote")
  [ "$foreign" -eq 0 ] || mode=stack
fi

# A private submodule's commit subjects and migration notes must not reach a public repository's PR.
# The submodule is private when the caller lists it in `private_submodules`, matched by the name of
# its remote's repository. The caller is taken to be public unless the API says it is private, so a
# lookup that fails redacts rather than leaks.
redact=false
if [ -n "$PRIVATE_SUBMODULES" ]; then
  sub_url=$(git -C "$path" config --get remote.origin.url)
  sub_repo=$(basename "${sub_url%/}" .git)
  listed=false
  while IFS= read -r name; do
    name=${name//[[:space:]]/}
    if [ -n "$name" ] && [ "${name,,}" = "${sub_repo,,}" ]; then listed=true; fi
  done < <(printf '%s\n' "${PRIVATE_SUBMODULES//,/$'\n'}")
  if [ "$listed" = true ]; then
    caller_private=$(gh api "repos/$REPO" --jq .private 2> /dev/null) || caller_private=unknown
    [ "$caller_private" = true ] || redact=true
  fi
fi

# The body quotes text from another repository, so it goes in fences: nothing in a commit subject or
# a migration note can @mention anyone, render as markup, or forge the marker comments.
# A line of three or more tildes, indented up to three spaces, could close the fence, so it gets a backslash.
tidy() { sed -E -e 's/<!--/<!- -/g' -e 's/^( {0,3})(~{3,})/\1\\\2/'; }
fence='~~~~~~~~'
total=$(git -C "$path" rev-list --count "$pinned..$head")
commit_format='%h %s'
[ "$redact" != true ] || commit_format='%h'
{
  echo "## What and why"
  echo
  echo "Moves the \`$path\` submodule pin from \`$(short "$pinned")\` to \`$(short "$head")\`, the head of \`$branch\`. Opened by the submodule-bump workflow."
  echo
  echo "## Commits ($total)"
  echo
  if [ "$redact" = true ]; then
    echo "The submodule is private and this repository is public, so only the short shas are listed. The subjects and any migration notes are in the submodule's own history."
    echo
  fi
  echo "$fence"
  # sed reads all of its input, unlike head: a producer that outlives its consumer dies of SIGPIPE, and
  # under pipefail that ends the script on exactly the long ranges the cap exists for.
  git -C "$path" log --reverse --format="${commit_format}" "$pinned..$head" | sed -n "1,${max_commits}p" | tidy
  [ "$total" -le "$max_commits" ] || echo "... and $((total - max_commits)) more"
  echo "$fence"
} > "$work/body.md"
migrations=''
[ "$redact" = true ] || migrations=$(git -C "$path" diff -U0 --no-color "$pinned" "$head" -- docs/migrations.md 2> /dev/null \
  | awk '/^@@/ {h = 1; next} h && /^\+/ {print substr($0, 2)}' | head -c "$max_migration_chars" | tidy || true)
if [ -n "${migrations//[[:space:]]/}" ]; then
  {
    echo
    echo "## Migrations"
    echo
    echo "Entries \`docs/migrations.md\` gained in this range:"
    echo
    echo "$fence"
    echo "$migrations"
    echo "$fence"
  } >> "$work/body.md"
fi
echo "<!-- submodule-bump:$path:$head -->" >> "$work/body.md"
title="chore: bump $path to $(short "$head")"

if [ "$DRY_RUN" = true ]; then
  status=dry-run
  detail="would $([ -n "$pr_number" ] && echo update || echo open) a PR moving the pin $(short "$pinned") -> $(short "$head") ($total commits)"
  echo "$detail"
  exit 0
fi

if [ "$mode" = stack ]; then
  git checkout --quiet -B "$bump_branch" "$old_remote"
else
  git checkout --quiet -B "$bump_branch" "origin/$BASE_BRANCH"
fi
git update-index --add --cacheinfo "160000,$head,$path"
# A branch left behind by a closed PR can already pin the head, and then there is nothing to commit.
if ! git diff --cached --quiet; then
  git commit --quiet -m "$title" -m "Moves the pin from $(short "$pinned") to $(short "$head"), $total commit(s) on $branch."
fi
if [ "$mode" = stack ]; then
  git push --quiet origin "HEAD:refs/heads/$bump_branch"
else
  # Leased against what was fetched, so a push that landed since is never overwritten.
  git push --quiet --force-with-lease="refs/heads/$bump_branch:$old_remote" origin "HEAD:refs/heads/$bump_branch"
fi

if [ -n "$pr_number" ]; then
  gh api -X PATCH "repos/$REPO/pulls/$pr_number" -f title="$title" -F body=@"$work/body.md" > /dev/null
  status=updated
  detail="moved the open PR to $(short "$head")${mode:+ ($mode)}"
else
  created=$(gh api -X POST "repos/$REPO/pulls" -f title="$title" -f head="$bump_branch" -f base="$BASE_BRANCH" -F body=@"$work/body.md")
  pr_number=$(jq -r '.number' <<< "$created")
  pr_url=$(jq -r '.html_url' <<< "$created")
  status=opened
  detail="pin $(short "$pinned") -> $(short "$head")"
fi
gh api -X POST "repos/$REPO/issues/$pr_number/labels" -f "labels[]=$AGENT_LABEL" > /dev/null
