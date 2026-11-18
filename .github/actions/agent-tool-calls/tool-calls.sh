#!/usr/bin/env bash
#
# Prints the agent's last 10 tool calls after its step did not succeed, so a run that died is
# diagnosable from the log. Environment: EXECUTION_FILE, SHOW_FULL_OUTPUT, HOME.
#
# No `-e`: this step reports on a failed run, so each command guards itself and it always exits 0.
set -uo pipefail
f="${EXECUTION_FILE:-}"
if [ -z "$f" ] || [ ! -s "$f" ]; then
  f=$(find "$HOME/.claude/projects" -name '*.jsonl' -type f -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -n 1 | cut -d' ' -f2-) || f=""
fi
if [ -z "$f" ] || [ ! -s "$f" ]; then
  echo "No execution file or transcript to read."
  exit 0
fi
echo "::group::The agent's last 10 tool calls ($(basename "$f"))"
# The commands are what show_full_output: false keeps out of a public log, so without it
# only the tool names are printed. A killed CLI can leave a half-written last line, which
# makes a whole-file read fail; the line-by-line read below skips it.
if [ "${SHOW_FULL_OUTPUT:-false}" = true ]; then
  show='"\(.name): \((.input.command // .input.file_path // .input.pattern // (.input | tostring))
             | tostring | gsub("\\s+"; " ") | .[0:300])"'
else
  show='.name'
fi
docs=$(jq -s '.' "$f" 2>/dev/null) \
  || docs=$(jq -R 'fromjson? // empty' "$f" 2>/dev/null | jq -s '.') || docs='[]'
jq -r "[.[] | (if type == \"array\" then .[] else . end)
         | select(.type == \"assistant\") | .message.content[]?
         | select(.type == \"tool_use\") | $show]
        | .[-10:][]" <<<"$docs" 2>&1 \
  | sed -E 's/(sk-ant-|gh[pousr]_|github_pat_)[A-Za-z0-9_-]+/\1***/g' || true
echo "::endgroup::"
