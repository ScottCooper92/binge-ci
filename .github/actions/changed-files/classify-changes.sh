#!/usr/bin/env bash
# Decides which CI jobs a diff can affect, from the changed paths, each ending in a NUL, in the file given as
# $1 (`git diff -z --name-only`: without it git quotes a path with a non-ASCII character, a quote or a tab,
# and a quoted path matches no pattern, which for the release allow-list means a wrongly skipped build).
# Prints `product=`, `screens=` and `release=`, each true or false, one per line.
#
# A job is skipped only when EVERY changed path is in a closed, finite set that provably cannot affect
# it. For `product` and `screens` a path in no set runs the job. `release` is the reverse, an allow-list:
# it runs only for a listed input, so a new R8 input must be added to RELEASE_INPUTS or the job is skipped
# for it. An empty diff runs everything, and so does anything this script cannot read.
#
#   product  the Gradle jobs. False only when every path is in PRODUCT_NONE: documentation or tooling
#            nothing compiles or packages.
#   screens  the screenshot frames. False when every path that is product is also in NO_FRAMES.
#   release  the R8 build. True when any path is in RELEASE_INPUTS.
#
# Each list is read from the environment, one bash glob per line. A `*` matches across `/`. The first
# line that matches a path decides: a `!` in front of a pattern puts the path OUT of the set, so a
# narrow exception goes above the broad pattern it carves out of. Blank lines and lines starting with `#`
# are ignored, and so is whitespace around a pattern, and after a `!`. A path in both PRODUCT_NONE and RELEASE_INPUTS does not
# reach the release build: PRODUCT_NONE says nothing is built from it, and it wins.
set -euo pipefail

list="${1:?usage: classify-changes.sh <file listing the changed paths, NUL-terminated>}"
: "${RELEASE_INPUTS:?RELEASE_INPUTS is empty: an empty allow-list would skip the release build for every pull request}"

# in_set <path> <patterns>: succeeds when the first matching pattern is not negated.
in_set() {
  local path="$1" patterns="${2:-}" line pattern negated
  while IFS= read -r line; do
    # A trailing space, a CRLF or the indent of a YAML block would otherwise make a pattern match nothing,
    # and for the release allow-list that silently drops the rule.
    line="${line//$'\r'/}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in '' | '#'*) continue ;; esac
    pattern="${line#!}"
    negated=false
    [ "$pattern" = "$line" ] || negated=true
    # `! pattern` is `!pattern`: a pattern with a space in front of it would match nothing, and a carve-out
    # that matches nothing is a path the broad pattern above it skips.
    pattern="${pattern#"${pattern%%[![:space:]]*}"}"
    # Stripping the longest prefix the glob matches leaves nothing exactly when it matches the whole
    # path, and `*` crosses `/`.
    if [ -z "${path##$pattern}" ]; then
      [ "$negated" = false ]
      return
    fi
  done <<< "$patterns"
  return 1
}

paths=()
while IFS= read -r -d '' path; do
  [ -n "$path" ] && paths+=("$path")
done < "$list"

if [ "${#paths[@]}" -eq 0 ]; then
  echo "No changed paths to read: running everything." >&2
  printf 'product=true\nscreens=true\nrelease=true\n'
  exit 0
fi

product=false screens=false release=false
for path in "${paths[@]}"; do
  in_set "$path" "${PRODUCT_NONE:-}" && continue
  product=true
  in_set "$path" "${NO_FRAMES:-}" || screens=true
  in_set "$path" "$RELEASE_INPUTS" && release=true
done

printf 'product=%s\nscreens=%s\nrelease=%s\n' "$product" "$screens" "$release"
