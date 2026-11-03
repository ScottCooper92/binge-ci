#!/usr/bin/env bash
#
# Runs check-callers.sh against fixture trees, one per grant shape it has to tell apart. In CI it reads
# the real callers, where the shapes that matter are all valid, so without these the failures it exists
# to report would never be exercised. Each case names the text the check must print on failure.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

# A tree holding the check, a reusable workflow declaring `actions: write`, and one caller whose
# permissions-bearing lines are the argument.
fixture() { # $1=name  $2=top-level lines  $3=the calling job's extra lines  $4=an extra job  $5=the calling job id
  local name=$1 top=$2 jobperms=$3 extra=${4:-} job=${5:-smoke}
  mkdir -p "$work/$name/tools" "$work/$name/.github/workflows" "$work/$name/callers/c"
  cp "$root/tools/check-callers.sh" "$work/$name/tools/"
  cat > "$work/$name/.github/workflows/device-smoke.yml" <<'W'
name: device-smoke
on:
  workflow_call:
    inputs:
      who:
        type: string
        required: false

permissions:
  contents: read
  actions: write

jobs:
  run:
    runs-on: ubuntu-latest
    steps:
      - run: echo
W
  {
    printf 'name: caller\non: push\n'
    [ -z "$top" ] || printf '%s\n' "$top"
    printf '\njobs:\n'
    [ -z "$extra" ] || printf '%s\n' "$extra"
    printf '  %s:\n' "$job"
    [ -z "$jobperms" ] || printf '%s\n' "$jobperms"
    printf '    uses: ScottCooper92/binge-ci/.github/workflows/device-smoke.yml@v1\n'
  } > "$work/$name/callers/c/device-smoke.yml"
}

expect() { # $1=name  $2=pass|fail  $3=text a failure must print
  local name=$1 want=$2 text=${3:-} status=0
  (cd "$work/$name" && ./tools/check-callers.sh) > "$work/$name.out" 2>&1 || status=$?
  local got=pass
  [ "$status" -eq 0 ] || got=fail
  if [ "$got" = "$want" ] && { [ -z "$text" ] || grep -qF -- "$text" "$work/$name.out"; }; then
    echo "ok    $name: ${want}, as expected"
  else
    echo "FAIL  $name: expected it to $want${text:+ with \"$text\"}, exit $status:"
    sed 's/^/      /' "$work/$name.out"
    failures=1
  fi
}

TOP_WRITE=$'permissions:\n  contents: read\n  actions: write'
TOP_READ=$'permissions:\n  contents: read'
JOB_WRITE=$'    permissions:\n      contents: read\n      actions: write'
JOB_READ=$'    permissions:\n      contents: read'
OTHER_JOB=$'  report:\n    permissions:\n      actions: write\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo\n'

fixture top-level-grant "$TOP_WRITE" ""
expect top-level-grant pass

fixture job-level-grant "$TOP_READ" "$JOB_WRITE"
expect job-level-grant pass

fixture job-narrows-top "$TOP_WRITE" "$JOB_READ"
expect job-narrows-top fail "permissions the caller must declare: actions: write"

fixture no-grant "" ""
expect no-grant fail "permissions the caller must declare: actions: write"

fixture job-write-all "$TOP_READ" $'    permissions: write-all'
expect job-write-all pass

fixture job-empty-block "$TOP_WRITE" $'    permissions: {}'
expect job-empty-block fail "permissions the caller must declare: actions: write"

fixture other-job-grant "$TOP_READ" "" "$OTHER_JOB"
expect other-job-grant fail "permissions the caller must declare: actions: write"

fixture other-job-ignored "$TOP_WRITE" "" "$OTHER_JOB"
expect other-job-ignored pass

fixture digit-job-narrows "$TOP_WRITE" "$JOB_READ" "" e2e
expect digit-job-narrows fail "permissions the caller must declare: actions: write"

fixture digit-job-grants "$TOP_READ" "$JOB_WRITE" "" smoke-34
expect digit-job-grants pass

fixture flow-job-grants "$TOP_READ" $'    permissions: { contents: read, actions: write }'
expect flow-job-grants pass

fixture flow-job-narrows "$TOP_WRITE" $'    permissions: { contents: read }'
expect flow-job-narrows fail "permissions the caller must declare: actions: write"

fixture job-omits-contents "" $'    permissions:\n      actions: write'
expect job-omits-contents fail "permissions the caller must declare: contents: read"

fixture top-omits-contents $'permissions:\n  actions: write' ""
expect top-omits-contents fail "permissions the caller must declare: contents: read"

fixture comment-job-grants "$TOP_READ" $'    permissions:\n      contents: read   # the reusable workflow reads the repo\n      actions: write  # device-smoke cancels runs'
expect comment-job-grants pass

fixture comment-top-grants $'permissions:\n  contents: read # needed\n  actions: write # needed' ""
expect comment-top-grants pass

fixture comment-flow-grants "$TOP_READ" $'    permissions: { contents: read, actions: write }  # both'
expect comment-flow-grants pass

fixture comment-narrows "$TOP_WRITE" $'    permissions:\n      contents: read   # actions is not needed here'
expect comment-narrows fail "permissions the caller must declare: actions: write"

fixture comment-names-scalar "" $'    permissions:  # not write-all, only what is listed\n      contents: read'
expect comment-names-scalar fail "permissions the caller must declare: actions: write"

exit $failures
