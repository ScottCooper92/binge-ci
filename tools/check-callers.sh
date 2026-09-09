#!/usr/bin/env bash
#
# Every `with:` key in a draft caller must be a declared input of the reusable
# workflow it calls, and every required secret must reach it.
#
# This exists because actionlint cannot see across a REMOTE reusable-workflow
# reference. For a local `./.github/workflows/x.yml` call it validates the inputs;
# for `ScottCooper92/binge-ci/...@v1` it cannot fetch the target, so a caller
# passing a misspelled or removed input is accepted silently here and fails at run
# time in the consuming repo - the one place the failure is expensive.
#
# `secrets: inherit` satisfies the secret check by definition. It is accepted but
# not preferred: naming the three secrets passes exactly those, where `inherit`
# hands the called workflow every secret the caller holds.
set -uo pipefail

cd "$(dirname "$0")/.."

keys() { # $1=file  $2=start regex  $3=stop regex  $4=key indent  $5=key charclass
  awk -v start="$2" -v stop="$3" -v ind="$4" -v cc="$5" '
    $0 ~ start {f=1; next}
    f && $0 ~ stop {f=0}
    f && $0 ~ "^" ind cc "+:" { line=$0; sub(/:.*/,"",line); gsub(/ /,"",line); print line }
  ' "$1" | sort -u
}

fail=0
for caller in callers/*/*.yml; do
  wf=$(basename "$caller"); reusable=".github/workflows/$wf"
  if [ ! -f "$reusable" ]; then
    echo "FAIL $caller"; echo "     no reusable workflow at $reusable"; fail=1; continue
  fi
  inputs=$(keys  "$reusable" '^    inputs:'  '^    secrets:' '      ' '[a-z_]')
  secrets=$(keys "$reusable" '^    secrets:' '^permissions:' '      ' '[A-Z_]')
  used=$(keys    "$caller"   '^    with:'    '^    secrets:' '      ' '[a-z_]')
  # Inputs with `required: true` and no default. Omitting one is a run-time failure in
  # the consuming repo, which is the same class of silence the undeclared-input check
  # exists for, arrived at from the other side.
  required=$(awk '
    /^    inputs:/ {f=1; next}
    /^    secrets:/ {f=0}
    f && /^      [a-z_]+:/ { name=$0; sub(/:.*/,"",name); gsub(/ /,"",name); req=0 }
    f && /^        required: *true/ { if (name != "") print name }
  ' "$reusable" | sort -u)
  if grep -qE '^    secrets: *inherit *$' "$caller"; then
    passed="$secrets"
  else
    passed=$(keys "$caller" '^    secrets:' '^[a-z]' '      ' '[A-Z_]')
  fi
  bad=$(comm -23 <(printf '%s\n' "$used")     <(printf '%s\n' "$inputs")   | grep -v '^$')
  unset_req=$(comm -23 <(printf '%s\n' "$required") <(printf '%s\n' "$used")     | grep -v '^$')
  missing=$(comm -23 <(printf '%s\n' "$secrets")  <(printf '%s\n' "$passed")   | grep -v '^$')
  if [ -n "$bad" ] || [ -n "$missing" ] || [ -n "$unset_req" ]; then
    fail=1; echo "FAIL $caller"
    [ -n "$bad" ]       && echo "     undeclared inputs:   $(echo "$bad")"
    [ -n "$unset_req" ] && echo "     required not passed: $(echo "$unset_req")"
    [ -n "$missing" ]   && echo "     secrets not passed:  $(echo "$missing")"
  else
    echo "ok   $caller  ($(printf '%s\n' "$used" | grep -c .) inputs, $(printf '%s\n' "$passed" | grep -c .) secrets)"
  fi
done
exit $fail
