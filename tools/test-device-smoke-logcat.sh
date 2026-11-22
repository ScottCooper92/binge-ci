#!/usr/bin/env bash
#
# Holds device-smoke.yml's optional logcat capture. A managed-device run keeps no logcat when the
# instrumentation process crashes, so a crash before any test ran leaves no cause to read. With
# `capture_logcat` the lane records `adb logcat` for the whole run and uploads it. This runs the start and
# stop steps against a stub `adb` and checks the workflow's wiring.
#
# What it holds: the capture appends across restarts of adb, which is what Gradle's adb restart does to the
# stream; it stops at its size cap; the stop step ends the loop and what runs under it; a missing adb warns and
# succeeds and a missing pid is harmless; and with the input off no logcat step runs and the upload paths gain
# nothing.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
workflow="$root/.github/workflows/device-smoke.yml"
work=$(mktemp -d)
trap 'pkill -f "$work" 2> /dev/null || true; rm -rf "${work:?}"' EXIT
failures=0
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
pass() { echo "ok    $1"; }
expect() { # $1=description  $2=shell condition
  if (set -e; eval "$2") > /dev/null 2>&1; then pass "$1"; else fail "$1"; fi
}

python3 -I - "$workflow" "$work" <<'PYX' || exit 1
import re, sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
job = next(iter(wf["jobs"].values()))
steps = job["steps"]
names = [s.get("name") for s in steps]
bad = []
start = [s for s in steps if s.get("id") == "logcat"]
stop = [s for s in steps if s.get("name") == "Stop recording logcat"]
if len(start) != 1 or len(stop) != 1:
    sys.exit("the start and stop steps are not in the workflow exactly once")
start, stop = start[0], stop[0]
open(sys.argv[2] + "/start.sh", "w").write(start["run"])
open(sys.argv[2] + "/stop.sh", "w").write(stop["run"])
inp = wf["on"]["workflow_call"]["inputs"] if "on" in wf else wf[True]["workflow_call"]["inputs"]
c = inp.get("capture_logcat")
if not c or c.get("type") != "boolean" or c.get("default") is not False:
    bad.append("capture_logcat is not a boolean that defaults to false")
if "inputs.capture_logcat" not in str(start.get("if")) or "inputs.capture_logcat" not in str(stop.get("if")):
    bad.append("the start or stop step runs with the input off")
if "always()" not in str(stop.get("if")):
    bad.append("the stop step does not run after a failure")
if names.index("Start recording logcat") > names.index("Create the managed-device snapshot"):
    bad.append("the capture starts after the device is created")
if names.index("Stop recording logcat") > names.index("Upload test results"):
    bad.append("the capture is stopped after the upload")
up = [s for s in steps if s.get("id") == "upload"][0]
path = up["with"]["path"]
if "inputs.artifact_paths" not in path or "inputs.capture_logcat && 'device-smoke-logcat.txt' || ''" not in path:
    bad.append("the upload does not add the logcat file only when the input is on")
if "retention-days" not in up["with"] or "inputs.retention_days" not in str(up["with"]["retention-days"]):
    bad.append("the retention is not the short retention_days input")
if "continue-on-error" in start or "continue-on-error" in stop:
    pass
for b in bad:
    print("FAIL  " + b)
if not bad:
    print("ok    the input is off by default, the capture starts before the device, stops before the upload and is uploaded only when on")
sys.exit(1 if bad else 0)
PYX

# A stub adb: each run prints a line and ends, as the logcat stream does when Gradle restarts the adb server.
mkdir -p "$work/bin" "$work/tmp"
cat > "$work/bin/adb" <<'STUB'
#!/usr/bin/env bash
echo "adb $* run $(date +%s%N)"
sleep "${STUB_SLEEP:-0.2}"
STUB
chmod +x "$work/bin/adb"

