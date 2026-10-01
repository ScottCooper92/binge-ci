#!/usr/bin/env bash
#
# Fails when a composite action reads `${{ env.NAME }}` that nothing in the same action sets.
#
# Inside a composite action the `env` expression context holds only what a caller, an `env:` key
# or an earlier step's write to `$GITHUB_ENV` put there. It does not hold the runner image's own
# environment, so `${{ env.ANDROID_SDK_ROOT }}` expands to an empty string on a runner that
# exports it in the shell, and the cache path built from it silently points at nothing.
# actionlint cannot see it: it has no schema for an action.yml at all.
#
# A reference is accepted when an `env:` key of that name appears in the same action file, or a
# `run:` value there that mentions `$GITHUB_ENV` echoes or printfs `NAME=` or `NAME<<` (the
# heredoc form), quoted or not, in a one-line value or any block scalar. That errs towards
# accepting: it does not check the write comes before the read, and an `env:` key counts for
# every step although it only reaches its own.
# One that has to come from the caller is the exception: read it from a step's `env:` instead,
# or take it as an input.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

python3 - "$@" <<'PY'
import glob, re, sys

WRITE = re.compile(r'(?:echo|printf)\s+(?:-[A-Za-z]+\s+)*["\']?([A-Za-z_][A-Za-z0-9_]*)(?:=|<<)')
BLOCK = re.compile(r'[|>](?:[0-9][+-]?|[+-][0-9]?)?')


def run_values(code):
    """Yield the text of every `run:` value: a one-line value or any block scalar (|, |-, >, ...)."""
    lines = code.splitlines()
    i = 0
    while i < len(lines):
        match = re.match(r'^(\s*)(-\s+)?run:\s*(.*)$', lines[i])
        i += 1
        if not match:
            continue
        rest = match.group(3).strip()
        if not BLOCK.fullmatch(rest):
            yield rest
            continue
        key_col = len(match.group(1)) + (len(match.group(2)) if match.group(2) else 0)
        body = []
        while i < len(lines) and (not lines[i].strip() or len(lines[i]) - len(lines[i].lstrip()) > key_col):
            body.append(lines[i])
            i += 1
        yield "\n".join(body)


bad = 0
refs = 0
actions = sorted(glob.glob('.github/actions/*/action.yml'))
for path in actions:
    text = open(path).read()
    code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith('#'))
    defined = set()
    for block in re.finditer(r'^(\s*)env:\s*\n((?:\1\s+.*\n|[ \t]*\n)+)', code + "\n", re.MULTILINE):
        defined.update(re.findall(r'^\s*([A-Za-z_][A-Za-z0-9_]*):', block.group(2), re.MULTILINE))
    for body in run_values(code):
        if 'GITHUB_ENV' in body:
            defined.update(WRITE.findall(body))
    for name in sorted(set(re.findall(r'\$\{\{\s*env\.([A-Za-z_][A-Za-z0-9_]*)', code))):
        refs += 1
        if name not in defined:
            bad = 1
            print(f"FAIL {path}: ${{{{ env.{name} }}}} is read but nothing in the action sets {name}")

# Zero actions is a failure: after a wrong cwd that is exactly what the glob returns.
if not actions:
    print("FAIL no composite actions found - nothing was checked")
    sys.exit(1)
if not bad:
    print(f"ok   {refs} env reference(s) across {len(actions)} action(s)")
sys.exit(bad)
PY
