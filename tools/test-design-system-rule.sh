#!/usr/bin/env bash
#
# Holds the review bot's rule for reusing the design system. A caller names the index of its design
# system's components in `design_system_index`; the review then asks whether a PR's new UI duplicates
# what the index offers. This runs the workflow's own step that extracts the governing docs against
# scratch repositories, and checks what the prompt and the merge guard say about the rule.
#
# What it holds: nothing changes while the input is empty; the index and the rule come from the default
# branch and never from the PR; an index that is missing is said so and not a failure; the rule is
# written by the workflow, so a caller's repository cannot hold a copy a PR could edit.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
workflow="$root/.github/workflows/bot-review.yml"
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
failures=0
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
pass() { echo "ok    $1"; }
expect() { # $1=description  $2=shell condition
  if (set -e; eval "$2") > /dev/null 2>&1; then pass "$1"; else fail "$1"; fi
}

# The step's script, read out of the workflow so this tests what runs: from its `run: |` to the next
# step, with the block's indent removed.
awk '/- name: Extract the governing docs/ {on = 1; next}
     on && /^      #/ {exit}
     on && /^        run: \|/ {run = 1; next}
     run {sub(/^          /, ""); print}' "$workflow" > "$work/step.sh"
[ -s "$work/step.sh" ] && grep -q 'RULES_DIR' "$work/step.sh" || { fail "the extract step is not in the workflow"; exit 1; }

git_() { git -c user.email=t@example.test -c user.name=t -c init.defaultBranch=main "$@"; }
origin="$work/origin"
git_ init -q "$origin"
mkdir -p "$origin/.ai/agents" "$origin/docs"
echo "guide" > "$origin/.ai/agents/pr-review-guide.md"
echo "conventions" > "$origin/CLAUDE.md"
echo "BASE INDEX: BingeButton" > "$origin/docs/components.md"
git -C "$origin" add -A && git_ -C "$origin" commit -q -m base
git_ clone -q "$origin" "$work/repo"
# The PR's head rewrites the index to say whatever it likes.
git_ -C "$work/repo" checkout -q -b pr
echo "PR INDEX: nothing is wrapped" > "$work/repo/docs/components.md"
git -C "$work/repo" add -A && git_ -C "$work/repo" commit -q -m "pr edits the index"

run_step() { # $1 = index path (may be empty)
  rm -rf "$work/rules" "$work/out"
  (cd "$work/repo" && RULES_DIR="$work/rules" DEFAULT_BRANCH=main GUIDE_PATH=.ai/agents/pr-review-guide.md \
     CONVENTIONS_PATH=CLAUDE.md DESIGN_SYSTEM_INDEX="$1" GITHUB_OUTPUT="$work/out" bash "$work/step.sh") > "$work/log" 2>&1
}
export work

echo "-- no index named"
run_step ""
expect "  the step still extracts the guide and the conventions" '[ -s "$work/rules/pr-review-guide.md" ] && [ -s "$work/rules/conventions.md" ]'
expect "  no rule and no index copy are written, and no output is set" '
  [ ! -e "$work/rules/design-system-rule.md" ] && [ ! -e "$work/rules/design-system-index.md" ] && ! grep -q design_system_rule "$work/out"'

echo "-- an index is named"
run_step docs/components.md
expect "  the rule is written and its path is the step output" '
  [ -s "$work/rules/design-system-rule.md" ] && grep -q "^design_system_rule=$work/rules/design-system-rule.md\$" "$work/out"'
expect "  the index is the default branch copy, not the one the PR edited" '
  grep -q "BASE INDEX" "$work/rules/design-system-index.md" && ! grep -q "PR INDEX" "$work/rules/design-system-index.md"'
expect "  the rule points at the index copy" 'grep -q "design-system-index.md" "$work/rules/design-system-rule.md"'
rule="$work/rules/design-system-rule.md"
export rule
expect "  the rule is a judgement and not a name match" 'grep -q "judgement, not a name match" "$rule" && grep -q "whatever its name" "$rule"'
expect "  a duplicate with no line in the PR body is a request for changes, naming the file and the component" '
  grep -q "Design system: <component> - <why it did not fit>" "$rule" && grep -q "request_changes" "$rule" && grep -q "name the file, the indexed component" "$rule"'
expect "  a given reason is judged, and a weak one is a question and not a block" 'grep -q "judge the reason" "$rule" && grep -q "is a question, not a block" "$rule"'
expect "  what the build already refuses is not reported again, and the rule says to read nothing from the PR" '
  grep -q "Do not report what the build already refuses" "$rule" && grep -q "Do not read the" "$rule"'
