#!/usr/bin/env bash
#
# The steps of release-tag.yml, kept in a script so tools/test-release-tag.sh can run them against scratch
# repositories and a stubbed `gh`. The workflow tags a release when its PR merges, which hands a GitHub App
# the right to create tags a ruleset otherwise forbids. So nothing here takes the version on trust.
#
#   release-tag.sh decide   Reads the merge commit $SHA. Writes `release`, `version`, `pr` and `resume` to $OUT
#                           (GITHUB_OUTPUT). A merge that is not a release is `release=false` and a green exit.
#                           A merge that looks like a release and is not safe to tag exits non-zero, so the
#                           failure is reported rather than skipped.
#   release-tag.sh tag      Creates the tag $VERSION at $SHA, checks it, moves `v1`, checks that, then moves the
#                           `stable` branch that consumers' submodules follow. In that order, as CLAUDE.md says.
#   release-tag.sh report   Opens (or updates) one issue for a release whose tagging failed.
#
# Environment: REPO (owner/name), SHA, BEFORE (the push's previous main), GH_TOKEN, OUT, and for `tag` and `report` VERSION. Tags and branches are
# written through the API, so this needs no push credentials and no git identity.
set -euo pipefail

cd "$(dirname "$0")/.."
here="$(pwd)"
out="${OUT:-/dev/null}"
# release/v1.0.N is the only line that is tagged. A new major needs a new alias, which is a decision, not a branch name.
version_re='^v1\.0\.[0-9]+$'

say() { echo "$*" >&2; }
die() { echo "::error::$*" >&2; exit 1; }
emit() { printf '%s=%s\n' "$1" "$2" >> "$out"; }

patch_of() { printf '%s' "${1##*.}"; }

