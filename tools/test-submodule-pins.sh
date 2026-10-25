#!/usr/bin/env bash
#
# Runs submodule-pins.yml's check step against scratch repositories, one per case it has to tell
# apart. The step is inline in a reusable workflow, so a change to it would otherwise surface only in
# a consumer's live run, on a real PR.
#
# The upstream submodule has main A-B-C, a branch D off C and a branch E off B. The base commit pins
# B; each case's PR commit pins another one. `gh` is stubbed to report the PR's labels.
set -euo pipefail

workflow="$(cd "$(dirname "$0")/.." && pwd)/.github/workflows/submodule-pins.yml"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

# The step's script: everything under its `run: |`, the last block in the file.
awk 'f { sub(/^          /, ""); print } /^        run: \|/ { f = 1 }' "$workflow" > "$work/step.sh"

# Scratch repositories reached over file://. The step fetches pins by SHA, which a GitHub remote
# allows and a local one does not unless told to.
export GIT_CONFIG_COUNT=3
export GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
export GIT_CONFIG_KEY_1=uploadpack.allowAnySHA1InWant GIT_CONFIG_VALUE_1=true
export GIT_CONFIG_KEY_2=init.defaultBranch GIT_CONFIG_VALUE_2=main
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

git init -q "$work/sub"
(
  cd "$work/sub"
  for c in A B C; do git commit -q --allow-empty -m "$c" && git tag "$c"; done
  git checkout -q -b d C && git commit -q --allow-empty -m D && git tag D
  git checkout -q -b e B && git commit -q --allow-empty -m E && git tag E
  git checkout -q main
)

git init -q "$work/super"
(
  cd "$work/super"
  git submodule --quiet add "$work/sub" sub
  git -C sub checkout -q B && git add -A && git commit -q -m base && git tag base
  for pin in A B C D E; do
    git -C sub checkout -q "$pin" && git add sub && git commit -q --allow-empty -m "pin $pin"
    git tag "pin-$pin" && git reset -q --hard base && git submodule --quiet update
  done
)

mkdir "$work/bin"
printf '#!/bin/sh\necho "{\\"labels\\":[$LABELS]}"\n' > "$work/bin/gh"
chmod +x "$work/bin/gh"

# $1 the case, $2 the commit to check out as the PR, $3 its labels as JSON objects, $4 pass|fail.
check() {
  local case=$1 dir="$work/checkout-$1" out rc
  git clone -q "$work/super" "$dir"
  git -C "$dir" checkout -q "$2"
  git -C "$dir" submodule --quiet update --init
  set +e
  out=$(cd "$dir" && PATH="$work/bin:$PATH" LABELS=$3 PR_NUMBER=1 HOLD_LABEL=hold \
    BASE_SHA=$(git rev-parse base) bash "$work/step.sh" 2>&1)
  rc=$?
  set -e
  if { [ "$4" = pass ] && [ "$rc" -eq 0 ]; } || { [ "$4" = fail ] && [ "$rc" -ne 0 ]; }; then
    echo "ok    $case"
  else
    echo "FAIL  $case: expected $4, exit $rc"
    sed 's/^/      /' <<<"$out"
    failures=1
  fi
}

held='{"name":"hold"}'
check unchanged base '' pass
check same-pin pin-B '' pass
check forward-merged pin-C '' pass
check rolled-back pin-A '' fail
check rolled-back-held pin-A "$held" pass
check forward-unmerged pin-D '' fail
check forward-unmerged-held pin-D "$held" pass
check unmerged-off-the-base pin-E '' fail
check unmerged-off-the-base-held pin-E "$held" pass

exit "$failures"
