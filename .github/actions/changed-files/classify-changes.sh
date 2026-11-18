#!/usr/bin/env bash
# Decides which CI jobs a diff can affect, from the changed paths, one per line, in the file given as $1.
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
# are ignored.
set -euo pipefail

list="${1:?usage: classify-changes.sh <file listing the changed paths>}"
: "${RELEASE_INPUTS:?RELEASE_INPUTS is empty: an empty allow-list would skip the release build for every pull request}"

# in_set <path> <patterns>: succeeds when the first matching pattern is not negated.
in_set() {
  local path="$1" patterns="${2:-}" line pattern
  while IFS= read -r line; do
    case "$line" in '' | '#'*) continue ;; esac
    pattern="${line#!}"
    # Stripping the longest prefix the glob matches leaves nothing exactly when it matches the whole
    # path, and `*` crosses `/`.
    if [ -z "${path##$pattern}" ]; then
      [ "$pattern" = "$line" ]
      return
    fi
  done <<< "$patterns"
  return 1
}

paths=()
while IFS= read -r path; do
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
