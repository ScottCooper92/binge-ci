#!/usr/bin/env bash
#
# Runs check-internal-refs.sh against fixture trees, one per case its first rule has to tell apart.
# The check reads the real repository in CI, where every case it passes is the one that holds, so
# without these the case it exists to fail would never be exercised.
set -euo pipefail

check="$(cd "$(dirname "$0")" && pwd)/check-internal-refs.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

# A tree with one composite action and one workflow, written from the arguments.
fixture() {
  local name=$1 workflow=$2 action=$3
  mkdir -p "$work/$name/.github/workflows" "$work/$name/.github/actions/sample"
  printf '%s\n' "$workflow" > "$work/$name/.github/workflows/sample.yml"
  printf '%s\n' "$action" > "$work/$name/.github/actions/sample/action.yml"
}

# Passes when the check's exit status is the one expected.
expect() {
  local name=$1 want=$2 status=0
  CHECK_ROOT="$work/$name" "$check" > "$work/$name.out" 2>&1 || status=$?
  local got=pass
  [ "$status" -eq 0 ] || got=fail
  if [ "$got" = "$want" ]; then
    echo "ok    $name: ${want}, as expected"
  else
    echo "FAIL  $name: expected it to $want, exit $status:"
    sed 's/^/      /' "$work/$name.out"
    failures=1
  fi
}

plain_action='runs:
  using: composite
  steps:
    - run: "true"
      shell: bash'

fixture reusable-local "on:
  workflow_call:
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/sample" "$plain_action"
expect reusable-local fail

fixture reusable-inline-local "on: [workflow_call, push]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/sample" "$plain_action"
expect reusable-inline-local fail

fixture reusable-list-local "on:
  - workflow_call
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/sample" "$plain_action"
expect reusable-list-local fail

fixture reusable-quoted-local "on:
  \"workflow_call\":
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/sample" "$plain_action"
expect reusable-quoted-local fail

fixture repo-only-local "on:
  pull_request:
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ./.github/actions/sample" "$plain_action"
expect repo-only-local pass

fixture action-local "on:
  pull_request:
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: \"true\"" "runs:
  using: composite
  steps:
    - uses: ./.github/actions/other"
expect action-local fail

exit $failures
