#!/usr/bin/env bash
#
# Runs check-gate-lists.sh against fixture trees. CI runs the check on the real repository, where
# every list is complete, so without these the failures it exists to report would never be
# exercised. Each case names the line the check must print, so a fixture that fails for some other
# reason does not pass.
set -euo pipefail

check="$(cd "$(dirname "$0")" && pwd)/check-gate-lists.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

names='tools/check-one.sh tools/test-check-one.sh tools/test-two.sh'

# A tree in which every list names every script ci.yml runs; $1 is the directory.
tree() {
  local dir=$1
  mkdir -p "$dir/.github/workflows" "$dir/.ai/agents"
  {
    printf 'jobs:\n  lint:\n    steps:\n'
    printf '      # tools/never-run.sh is only mentioned here, and tools/test-comment.sh\n'
    printf '      - run: echo not a gate\n'
    for n in $names; do printf '      - name: %s\n        run: ./%s\n' "$n" "$n"; done
  } > "$dir/.github/workflows/ci.yml"
  printf '# Rules\n\nGates: %s\n' "$names" > "$dir/CLAUDE.md"
  printf '## 1. What CI decided\n\n%s\n' "$names" > "$dir/.ai/agents/pr-review-guide.md"
  printf '## Steps\n\n%s\n\n## The table\n\n%s\n\n## Verifying\n\n%s\n\n## Never\n\nx\n' \
    "$names" "$names" "$names" > "$dir/.ai/agents/ci-triage.md"
  printf '## Checked\n\n%s\n' "$names" > "$dir/.github/pull_request_template.md"
  printf 'jobs:\n  r:\n    with:\n      gated_checks: >-\n        %s\n    secrets:\n      A: b\n' \
    "$names" > "$dir/.github/workflows/self-review.yml"
  printf 'jobs:\n  c:\n    with:\n      verify_guidance: >\n        %s\n      gate_rules: x\n' \
    "$names" > "$dir/.github/workflows/self-comments.yml"
}

# Passes when the check exits as expected and, for a failure, prints the expected text.
expect() {
  local name=$1 want=$2 text=${3:-} status=0
  CHECK_ROOT="$work/$name" "$check" > "$work/$name.out" 2>&1 || status=$?
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

# Copies the complete tree and removes one script's name from one file.
without() {
  local name=$1 file=$2 script=$3
  tree "$work/$name"
  sed -i "s#$script##g" "$work/$name/$file"
}

tree "$work/complete"
expect complete pass "3 scripts"

without claude CLAUDE.md tools/check-one.sh
expect claude fail "CLAUDE.md does not name tools/check-one.sh"

without guide .ai/agents/pr-review-guide.md tools/test-two.sh
expect guide fail ".ai/agents/pr-review-guide.md does not name tools/test-two.sh"

without template .github/pull_request_template.md tools/test-two.sh
expect template fail ".github/pull_request_template.md does not name tools/test-two.sh"

without review .github/workflows/self-review.yml tools/test-two.sh
expect review fail "gated_checks in .github/workflows/self-review.yml does not name tools/test-two.sh"

without comments .github/workflows/self-comments.yml tools/test-two.sh
expect comments fail "verify_guidance in .github/workflows/self-comments.yml does not name tools/test-two.sh"

# One part of ci-triage naming a script does not cover the other two.
tree "$work/triage-steps"
printf '## Steps\n\nx\n\n## The table\n\n%s\n\n## Verifying\n\n%s\n\n## Never\n\nx\n' \
  "$names" "$names" > "$work/triage-steps/.ai/agents/ci-triage.md"
expect triage-steps fail "ci-triage.md, the step table does not name tools/check-one.sh"

tree "$work/triage-table"
printf '## Steps\n\n%s\n\n## The table\n\nx\n\n## Verifying\n\n%s\n\n## Never\n\nx\n' \
  "$names" "$names" > "$work/triage-table/.ai/agents/ci-triage.md"
expect triage-table fail "ci-triage.md, the failure table does not name tools/test-two.sh"

tree "$work/triage-verifying"
printf '## Steps\n\n%s\n\n## The table\n\n%s\n\n## Verifying\n\nx\n\n## Never\n\n%s\n' \
  "$names" "$names" "$names" > "$work/triage-verifying/.ai/agents/ci-triage.md"
expect triage-verifying fail "ci-triage.md, the Verifying block does not name tools/test-two.sh"

# test-check-one.sh in a list does not stand in for check-one.sh.
tree "$work/prefix"
sed -i 's#tools/check-one.sh##' "$work/prefix/CLAUDE.md"
expect prefix fail "CLAUDE.md does not name tools/check-one.sh"

# A list naming a script ci.yml does not run is not a failure.
tree "$work/extra"
printf '\ntools/test-unused.sh\n' >> "$work/extra/CLAUDE.md"
expect extra pass

# A ci.yml that runs no gate means the parse is wrong, which must not read as success.
tree "$work/empty"
printf 'jobs:\n  lint:\n    steps:\n      - run: echo hi\n' > "$work/empty/.github/workflows/ci.yml"
expect empty fail "the parse is wrong"

exit "$failures"
