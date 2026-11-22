#!/usr/bin/env bash
# Fails if R8 renamed one of an app's classes in a release build.
#
# A `-keepnames` rule is how an app keeps the names a stack frame, a reflective lookup or a log matcher depends on. The
# minified debug build a device lane runs is not the build users run, so a removed or narrowed rule would show only
# on a user's device. This reads the release build's R8 mapping instead, and holds a short list of classes to their own names.
#
# Usage: check-r8-names.sh <mapping.txt> <class> [<class> ...]
# A class line in the mapping is `original.Name -> final.Name:` at the start of a line (members are indented). Every
# class named must be there and must map to itself. A class missing from the mapping fails too: a class that was renamed
# or removed makes the list stale, and a check that finds nothing must not pass. -keepnames does not stop R8 merging or
# generating classes, so this checks a short list the caller chose and not every class.
# Set R8_KEEP_RULE_HINT to a sentence naming the keep rule, and it is added to a failure.
set -euo pipefail

mapping="${1:?usage: check-r8-names.sh <mapping.txt> <class> [<class> ...]}"
shift
[ "$#" -gt 0 ] || { echo "no classes were named: a check of nothing must not pass" >&2; exit 1; }
[ -s "$mapping" ] || { echo "$mapping is missing or empty: the release build wrote no R8 mapping" >&2; exit 1; }

hint="${R8_KEEP_RULE_HINT:-}"
failed=0
for name in "$@"; do
  # The class line only: it starts at column 0 as `name -> final:`, so a member line (indented) or a longer name never
  # matches. An exact string compare, so a dot or a dollar sign in a name is itself and not a pattern.
  final="$(awk -v n="$name" '$1 == n && $2 == "->" { print $3; exit }' "$mapping")"
  if [ -z "$final" ]; then
    echo "$name is not in the R8 mapping: the class was renamed, removed or shrunk away. Update the list of classes." >&2
    failed=1
    continue
  fi
  final="${final%:}"
  if [ "$final" != "$name" ]; then
    echo "R8 renamed $name to $final.${hint:+ $hint}" >&2
    failed=1
  fi
done

[ "$failed" -eq 0 ] && echo "check-r8-names: $# class(es) keep their names"
exit "$failed"
