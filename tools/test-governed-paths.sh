#!/usr/bin/env bash
#
# Runs restore-agent-governed-paths.sh against scratch repositories, one per case it has to tell
# apart. Its notes and markers are read by other steps - the merge gate holds on the merged marker,
# the author bots caveat their reply on the discarded one - so a change that moved either would
# otherwise surface only in a live run, on a real PR.
#
# Each case builds a base commit (origin/main) and a PR commit (HEAD), runs the script's own
# --rewrite as claude-code-action's rewrite, applies what the agent did, and then runs the undo.
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/.github/actions/governed-paths/restore-agent-governed-paths.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
merged_marker=$(bash "$script" --merged-marker)
discarded_marker=$(bash "$script" --discarded-marker)
export GOVERNED_BASE_REF=origin/main

fail() { echo "FAIL  $case: $*"; failures=1; }
ok() { echo "ok    $case"; }

# A repository whose origin/main holds the base's governed files and whose HEAD is the PR.
# $1 is run in the base commit, $2 on top of it for the PR.
repo() {
  local dir="$work/$case"
  mkdir -p "$dir" && cd "$dir"
  git init -q -b pr . && git config user.email t@example.com && git config user.name t
  echo readme > README && eval "$1" && git add -A && git commit -qm base
  git update-ref refs/remotes/origin/main HEAD
  eval "$2"; git add -A && git commit -qm pr --allow-empty
}

lines() { printf 'line %s\n' 1 2 3 4 5 6 7 8 9; }

# The undo, after claude-code-action's rewrite and the agent's own edit ($1).
undo() {
  bash "$script" --rewrite 2>/dev/null
  eval "$1"
  note=$(bash "$script" HEAD 2>/dev/null)
}

case=restored-quietly
repo 'lines > CLAUDE.md' 'sed -i "s/line 2/pr 2/" CLAUDE.md'
undo ':'
if [ -n "$note" ]; then fail "the rewrite alone produced a note: $note"
elif ! grep -qx 'pr 2' CLAUDE.md; then fail "the PR's copy was not restored"
else ok; fi

case=merged-edit
repo 'lines > CLAUDE.md' 'sed -i "s/line 2/pr 2/" CLAUDE.md'
undo 'sed -i "s/line 8/agent 8/" CLAUDE.md'
if ! grep -qxF "$merged_marker" <<<"$note"; then fail "no merged marker: $note"
elif grep -qxF "$discarded_marker" <<<"$note"; then fail "a discarded marker on a clean merge"
elif ! grep -qx 'pr 2' CLAUDE.md || ! grep -qx 'agent 8' CLAUDE.md; then fail "the file lost one side"
else ok; fi

case=discarded-edit
repo 'lines > CLAUDE.md' 'sed -i "s/line 2/pr 2/" CLAUDE.md'
undo 'sed -i "s/line 2/agent 2/" CLAUDE.md'
if ! grep -qxF "$discarded_marker" <<<"$note"; then fail "no discarded marker: $note"
elif grep -qxF "$merged_marker" <<<"$note"; then fail "a merged marker on a discard"
elif ! grep -qx 'pr 2' CLAUDE.md || grep -q 'agent 2' CLAUDE.md; then fail "the PR's copy was not kept"
else ok; fi

# #205: a new file under a governed path is a governed change made after `hold` was decided.
case=added-file
repo ':' ':'
undo 'mkdir -p .claude && echo "{}" > .claude/settings.json'
if ! grep -qxF "$merged_marker" <<<"$note"; then fail "no merged marker for an added file: $note"
elif ! grep -q 'this commit adds `.claude/settings.json`' <<<"$note"; then fail "the note does not name the file: $note"
elif [ ! -f .claude/settings.json ]; then fail "the added file was deleted"
else ok; fi

case=added-and-merged
repo 'lines > CLAUDE.md' 'sed -i "s/line 2/pr 2/" CLAUDE.md'
undo 'sed -i "s/line 8/agent 8/" CLAUDE.md; mkdir -p .claude && echo "{}" > .claude/settings.json'
if [ "$(grep -cxF "$merged_marker" <<<"$note")" != 1 ]; then fail "expected exactly one merged marker: $note"
else ok; fi

case=deleted-by-the-pr
repo 'lines > CLAUDE.md' 'rm CLAUDE.md'
undo ':'
if [ -e CLAUDE.md ]; then fail "the file the PR deleted came back"
elif [ -n "$note" ]; then fail "a deletion put back produced a note: $note"
else ok; fi