# A process that has ended but not been reaped is a zombie, which `kill -0` still finds.
alive() { local st; st=$(ps -o stat= -p "$1" 2> /dev/null || true); [ -n "$st" ] && [[ $st != Z* ]]; }
export -f alive 2> /dev/null || true
start() { # extra env assignments
  : > "$work/gh-out"
  env -i PATH="$work/bin:$PATH" RUNNER_TEMP="$work/tmp" GITHUB_OUTPUT="$work/gh-out" LOGCAT_FILE="$work/logcat.txt" \
    LOGCAT_MAX_BYTES=1000000 "$@" bash "$work/start.sh" > "$work/start.out" 2>&1
}
stop() { env -i PATH="$PATH" LOGCAT_PID="$1" LOGCAT_FILE="$work/logcat.txt" bash "$work/stop.sh" > "$work/stop.out" 2>&1; }

start STUB_SLEEP=0.2 || fail "the start step failed"
pid=$(sed -n 's/^pid=//p' "$work/gh-out"); export pid
expect "the start step records a pid" '[[ $pid =~ ^[0-9]+$ ]]'
sleep 4
expect "the capture ran adb with wait-for-device and the full buffer set" 'grep -q "adb wait-for-device logcat -v threadtime -b all" "$work/logcat.txt"'
expect "and ran it again after it ended, into the same file" '[ "$(grep -c "^adb " "$work/logcat.txt")" -ge 2 ]'
stop "$pid" || fail "the stop step failed"
sleep 1
expect "the stop step ends the loop" '! alive "$pid"'
expect "and says how much it recorded" 'grep -q "Recorded [0-9]* bytes of logcat" "$work/stop.out"'
size=$(stat -c %s "$work/logcat.txt"); export size; sleep 2
expect "no more is written after the stop" '[ "$(stat -c %s "$work/logcat.txt")" = "$size" ]'

# The stop step ends what runs under the loop too, with adb in the middle of a long run.
start STUB_SLEEP=6 || fail "the start step failed for the group check"
pid3=$(sed -n 's/^pid=//p' "$work/gh-out"); export pid3
sleep 1.5
expect "adb is running when the stop step starts" 'pgrep -f "$work/bin/adb" > /dev/null'
stop "$pid3" || fail "the stop step failed for the group check"
sleep 0.3
expect "the stop step ends adb under the loop as well, not only the loop" '! pgrep -f "$work/bin/adb" > /dev/null'
expect "and the loop is gone" '! alive "$pid3"'

# The size cap.
start LOGCAT_MAX_BYTES=60 STUB_SLEEP=0 || fail "the start step failed with a cap"
pid2=$(sed -n 's/^pid=//p' "$work/gh-out"); export pid2
sleep 5
expect "the loop ends by itself at the size cap" '! alive "$pid2"'
expect "and the file stopped near the cap" '[ "$(stat -c %s "$work/logcat.txt")" -lt 400 ]'
stop "$pid2" || true

# No adb, no pid, and a bad pid.
mkdir -p "$work/empty"
: > "$work/gh-out"
env -i PATH="/usr/bin:/bin" RUNNER_TEMP="$work/tmp" GITHUB_OUTPUT="$work/gh-out" LOGCAT_FILE="$work/none.txt" LOGCAT_MAX_BYTES=100 ANDROID_HOME="$work/empty" bash "$work/start.sh" > "$work/noadb.out" 2>&1 \
  && pass "with no adb the step succeeds" || fail "with no adb the step failed"
expect "and warns that nothing is recorded" 'grep -q "::warning::capture_logcat is on but adb was not found" "$work/noadb.out"'
expect "and records no pid" '! grep -q "^pid=" "$work/gh-out"'
stop "" && pass "an empty pid is harmless" || fail "an empty pid failed the stop step"
stop "not-a-pid; touch $work/injected" && pass "a pid that is not a number is harmless" || fail "a bad pid failed the stop step"
expect "and runs nothing" '[ ! -e "$work/injected" ]'
[ "$failures" -eq 0 ]
