#!/usr/bin/env bash
#
# Every gate script ci.yml runs is named by hand in several lists that tell the bots what CI has
# already decided and what to run. Nothing else compares them, so a new test would leave a bot with
# a stale list while CI stays green. This fails when a list does not name a script ci.yml runs.
#
# CHECK_ROOT points it at a fixture tree; the lists in governed paths are read from the tree it
# is given, so on a PR it holds the PR's copy and the next merge brings main in step.
set -euo pipefail

root=${CHECK_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
ci="$root/.github/workflows/ci.yml"

# The scripts a `run:` line invokes, not ones a comment merely mentions.
mapfile -t scripts < <(sed -nE 's#^[[:space:]]+run: \./tools/((test|check)-[a-z0-9-]+\.sh)[[:space:]]*$#\1#p' "$ci" | sort -u)
if [ "${#scripts[@]}" -eq 0 ]; then
  echo "check-gate-lists: ci.yml runs no tools/test-*.sh or tools/check-*.sh, so the parse is wrong" >&2
  exit 1
fi

# The value of a YAML key, up to the next line indented no deeper than the key.
yaml_key() {
  awk -v key="$2" '
    function indent(s) { match(s, /^ */); return RLENGTH }
    found && NF && indent($0) <= depth { exit }
    found { print }
    !found && $0 ~ "^ *" key ":" { found = 1; depth = indent($0) }
  ' "$1"
}

# A Markdown file's text from the line that matches $2 (from the top when $2 is empty) up to, not
# including, the first line after it that matches $3.
md_part() {
  awk -v from="$2" -v to="$3" '
    from == "" { found = 1 }
    found && to != "" && $0 ~ to { exit }
    found { print }
    !found && $0 ~ from { found = 1 }
  ' "$1"
}

lists=(
  "CLAUDE.md|$(cat "$root/CLAUDE.md")"
  ".ai/agents/pr-review-guide.md|$(cat "$root/.ai/agents/pr-review-guide.md")"
  ".ai/agents/ci-triage.md, the step table|$(md_part "$root/.ai/agents/ci-triage.md" "" '^## The table')"
  ".ai/agents/ci-triage.md, the failure table|$(md_part "$root/.ai/agents/ci-triage.md" '^## The table' '^## Verifying')"
  ".ai/agents/ci-triage.md, the Verifying block|$(md_part "$root/.ai/agents/ci-triage.md" '^## Verifying' '^## Never')"
  ".github/pull_request_template.md|$(cat "$root/.github/pull_request_template.md")"
  "gated_checks in .github/workflows/self-review.yml|$(yaml_key "$root/.github/workflows/self-review.yml" gated_checks)"
  "verify_guidance in .github/workflows/self-comments.yml|$(yaml_key "$root/.github/workflows/self-comments.yml" verify_guidance)"
)

status=0
for entry in "${lists[@]}"; do
  label=${entry%%|*}
  text=${entry#*|}
  for script in "${scripts[@]}"; do
    # A name preceded by `-` or a letter is a longer one: test-check-callers.sh holds check-callers.sh.
    pattern="(^|[^a-z-])${script//./\\.}"
    if ! grep -qE -- "$pattern" <<< "$text"; then
      echo "check-gate-lists: $label does not name tools/$script, which ci.yml runs" >&2
      status=1
    fi
  done
done

if [ "$status" -eq 0 ]; then
  echo "check-gate-lists: ${#lists[@]} lists each name all ${#scripts[@]} scripts ci.yml runs"
fi
exit "$status"
