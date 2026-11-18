#!/usr/bin/env bash
# Says whether a pull request changes nothing but its binge-ci pins, and pins them to one tagged release.
#
# Every consumer pins binge-ci by commit, in `uses:` lines and in a `binge-ci` submodule. A release moves all of
# them, and that update touches workflow files, which a human has to merge. This is the check that lets the pure
# pin update through without one: it is true only when EVERY change in the pull request is one of
#   - a `uses: ScottCooper92/binge-ci/<path>@<40 hex> # v1.0.N` line, the same line with a new commit and comment, or
#   - the `binge-ci` gitlink moving from one commit to another,
# every new commit is the same one, and that commit is the one the tag `v1.0.N` names in binge-ci's own repository
# and is on its `main`. A workflow edit beside the pin, a pin to a commit no release tag names, a pin to `v1`, an
# added or deleted line, another file: none of it is a pin-only change, and the normal rules apply.
#
# It decides by comparing each changed file's old and new lines one for one, not by reading a diff, so a changed line
# cannot hide in the parsing: the line counts must match, and every line that differs must be a pin that differs
# only in its commit and its comment. Anything it cannot read means "not pin-only", never an error: the answer
# `false` only ever keeps the normal rules in force.
#
# Environment: BASE and HEAD (commits of the pull request), OUT (GITHUB_OUTPUT). Optional BINGE_CI_URL (default
# binge-ci's public remote) and SUBMODULE_PATH (default binge-ci). Writes pin_only, reason, commit and version.
set -euo pipefail

: "${BASE:?}" "${HEAD:?}"
url=${BINGE_CI_URL:-https://github.com/ScottCooper92/binge-ci.git}
sub=${SUBMODULE_PATH:-binge-ci}
out=${OUT:-/dev/null}

emit() { printf '%s=%s\n' "$1" "$2" >> "$out"; }
no() {
  emit pin_only false
  emit reason "$*"
  echo "Not a pin-only change: $*"
  exit 0
}

# What a pin looks like: the part before `@` (indent, `- `, `uses:`, the action path), the commit, an optional comment.
pin_re='^([[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+ScottCooper92/binge-ci/[^@[:space:]]+)@([0-9a-f]{40})([[:space:]]+#[[:space:]]*(v1(\.0\.[0-9]+)?))?[[:space:]]*$'
file_re='^\.github/(workflows/[^/]+\.ya?ml|actions/[^/]+/action\.ya?ml)$'

mb=$(git merge-base "$BASE" "$HEAD" 2> /dev/null) || no "the pull request has no merge base with its base."

commits=()
versions=()
gitlink=""
changed=0

# -z so a path with any character is one path; --no-renames so a rename is a delete and an add, which is not a pin.
while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
  changed=$((changed + 1))
  read -r old_mode new_mode _old_sha new_sha status <<< "${meta#:}"
  if [ "$path" = "$sub" ]; then
    [ "$old_mode" = 160000 ] && [ "$new_mode" = 160000 ] && [ "$status" = M ] || no "$sub is not a submodule moving from one commit to another."
    gitlink=$new_sha
    continue
  fi
  [[ $path =~ $file_re ]] || no "$path is not a workflow or action file."
  [ "$old_mode" = "$new_mode" ] && [ "$status" = M ] || no "$path was added, deleted or had its mode changed."
  mapfile -t old_lines < <(git show "$mb:$path")
  mapfile -t new_lines < <(git show "$HEAD:$path")
  [ "${#old_lines[@]}" -eq "${#new_lines[@]}" ] || no "$path gained or lost lines."
  [ "$(git show "$mb:$path" | tail -c1 | od -An -c | tr -d ' ')" = "$(git show "$HEAD:$path" | tail -c1 | od -An -c | tr -d ' ')" ] \
    || no "$path changed how it ends."
  for i in "${!old_lines[@]}"; do
    [ "${old_lines[$i]}" = "${new_lines[$i]}" ] && continue
    [[ ${old_lines[$i]} =~ $pin_re ]] || no "$path line $((i + 1)) changed and was not a binge-ci pin."
    old_prefix=${BASH_REMATCH[1]}
    [[ ${new_lines[$i]} =~ $pin_re ]] || no "$path line $((i + 1)) is no longer a binge-ci pin."
    [ "${BASH_REMATCH[1]}" = "$old_prefix" ] || no "$path line $((i + 1)) names a different action."
    [ -n "${BASH_REMATCH[6]}" ] || no "$path line $((i + 1)) does not carry a v1.0.N tag comment (a pin to v1 or to no tag is not pin-only)."
    commits+=("${BASH_REMATCH[3]}")
    versions+=("${BASH_REMATCH[5]}")
  done
done < <(git diff -z --raw --no-renames --no-abbrev "$mb" "$HEAD")

[ "$changed" -gt 0 ] || no "the pull request changes nothing."

# Every new pin is one commit, and the gitlink, when it moved, is that commit too.
commit=""
if [ "${#commits[@]}" -gt 0 ]; then
  commit=$(printf '%s\n' "${commits[@]}" | sort -u)
  [ "$(printf '%s\n' "$commit" | wc -l)" -eq 1 ] || no "the new pins name more than one commit."
  version=$(printf '%s\n' "${versions[@]}" | sort -u)
  [ "$(printf '%s\n' "$version" | wc -l)" -eq 1 ] || no "the new pins name more than one release tag."
fi
if [ -n "$gitlink" ]; then
  [ -z "$commit" ] || [ "$gitlink" = "$commit" ] || no "the $sub submodule moved to a different commit than the pins."
  commit=$gitlink
fi
[ -n "$commit" ] || no "no pin changed."

# The commit has to be a release: the tag names it, in binge-ci's own repository, and it is on that repository's main.
scratch=$(mktemp -d)
trap 'rm -rf "${scratch:?}"' EXIT
git init -q --bare "$scratch"
git -C "$scratch" fetch -q --no-tags "$url" '+refs/heads/main:refs/heads/main' '+refs/tags/v1.0.*:refs/tags/v1.0.*' 2> /dev/null \
  || no "could not read binge-ci's tags and main from $url."
if [ -z "${version:-}" ]; then
  # Only the submodule moved: the release is whichever tag names the commit.
  version=$(git -C "$scratch" tag --points-at "$commit" | grep -E '^v1\.0\.[0-9]+$' | sort -t. -k3 -n | tail -n 1 || true)
  [ -n "$version" ] || no "no v1.0.N tag of binge-ci names $commit."
fi
[[ $version =~ ^v1\.0\.[0-9]+$ ]] || no "'$version' is not a v1.0.N tag."
tagged=$(git -C "$scratch" rev-parse -q --verify "refs/tags/$version^{commit}" 2> /dev/null) || no "binge-ci has no tag $version."
[ "$tagged" = "$commit" ] || no "the tag $version names $tagged, not $commit."
git -C "$scratch" merge-base --is-ancestor "$commit" refs/heads/main 2> /dev/null || no "$commit is not on binge-ci's main."

emit pin_only true
emit reason "every change is a pin to $version ($commit)."
emit commit "$commit"
emit version "$version"
echo "Pin-only change: every change is a pin to $version ($commit)."