decide() {
  : "${REPO:?}" "${SHA:?}" "${BEFORE:?}"
  local prs pr head_ref head_repo merged_by merged_type number version newest

  # The pull request this commit is the merge of. A direct push to main, or a squash of something else, has none.
  prs=$(gh api "repos/$REPO/commits/$SHA/pulls") || die "could not list the pull requests for $SHA"
  pr=$(jq -c --arg sha "$SHA" '[.[] | select(.merge_commit_sha == $sha and .merged_at != null)] | .[0] // empty' <<< "$prs")
  if [ -z "$pr" ]; then
    say "$SHA is not the merge of a pull request: not a release."
    emit release false
    return 0
  fi
  number=$(jq -r '.number' <<< "$pr")
  # The list above is the simple pull request schema, which has no merged_by. Only the single-PR read does.
  pr=$(gh api "repos/$REPO/pulls/$number") || die "could not read PR #$number"
  head_ref=$(jq -r '.head.ref' <<< "$pr")
  head_repo=$(jq -r '.head.repo.full_name // ""' <<< "$pr")
  merged_by=$(jq -r '.merged_by.login // ""' <<< "$pr")
  merged_type=$(jq -r '.merged_by.type // ""' <<< "$pr")
  case "$head_ref" in
    release/v*) ;;
    *)
      say "PR #$number came from '$head_ref', not a release/v* branch: not a release."
      emit release false
      return 0
      ;;
  esac

  # From here the merge looks like a release, so anything wrong is an error rather than a skip.
  version=${head_ref#release/}
  emit pr "$number"
  emit version "$version"
  [[ $version =~ $version_re ]] || die "the branch '$head_ref' does not name a v1.0.N release."
  [ "$head_repo" = "$REPO" ] || die "PR #$number came from '$head_repo', not from a branch of $REPO. A fork does not cut a release."
  [ "$merged_type" = User ] || die "PR #$number was merged by '${merged_by:-nobody}' ($merged_type), not by a person."

  # Tags are read from the checkout, which fetched them all.
  newest=$(git tag --list 'v1.0.*' | grep -E "$version_re" | sort -t. -k3 -n | tail -n 1 || true)
  [ -n "$newest" ] || die "no v1.0.N tag exists to follow; the first release is cut by hand."
  local resume=false
  if git rev-parse -q --verify "refs/tags/$version" > /dev/null; then
    [ "$(git rev-parse "refs/tags/$version^{commit}")" = "$SHA" ] \
      || die "$version already exists at $(git rev-parse "refs/tags/$version^{commit}"), not at $SHA. A tag is never moved."
    resume=true
    say "$version already names $SHA: resuming a release that was tagged only in part."
  else
    [ "$(patch_of "$version")" -gt "$(patch_of "$newest")" ] \
      || die "$version is not newer than $newest, the newest tag."
  fi

  # The tree has to say the same thing as the branch name.
  git rev-parse -q --verify "$SHA^{commit}" > /dev/null || die "$SHA is not in this checkout."
  # A rebase merge lands several commits in one push, so the diff is everything the push brought, not the last commit.
  git rev-parse -q --verify "$BEFORE^{commit}" > /dev/null 2>&1 || die "the push's previous head $BEFORE is not in this checkout."
  git merge-base --is-ancestor "$BEFORE" "$SHA" || die "$BEFORE is not an ancestor of $SHA: main was not fast-forwarded to the merge."
  local pins
  pins=$(git grep -hoE '^[[:space:]]*(- )?uses:[[:space:]]*ScottCooper92/binge-ci/[^[:space:]]*' "$SHA" -- '.github/workflows/*.yml' '.github/actions/*/action.yml' \
         | sed 's/.*@//' | sort -u)
  [ "$pins" = "$version" ] || die "the branch names $version, but the self-references at $SHA pin '$(printf '%s ' $pins)'."

  # A release is the self-reference bump and nothing else. That is what lets a tag be cut without a person reading it.
  local files
  files=$(git diff --no-renames --name-only -z "$BEFORE" "$SHA" | tr '\0' '\n')
  [ -n "$files" ] || die "the merge changes nothing."
  if grep -qvE '^\.github/(workflows|actions/[^/]+)/[^/]+\.yml$' <<< "$files"; then
    die "the merge changes more than workflow and action files: $(grep -vE '^\.github/(workflows|actions/[^/]+)/[^/]+\.yml$' <<< "$files" | head -3 | tr '\n' ' ')"
  fi
  # File by file, byte for byte: the file at BEFORE with the previous release's self-references rewritten to this
  # release's has to be exactly the file at SHA. A multiset of changed lines is not enough: it accepts two
  # self-reference lines swapped within a workflow, or one moved to another workflow, and a swap can hand a job
  # with write access an action another job used. This also refuses an added or deleted file and a mode change.
  local prev prev_re f before_mode sha_mode
  prev=$(git tag --list 'v1.0.*' | grep -E "$version_re" | awk -F. -v n="$(patch_of "$version")" '$3 + 0 < n' | sort -t. -k3 -n | tail -n 1 || true)
  [ -n "$prev" ] || die "no release older than $version exists to bump from."
  if [ "$resume" = false ]; then
    [ "$prev" = "$newest" ] || die "the previous release is $prev, not $newest."
  fi
  prev_re=${prev//./\\.}
  local scratch
  scratch=$(mktemp -d)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    git cat-file -e "$BEFORE:$f" 2> /dev/null || die "$f did not exist before the merge: a release adds no file."
    git cat-file -e "$SHA:$f" 2> /dev/null || die "$f is deleted by the merge: a release deletes no file."
    before_mode=$(git ls-tree "$BEFORE" -- "$f" | awk '{print $1}')
    sha_mode=$(git ls-tree "$SHA" -- "$f" | awk '{print $1}')
    [ "$before_mode" = "$sha_mode" ] || die "$f changes mode: a release changes only self-references."
    git show "$BEFORE:$f" | sed -E "s#(ScottCooper92/binge-ci/[^[:space:]@]*)@${prev_re}([^0-9]|\$)#\\1@${version}\\2#g" > "$scratch/expected"
    git show "$SHA:$f" > "$scratch/actual"
    cmp -s "$scratch/expected" "$scratch/actual" || die "$f differs from the previous release's copy by more than $prev becoming $version."
  done <<< "$files"
  rm -rf "$scratch"

  # The rest of the reference rules (no './', one tag, immutable).
  CHECK_ROOT="$here" bash tools/check-internal-refs.sh > /dev/null || die "tools/check-internal-refs.sh fails at $SHA."

  emit release true
  emit resume "$resume"
  say "PR #$number is the $version release. Tagging $SHA."
}

# A re-run of an older release must not drag an alias back past a newer one, so v1 and stable have to be
# behind the commit being tagged, or at it, before anything is moved.
only_forward() {
  local name=$1 ref=$2 at
  at=$(git rev-parse -q --verify "$ref^{commit}" 2> /dev/null) || return 0
  git merge-base --is-ancestor "$at" "$SHA" \
    || die "$name is at $at, which is not behind $SHA, so moving it would take it backwards. Nothing was moved."
}

ref_exists() { gh api "repos/$REPO/git/ref/$1" > /dev/null 2>&1; }

tag() {
  : "${REPO:?}" "${SHA:?}" "${VERSION:?}"
  [[ $VERSION =~ $version_re ]] || die "'$VERSION' is not a v1.0.N release."
  # 1. The release tag, lightweight, at the merge commit. Skipped when a half-finished run already made it.
  if ref_exists "tags/$VERSION"; then
    say "$VERSION exists already."
  else
    gh api -X POST "repos/$REPO/git/refs" -f "ref=refs/tags/$VERSION" -f "sha=$SHA" > /dev/null || die "could not create $VERSION."
    say "Created $VERSION at $SHA."
  fi
  git fetch -q --force --tags origin
  git fetch -q origin "+refs/heads/stable:refs/remotes/origin/stable" 2> /dev/null || true
  only_forward v1 refs/tags/v1
  only_forward stable refs/remotes/origin/stable
  PUSHED_REF="$VERSION" PUSHED_SHA="$SHA" bash tools/check-internal-refs.sh --resolve \
    || die "the tag checks fail for $VERSION. v1 was NOT moved."
  # 2. Only then the alias consumers follow.
  if ref_exists tags/v1; then
    gh api -X PATCH "repos/$REPO/git/refs/tags/v1" -f "sha=$SHA" -F force=true > /dev/null || die "could not move v1. $VERSION is tagged."
  else
    gh api -X POST "repos/$REPO/git/refs" -f ref=refs/tags/v1 -f "sha=$SHA" > /dev/null || die "could not create v1. $VERSION is tagged."
  fi
  say "Moved v1 to $SHA."
  git fetch -q --force --tags origin
  PUSHED_REF=v1 PUSHED_SHA="$SHA" bash tools/check-internal-refs.sh --resolve \
    || die "the tag checks fail after v1 moved to $SHA. Every consumer on v1 is affected: check the run."
  # 3. The branch a consumer's submodule follows. A fast-forward only: a releases branch that is not a line is a mistake.
  if ref_exists heads/stable; then
    gh api -X PATCH "repos/$REPO/git/refs/heads/stable" -f "sha=$SHA" -F force=false > /dev/null \
      || die "could not fast-forward the stable branch to $SHA. $VERSION is tagged and v1 has moved."
  else
    gh api -X POST "repos/$REPO/git/refs" -f ref=refs/heads/stable -f "sha=$SHA" > /dev/null \
      || die "could not create the stable branch. $VERSION is tagged and v1 has moved."
  fi
  say "stable is at $SHA."
}

report() {
  : "${REPO:?}" "${VERSION:?}" "${RUN_URL:?}"
  local marker="<!-- release-tag:$VERSION -->" body existing
  body="$marker
The release workflow could not finish tagging $VERSION. It stopped at the step the run log names: $RUN_URL

If the run log stops at the token step, the release App's secrets are not set up in the \`release\` environment.

State to check by hand: \`git ls-remote --tags origin $VERSION v1\` and the \`stable\` branch. The order is the release tag, then \`v1\`, then \`stable\`; nothing after a failed step ran. Re-running the workflow resumes a release that was tagged in part, and refuses one whose tag names another commit."
  existing=$(gh issue list --repo "$REPO" --state open --limit 100 --json number,body \
               --jq "[.[] | select(.body | contains(\"$marker\"))] | .[0].number // empty") \
    || die "could not look for an existing issue."
  if [ -n "$existing" ]; then
    gh issue comment "$existing" --repo "$REPO" --body "Failed again: $RUN_URL" > /dev/null
  else
    gh issue create --repo "$REPO" --title "Release $VERSION: tagging failed" --body "$body" > /dev/null
  fi
}

case "${1:-}" in
  decide) decide ;;
  tag) tag ;;
  report) report ;;
  *) echo "usage: release-tag.sh decide|tag|report" >&2; exit 2 ;;
esac
