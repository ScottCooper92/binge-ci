#!/usr/bin/env bash
#
# shellcheck every `run:` block in .github/actions/*/action.yml.
#
# actionlint parses WORKFLOWS. Pointed at an action.yml it reports "on section is missing"
# and stops, so the shell inside a composite action is the one place in this repository that
# its shellcheck integration does not reach - and both actions here carry real shell.
#
# `${{ ... }}` is replaced with `$PLACEHOLDER` rather than a literal: a bare word turns
# `[ "${{ inputs.x }}" = "true" ]` into a constant comparison and SC2050 fires on a pattern
# that is correct and used throughout.
set -uo pipefail
cd "$(dirname "$0")/.."
command -v shellcheck >/dev/null || { echo "shellcheck is not on PATH."; exit 1; }

python3 - "$@" <<'PY'
import glob, re, subprocess, sys

bad = 0
checked = 0
for path in sorted(glob.glob('.github/actions/*/action.yml')):
    text = open(path).read()
    for match in re.finditer(r'\n(\s+)run: \|\n((?:\1  .*\n|[ \t]*\n)+)', text):
        indent = len(match.group(1)) + 2
        body = "".join(
            line[indent:] if len(line) > indent else line
            for line in match.group(2).splitlines(keepends=True)
        )
        body = re.sub(r'\$\{\{[^}]*\}\}', '$PLACEHOLDER', body)
        checked += 1
        result = subprocess.run(
            ['shellcheck', '--severity=warning', '-s', 'bash', '-'],
            input=body, capture_output=True, text=True,
        )
        if result.returncode:
            bad = 1
            print(f"FAIL {path}\n{result.stdout}")

print(f"ok   {checked} run block(s) across {len(glob.glob('.github/actions/*/action.yml'))} action(s)" if not bad else "")
sys.exit(bad)
PY
