#!/usr/bin/env bash
#
# Runs check-internal-refs.sh against fixture trees, one per case its first rule has to tell apart,
# and its --resolve mode against a fixture history with tags on a local remote. The check reads the
# real repository in CI, where every case it passes is the one that holds, so without these the
# case it exists to fail would never be exercised.
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

# A reusable workflow pinning this repository's action at an immutable tag: the shape that holds.
fixture reusable-pinned "on:
  workflow_call:
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: ScottCooper92/binge-ci/.github/actions/sample@v1.0.0" "$plain_action"
expect reusable-pinned pass

# The same reference quoted, which the check cannot read. Zero self-references in a tree that ships
# a reusable workflow means the tag checks would pass on nothing.
fixture reusable-unread-ref "on:
  workflow_call:
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: \"ScottCooper92/binge-ci/.github/actions/sample@v1.0.0\"" "$plain_action"
expect reusable-unread-ref fail

# No workflows and no actions at all: nothing was checked, which is not a pass.
mkdir -p "$work/empty"
expect empty fail

# --resolve, which tag-check.yml runs on a push to main or a tag. A history of releases on a local
# remote: each commit pins one tag, and the tags sit where a release, or a mistake, would put them.
#   c1  pins v1.0.0  tagged v1.0.0 (annotated), and v1.0.2 by mistake: a reused tag
#   c2  pins v1.0.1  tagged v1.0.1 (lightweight)
#   c3  pins v1.0.2  the bump to a tag that already exists at c1
#   c4  pins v1.0.3  never tagged
history="$work/history"
mkdir -p "$history/.github/actions/sample"
printf '%s\n' "$plain_action" > "$history/.github/actions/sample/action.yml"
git -C "$history" init -q -b main
git -C "$history" config user.email t@example.com
git -C "$history" config user.name t
commit() {
  mkdir -p "$history/.github/workflows"
  printf '%s\n' "on:
  workflow_call:
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: ScottCooper92/binge-ci/.github/actions/sample@$1" > "$history/.github/workflows/sample.yml"
  git -C "$history" add -A && git -C "$history" commit -qm "pin $1"
  git -C "$history" rev-parse HEAD
}
c1=$(commit v1.0.0); c2=$(commit v1.0.1); c3=$(commit v1.0.2); c4=$(commit v1.0.3)
git -C "$history" tag -a -m v1.0.0 v1.0.0 "$c1"
git -C "$history" tag v1.0.2 "$c1"
git -C "$history" tag v1.0.1 "$c2"
git clone -q --bare "$history" "$work/remote.git"

# Passes when --resolve, on a checkout of $3 with the push named by $4 and $5, exits as expected.
expect_resolve() {
  local name=$1 want=$2 at=$3 ref=$4 sha=$5 status=0
  git clone -q "$work/remote.git" "$work/$name"
  git -C "$work/$name" checkout -q "$at"
  CHECK_ROOT="$work/$name" PUSHED_REF="$ref" PUSHED_SHA="$sha" "$check" --resolve \
    > "$work/$name.out" 2>&1 || status=$?
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

expect_resolve main-at-a-release pass "$c2" main "$c2"
expect_resolve main-tag-not-cut fail "$c4" main "$c4"
expect_resolve main-tag-reused fail "$c3" main "$c3"
expect_resolve tag-is-the-pinned-one pass "$c2" v1.0.1 "$c2"
expect_resolve tag-pins-the-last-release fail "$c1" v1.0.5 "$c1"
expect_resolve alias-on-the-release pass "$c2" v1 "$c2"
expect_resolve alias-on-an-annotated-release pass "$c1" v1 "$c1"
expect_resolve alias-elsewhere fail "$c2" v1 "$c1"

exit $failures