case=rewrite-leaves-the-index
repo 'lines > CLAUDE.md' 'sed -i "s/line 2/pr 2/" CLAUDE.md'
bash "$script" --rewrite 2>/dev/null
if ! git diff --quiet origin/main -- CLAUDE.md; then fail "the working tree is not the base's copy"
elif ! git diff --cached --quiet; then fail "the rewrite staged something"
else ok; fi

# #237: the agent's prompt names the paths the rewrite is about to replace, and only those.
case='prompt-note-names-changes'
repo 'lines > CLAUDE.md; lines > .mcp.json' 'sed -i "s/line 2/pr 2/" CLAUDE.md; mkdir -p .claude && echo "{}" > .claude/settings.json; rm .mcp.json'
prompt=$(bash "$script" --prompt-note)
if ! grep -qF '`CLAUDE.md`' <<<"$prompt"; then fail "a changed path is not named: $prompt"
elif ! grep -qF '`.claude`' <<<"$prompt"; then fail "a path the PR added is not named: $prompt"
elif ! grep -qF '`.mcp.json`' <<<"$prompt"; then fail "a path the PR deleted is not named: $prompt"
elif grep -qF '`.husky`' <<<"$prompt"; then fail "a path neither side has is named: $prompt"
elif ! grep -qF 'origin/main' <<<"$prompt"; then fail "the note does not name the base: $prompt"
else ok; fi

case='prompt-note-quiet'
repo 'lines > CLAUDE.md' 'echo pr > README'
prompt=$(bash "$script" --prompt-note)
if [ -n "$prompt" ]; then fail "a PR that changes no governed path got a note: $prompt"
else ok; fi

# #246: a stacked PR, whose base is another PR's branch. origin/main holds the default branch's
# copy, origin/stack the lower PR's change to it, and HEAD this PR's change on top.
stacked() {
  repo 'lines > CLAUDE.md' 'sed -i "s/line 2/stack 2/" CLAUDE.md'
  git update-ref refs/remotes/origin/stack HEAD
  sed -i "s/line 8/pr 8/" CLAUDE.md && git commit -qam pr
}

# Neither side's change may be lost: the lower PR's line and this PR's line both survive.
both_sides() { grep -qx 'stack 2' CLAUDE.md && grep -qx 'pr 8' CLAUDE.md; }

case=stacked-rewrite-from-base
stacked
note=$(GOVERNED_BASE_REF=origin/stack bash -c '
  bash "$1" --rewrite 2>/dev/null && bash "$1" HEAD 2>/dev/null' _ "$script")
if [ -n "$note" ]; then fail "the rewrite alone produced a note: $note"
elif ! git diff --quiet HEAD -- CLAUDE.md; then fail "the PR's copy was not restored: $(cat CLAUDE.md)"
else ok; fi

# The action falls back to the default branch when it is not told the base. Read against the
# stack alone, that copy is an edit, and merging it would put main's lines back over the stack's.
case=stacked-rewrite-from-default
stacked
GOVERNED_BASE_REF=origin/main bash "$script" --rewrite 2>/dev/null
note=$(GOVERNED_BASE_REF=origin/stack GOVERNED_DEFAULT_REF=origin/main bash "$script" HEAD 2>/dev/null)
if [ -n "$note" ]; then fail "the default branch's copy was read as an edit: $note"
elif ! git diff --quiet HEAD -- CLAUDE.md; then fail "the PR's copy was not restored: $(cat CLAUDE.md)"
else ok; fi

case=stacked-merged-edit
stacked
note=$(GOVERNED_BASE_REF=origin/stack GOVERNED_DEFAULT_REF=origin/main bash -c '
  bash "$1" --rewrite 2>/dev/null && sed -i "s/line 5/agent 5/" CLAUDE.md && bash "$1" HEAD 2>/dev/null' _ "$script")
if ! grep -qxF "$merged_marker" <<<"$note"; then fail "no merged marker: $note"
elif ! both_sides || ! grep -qx 'agent 5' CLAUDE.md; then fail "a side was lost: $(cat CLAUDE.md)"
else ok; fi

case=extra-paths
cd "$work"
if ! GOVERNED_EXTRA_PATHS=$'  docs/agents  \n' bash "$script" --list | grep -qx 'docs/agents'; then
  fail "an extra path is not listed, trimmed"
elif ! bash "$script" --list | grep -qx 'CLAUDE.md'; then fail "CLAUDE.md is not governed"
else ok; fi

exit $failures
