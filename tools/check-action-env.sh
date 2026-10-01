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
# `run:` there that mentions `$GITHUB_ENV` echoes or printfs `NAME=` or `NAME<<` (the heredoc
# form), quoted or not. The `run:` may be one line or any block scalar (`|`, `|-`, `>`). That errs
# towards accepting: it does not check the write comes before the read.
# One that has to come from the caller is the exception: read it from a step's `env:` instead,
# or take it as an input.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

python3 - "$@" <<'PY'
import glob, re, sys

bad = 0
refs = 0
actions = sorted(glob.glob('.github/actions/*/action.yml'))
for path in actions:
    text = open(path).read()
    code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith('#'))
    defined = set()
    for block in re.finditer(r'^(\s*)env:\s*\n((?:\1\s+.*\n|[ \t]*\n)+)', code + "\n", re.MULTILINE):
        defined.update(re.findall(r'^\s*([A-Za-z_][A-Za-z0-9_]*):', block.group(2), re.MULTILINE))
    lines = code.splitlines()
    for i, line in enumerate(lines):
        m = re.match(r'^(\s*)(?:-\s+)?run:\s*(.*)$', line)
        if not m:
            continue
        body = m.group(2)
        if re.fullmatch(r'[|>][+-]?[0-9]*', body):
            body = ""
            for nxt in lines[i + 1:]:
                if nxt.strip() and len(nxt) - len(nxt.lstrip()) <= len(m.group(1)):
                    break
                body += nxt + "\n"
        if 'GITHUB_ENV' in body:
            defined.update(re.findall(
                r'(?:echo|printf)\s+(?:-[A-Za-z]+\s+)?["\']?([A-Za-z_][A-Za-z0-9_]*)(?:=|<<)',
                body,
            ))
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
