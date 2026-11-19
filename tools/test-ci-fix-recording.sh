#!/usr/bin/env bash
#
# Holds author-ci-fix.yml's stand-down for a recording in progress. The conflict bot pushes the default
# branch's frames on purpose and dispatches `record-screenshots`; a CI-fix attempt on the red run in between
# would re-record the same classes beside it. The check is read out of the workflow between its markers and
# run against a stubbed `gh`, and the guard step is checked to act on it before it spends an attempt.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
workflow="$root/.github/workflows/author-ci-fix.yml"
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
failures=0
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
pass() { echo "ok    $1"; }

awk '/# bound:recording-begin/ {on = 1; next} /# bound:recording-end/ {exit} on {sub(/^          /, ""); print}' "$workflow" > "$work/fn.sh"
if [ "$(grep -c 'bound:recording-begin' "$workflow")" -ne 1 ] || ! grep -q '^recording_in_progress()' "$work/fn.sh"; then
  fail "recording_in_progress is not in the workflow exactly once"
  exit 1
fi
# shellcheck source=/dev/null
. "$work/fn.sh"

mkdir "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
echo "token=$GH_TOKEN" >> "$GH_LOG"
case "$STUB_MODE" in
  fail) exit 1 ;;
  *) # the workflow's own --jq expression, applied to a payload of the runs the case names
     while [ $# -gt 0 ]; do [ "$1" = --jq ] && expr=$2; shift; done
     jq -r "$expr" <<<"{\"workflow_runs\":$STUB_RUNS}" ;;
esac
STUB
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH" GH_LOG="$work/log" GH_REPO=o/r BRANCH=feature/x ACTIONS_TOKEN=actionstoken GH_TOKEN=authortoken

check() { # $1 description, $2 expected (yes|no), $3 mode, $4 runs
  : > "$GH_LOG"
  if STUB_MODE=$3 STUB_RUNS=$4 recording_in_progress; then got=yes; else got=no; fi
  [ "$got" = "$2" ] && pass "$1" || fail "$1: expected $2, got $got"
}
check "no runs" no ok '[]'
check "only finished runs" no ok '[{"status":"completed"},{"status":"completed"}]'
check "a run in progress" yes ok '[{"status":"in_progress"}]'
check "a run queued behind a finished one" yes ok '[{"status":"completed"},{"status":"queued"}]'
check "a run waiting for approval" yes ok '[{"status":"waiting"}]'
check "an API failure or a missing workflow is not a recording" no fail '[]'
: > "$GH_LOG"; STUB_MODE=ok STUB_RUNS='[]' recording_in_progress || true
grep -q '^api repos/o/r/actions/workflows/record-screenshots.yml/runs?branch=feature/x' "$GH_LOG" \
  && pass "it asks about this branch's runs of record-screenshots.yml" || fail "it asks about the wrong runs: $(head -1 "$GH_LOG")"
grep -q '^token=actionstoken$' "$GH_LOG" && pass "with the workflow's token, not the author app's" || fail "wrong token"

python3 - "$workflow" <<'PY' || failures=$((failures + 1))
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["fix"]["steps"]
g = [s for s in steps if s.get("id") == "guard"][0]
run = g["run"]
i, j = run.index("recording_in_progress; then"), run.index('marker="<!-- ci-fix-attempted')
head = run[i:j]
ok = "skip=true" in head and "exit 0" in head and run.index("recording-end") < i
env = g["env"]
ok = ok and env.get("BRANCH") and "github.token" in env.get("ACTIONS_TOKEN", "")
if not ok:
    print("FAIL  the guard does not stand down, before spending an attempt, on the workflow's token"); sys.exit(1)
print("ok    the guard stands down (skip=true) before the attempt marker is read")
PY
[ "$failures" -eq 0 ]
