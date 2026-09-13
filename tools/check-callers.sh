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
#
# It also checks PERMISSIONS, which is the one that cost a debugging session. A reusable
# workflow cannot be granted more than its caller holds, and a caller with no `permissions:`
# block gets the repository default - `contents: read`, with no `actions`. A called workflow
# declaring `actions: read` then dies as `startup_failure`: no log, no annotation, no job, and
# nothing on the PR. Nothing else in the toolchain sees it. actionlint cannot, because the
# reference is remote; the called workflow's own CI cannot, because it is not the caller.
#
# Permissions are compared as `name: level` pairs, not names: `actions: write` in the workflow
# is not met by `actions: read` in the caller, and `contents: write` is not met by the default.
# `write` satisfies `read`. Input TYPES are checked too - a caller passing `'50'` to a
# `type: number` input, or `'false'` to a boolean, is the same startup_failure with no log.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
shopt -s nullglob

keys() { # $1=file  $2=start regex  $3=stop regex  $4=key indent  $5=key charclass
  awk -v start="$2" -v stop="$3" -v ind="$4" -v cc="$5" '
    $0 ~ start {f=1; next}
    f && $0 ~ stop {f=0}
    f && $0 ~ "^" ind cc "+:" { line=$0; sub(/:.*/,"",line); gsub(/ /,"",line); print line }
  ' "$1" | sort -u
}

# The top-level permissions block as `name:level` lines.
perm_pairs() {
  awk '
    /^permissions:/ {f=1; next}
    f && /^[a-z]/ {f=0}
    f && /^  [a-z-]+: *[a-z]+/ { line=$0; sub(/^ +/,"",line); gsub(/ /,"",line); print line }
  ' "$1" | sort -u
}

# Each declared input's `type`, as `name:type` lines.
input_types() {
  awk '
    /^    inputs:/ {f=1; next}
    /^    secrets:/ {f=0}
    f && /^      [a-z_]+:/ { name=$0; sub(/:.*/,"",name); gsub(/ /,"",name) }
    f && /^        type: */ { t=$0; sub(/.*type: */,"",t); gsub(/ /,"",t); if (name != "") print name ":" t }
  ' "$1"
}

# The literal a caller passes for one input, or nothing when it is absent or block-scalar.
with_value() { # $1=caller  $2=input
  awk -v k="$2" '
    /^    with:/ {f=1; next}
    f && /^    [a-z]/ {f=0}
    f && index($0, "      " k ":") == 1 { v=$0; sub("^      " k ": *", "", v); print v; exit }
  ' "$1"
}

fail=0
callers=(callers/*/*.yml)
if [ ${#callers[@]} -eq 0 ]; then
  echo "FAIL no callers found under callers/*/ - nothing was checked."
  exit 1
fi

for caller in "${callers[@]}"; do
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

  # Permissions the called workflow declares, against what the caller grants itself. A
  # caller with no block holds the repository default, which is `contents: read` and nothing
  # else, so that is the one pair a caller need not restate.
  needs_perms=$(perm_pairs "$reusable")
  has_perms=$(perm_pairs "$caller")
  missing_perms=""
  while IFS=: read -r name level; do
    [ -n "$name" ] || continue
    got=$(printf '%s\n' "$has_perms" | awk -F: -v n="$name" '$1 == n { print $2 }')
    [ -z "$got" ] && [ "$name" = contents ] && got="read"
    case "$got" in
      "$level"|write) ;;
      *) missing_perms+="$name: $level " ;;
    esac
  done <<<"$needs_perms"

  # A quoted scalar reaching a `number` or `boolean` input is a string to GitHub, and it
  # refuses the call at startup with no log. `${{ }}` and bare literals pass.
  bad_types=""
  while IFS=: read -r name type; do
    [ -n "$name" ] || continue
    case "$type" in number|boolean) ;; *) continue ;; esac
    value=$(with_value "$caller" "$name")
    case "$value" in
      \'*|\"*) bad_types+="$name ($type, passed quoted) " ;;
    esac
  done <<<"$(input_types "$reusable")"

  bad=$(comm -23 <(printf '%s\n' "$used")     <(printf '%s\n' "$inputs")   | grep -v '^$')
  unset_req=$(comm -23 <(printf '%s\n' "$required") <(printf '%s\n' "$used")     | grep -v '^$')
  missing=$(comm -23 <(printf '%s\n' "$secrets")  <(printf '%s\n' "$passed")   | grep -v '^$')
  if [ -n "$bad" ] || [ -n "$missing" ] || [ -n "$unset_req" ] || [ -n "$missing_perms" ] || [ -n "$bad_types" ]; then
    fail=1; echo "FAIL $caller"
    [ -n "$bad" ]           && echo "     undeclared inputs:   $(echo "$bad")"
    [ -n "$unset_req" ]     && echo "     required not passed: $(echo "$unset_req")"
    [ -n "$missing" ]       && echo "     secrets not passed:  $(echo "$missing")"
    [ -n "$missing_perms" ] && echo "     permissions the caller must declare: ${missing_perms% }"
    [ -n "$bad_types" ]     && echo "     inputs of the wrong type: ${bad_types% }"
  else
    echo "ok   $caller  ($(printf '%s\n' "$used" | grep -c .) inputs, $(printf '%s\n' "$passed" | grep -c .) secrets)"
  fi
done
exit $fail