expect "  the rule names no repository" '! grep -qiE "binge|ephyra|seerr|homelab" "$rule"'

echo "-- an index the default branch does not have"
run_step docs/missing.md
expect "  the step succeeds, and the rule says it could not read the index" '
  grep -q "could not be read from the default branch" "$rule" && grep -q "do not apply the rule" "$rule"'

echo "-- an index inside a submodule"
# The design system is usually a submodule, and `git show <rev>:<path>` does not descend into one.
sub="$work/sub"
git_ init -q "$sub"
mkdir -p "$sub/docs"
echo "BASE SUB INDEX" > "$sub/docs/components.md"
git -C "$sub" add -A && git_ -C "$sub" commit -q -m "index"
git_ -C "$work/origin" -c protocol.file.allow=always submodule add -q "$sub" design-system
git_ -C "$work/origin" commit -q -m "add the design system"
git_ -c protocol.file.allow=always clone -q --recurse-submodules "$work/origin" "$work/repo2"
# The PR bumps the pin to a commit whose index says something else.
git_ -C "$work/repo2" checkout -q -b pr
echo "PR SUB INDEX" > "$sub/docs/components.md"
git -C "$sub" add -A && git_ -C "$sub" commit -q -m "pr index"
git_ -C "$work/repo2/design-system" -c protocol.file.allow=always fetch -q origin
git -C "$work/repo2/design-system" checkout -q FETCH_HEAD
git -C "$work/repo2" add -A && git_ -C "$work/repo2" commit -q -m "bump the design system"
rm -rf "$work/rules" "$work/out"
(cd "$work/repo2" && RULES_DIR="$work/rules" DEFAULT_BRANCH=main GUIDE_PATH=.ai/agents/pr-review-guide.md CONVENTIONS_PATH=CLAUDE.md \
   DESIGN_SYSTEM_INDEX=design-system/docs/components.md GITHUB_OUTPUT="$work/out" bash "$work/step.sh") > "$work/log" 2>&1 || true
expect "  the index is read from the pin the default branch records, not the PR's" '
  grep -q "BASE SUB INDEX" "$work/rules/design-system-index.md" && ! grep -q "PR SUB INDEX" "$work/rules/design-system-index.md"'
expect "  and the rule is on" 'grep -q "^design_system_rule=" "$work/out" && ! grep -q "could not be read" "$work/rules/design-system-rule.md"'

# The governed list the merge guard builds, read out of the workflow between its markers.
awk '/# bound:index-governed-begin/ {on = 1; next} /# bound:index-governed-end/ {exit} on {sub(/^ */, ""); print}' "$workflow" > "$work/governed.sh"
[ -s "$work/governed.sh" ] || { fail "the governed-index block is not in the workflow"; exit 1; }
governed_for() { # $1 = index path
  (cd "$work/repo2" && DEFAULT_BRANCH=main DESIGN_SYSTEM_INDEX="$1" bash -c 'governed_list=""; . "$0"; printf "%s\n" "$governed_list"' "$work/governed.sh")
}
expect "  the submodule's own path is governed, since that is what a bump changes" 'governed_for design-system/docs/components.md | grep -qx "design-system"'
expect "  the index path is governed too" 'governed_for design-system/docs/components.md | grep -qx "design-system/docs/components.md"'
expect "  an index tracked in the repository itself adds only its own path" '[ "$(governed_for docs/components.md | grep -c .)" -eq 1 ]'
expect "  no index adds nothing" '[ -z "$(governed_for "" | grep .)" ]'
export -f governed_for 2> /dev/null || true

echo "-- the prompt and the merge guard"
review=$(awk '/prompt: \|/ {on = 1} on' "$workflow")
export review workflow
expect "  the prompt names the rule only when the step wrote one" '
  grep -q "steps.docs.outputs.design_system_rule != ..  *&& format(" <<<"$review" || grep -qE "steps\.docs\.outputs\.design_system_rule != .. && format\(" <<<"$review"'
expect "  and says the rule is not a file the PR can change" 'grep -q "not of any file the PR can change" <<<"$review"'
expect "  the rule text is not in the prompt, so an empty input leaves the prompt as it was" '! grep -q "judgement, not a name match" <<<"$review"'
expect "  the input defaults to empty" 'awk "/^      design_system_index:/ {on = 1} on && /default:/ {print; exit}" "$workflow" | grep -q "default: '"''"'"'
expect "  an index a PR changes is refused for an unbuilt merge, like the guide" '
  grep -q "governed_list+=.*DESIGN_SYSTEM_INDEX" "$workflow"'

[ "$failures" -eq 0 ] || { echo "$failures failure(s)"; exit 1; }
echo "all passed"
