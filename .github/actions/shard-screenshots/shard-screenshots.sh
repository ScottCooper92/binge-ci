#!/usr/bin/env bash
# Splits the screenshot test classes into N shards, so each shard renders in a JVM of its own.
#
# The render holds every frame's native memory until its JVM exits, so one JVM for the whole
# suite grows with the suite: past what a hosted runner has, the job stalls and is cancelled at
# its time limit with no log. Each shard renders a share and exits.
#
# Usage: shard-screenshots.sh <shards> <index> [<test dir> [<reference dir>]]
# Prints the `--tests` arguments for shard <index> (0-based), one per line. A class is a file in
# the test dir with a `class …ScreenshotTest` (modifiers allowed); its weight is how many reference PNGs it has
# (a class with none yet counts 1). Heaviest classes are placed first, each on the lightest shard,
# ties by name, so the split is stable and every class lands in exactly one shard.
set -euo pipefail

shards="${1:?shards}"
index="${2:?index}"
tests="${3:-app/src/screenshotTest}"
refs="${4:-app/src/screenshotTestDebug/reference}"

# A shard count or index that is not a whole number would reach awk as 0 and put every class on one
# shard, so it is refused here. An index past the last shard would print nothing and look like an empty one.
[[ $shards =~ ^[1-9][0-9]*$ ]] || { echo "shards must be a positive whole number, not '$shards'" >&2; exit 1; }
[[ $index =~ ^[0-9]+$ ]] && [ "$index" -lt "$shards" ] || { echo "index must be a whole number below $shards, not '$index'" >&2; exit 1; }

# A reference directory that is not there is a mistyped path or a variant that is not debug. Counting
# it as holding no frames would skip the orphan check too, so it stops here with its name.
[ -d "$refs" ] || { echo "reference directory '$refs' does not exist; check the reference_dir input (an empty directory is fine for a module with no frames recorded yet)" >&2; exit 1; }

# Fail closed: a frame no shard names is a frame nothing validates, and CI would stay green.
# A class may carry modifiers; a `@PreviewTest` at the top level of a file, or in a file with no matched class, is an error.
# A second class in a file that has a matched one is not checked.
class_re='^[[:space:]]*((public|internal|private|open|final|abstract)[[:space:]]+)*class[[:space:]]+[A-Za-z0-9_]*ScreenshotTest\b'
while IFS= read -r f; do
  # An annotation, not a mention: a doc comment may name `@PreviewTest` without being a frame.
  if grep -qE '^[[:space:]]*@PreviewTest' "$f"; then
    if grep -qE '^@PreviewTest' "$f"; then
      echo "$f: a top-level @PreviewTest is in no class, so in no shard; put it in a *ScreenshotTest class" >&2
      exit 1
    fi
    if ! grep -qE "$class_re" "$f"; then
      echo "$f: has @PreviewTest but no class named *ScreenshotTest, so no shard would run it" >&2
      exit 1
    fi
  fi
done < <(find "$tests" -name '*.kt')

classes="$(grep -rhE "$class_re" "$tests" | sed -E 's/^.*class[[:space:]]+([A-Za-z0-9_]*ScreenshotTest).*$/\1/' | sort -u)"
[ -n "$classes" ] || { echo "no screenshot test classes under $tests" >&2; exit 1; }

# A reference directory no class owns is a frame nothing renders, and the validate task does not
# fail on it. Fail here so a renamed or deleted class takes its PNGs with it.
while IFS= read -r d; do
  grep -qx "$d" <<< "$classes" || { echo "$d: reference PNGs with no *ScreenshotTest class; delete them or restore the class" >&2; exit 1; }
done < <(find "$refs" -type d -name '*ScreenshotTest' -exec basename {} \; 2>/dev/null | sort -u)

weighted=""
while IFS= read -r c; do
  n="$(find "$refs" -type d -name "$c" -exec find {} -name '*.png' \; 2>/dev/null | wc -l | tr -d ' ')"
  [ "$n" -gt 0 ] || n=1
  weighted+="$n $c"$'\n'
done <<< "$classes"

printf '%s' "$weighted" | sort -k1,1nr -k2,2 | awk -v shards="$shards" -v want="$index" '
  BEGIN { for (i = 0; i < shards; i++) load[i] = 0 }
  {
    best = 0
    for (i = 1; i < shards; i++) if (load[i] < load[best]) best = i
    load[best] += $1
    if (best == want) printf "--tests\n*.%s\n", $2
  }'
