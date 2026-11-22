#!/usr/bin/env bash
#
# Holds the R8 name check. A -keepnames rule keeps the names that a stack frame, a reflective lookup or a log
# matcher depends on, and a removed or narrowed rule shows only in the release build users run. The check reads the
# release build's R8 mapping and holds a short list of classes to their own names. This runs it against synthetic
# mappings, so no R8 run is needed, and checks where the reusable workflow runs it.
#
# What it holds: names that are kept pass; a renamed class fails and the message names it and what it became; a class
# missing from the mapping fails; a longer name, a nested class and a member line are not the class; a dot is a dot; an
# empty or missing mapping fails; no class named fails, since a check of nothing passes everything; the keep rule hint is
# added to a failure; and the workflow runs the check only when it is given classes, after the release build, from the
# action at the release tag.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/.github/actions/check-r8-names/check-r8-names.sh"
action="$root/.github/actions/check-r8-names/action.yml"
workflow="$root/.github/workflows/android-app-ci.yml"
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
failures=0
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
pass() { echo "ok    $1"; }
expect() { # $1=description  $2=shell condition
  if (set -e; eval "$2") > /dev/null 2>&1; then pass "$1"; else fail "$1"; fi
}

A=com.example.app.service.SampleService
V=com.example.app.ui.SampleViewModel
C=com.example.app.auth.SampleConnection

mapping() { # a mapping with the class lines as given
  printf '# {"id":"com.android.tools.r8.mapping","version":"2.2"}\n'
  for line in "$@"; do printf '%s\n    1:1:void run():10:10 -> a\n' "$line"; done
}
check() { bash "$script" "$@"; }

mapping "$A -> $A:" "$V -> $V:" "$C -> $C:" > "$work/kept.txt"
expect "classes that keep their names pass" 'check "$work/kept.txt" "$A" "$V" "$C"'

mapping "$A -> a.b:" "$V -> $V:" "$C -> $C:" > "$work/renamed.txt"
expect "a renamed class fails" '! check "$work/renamed.txt" "$A" "$V" "$C"'
out="$(check "$work/renamed.txt" "$A" "$V" "$C" 2>&1 || true)"
expect "and the message names the class and what it became" '[[ $out == *"R8 renamed $A to a.b"* ]]'
out="$(R8_KEEP_RULE_HINT='Restore the keepnames rule in the keep rules file.' check "$work/renamed.txt" "$A" 2>&1 || true)"
expect "and the keep rule hint is added to it" '[[ $out == *"to a.b. Restore the keepnames rule in the keep rules file."* ]]'

mapping "$A -> $A:" "$V -> $V:" > "$work/missing.txt"
expect "a class missing from the mapping fails" '! check "$work/missing.txt" "$A" "$V" "$C"'
out="$(check "$work/missing.txt" "$A" "$V" "$C" 2>&1 || true)"
expect "and the message says it is not in the mapping" '[[ $out == *"$C is not in the R8 mapping"* ]]'

# The same name as a prefix of another class, or inside a member line, is not the class.
{
  mapping "$V -> $V:" "$C -> $C:"
  printf '%s$Inner -> a.c:\n    1:1:void m():1:1 -> b\n' "$A"
} > "$work/prefix.txt"
expect "a nested class's name is not the class" '! check "$work/prefix.txt" "$A" "$V" "$C"'
out="$(check "$work/prefix.txt" "$A" "$V" "$C" 2>&1 || true)"
expect "and it is reported as missing, not as renamed" '[[ $out == *"$A is not in the R8 mapping"* ]]'

# A dot in a name is a dot, not any character.
mapping "com.example.appXserviceXSampleService -> x:" "$V -> $V:" "$C -> $C:" > "$work/dot.txt"
expect "a dot in a class name matches literally" '! check "$work/dot.txt" "$A" "$V" "$C"'
out="$(check "$work/dot.txt" "$A" "$V" "$C" 2>&1 || true)"
expect "and the look-alike is reported as missing, not as renamed" '[[ $out == *"$A is not in the R8 mapping"* ]]'

: > "$work/empty.txt"
expect "an empty mapping fails" '! check "$work/empty.txt" "$A"'
expect "a missing mapping fails" '! check "$work/nope.txt" "$A"'
expect "naming no class fails, since a check of nothing passes everything" '! check "$work/kept.txt"'
expect "naming a class that is kept, and none that is not, passes against a renamed mapping" 'check "$work/renamed.txt" "$V"'

# The action passes the list on one class per line, ignoring blanks and stray spaces.
python3 -I - "$action" "$work" <<'PY'
import sys, yaml
act = yaml.safe_load(open(sys.argv[1]))
step = act["runs"]["steps"][0]
assert act["inputs"]["classes"]["required"] is True
assert "mapping" in act["inputs"] and act["inputs"]["mapping"]["default"] == "app/build/outputs/mapping/release/mapping.txt"
for key in ("CLASSES", "MAPPING", "R8_KEEP_RULE_HINT", "ACTION_PATH"):
    assert key in step["env"], key
assert "${{" not in step["run"], "an input reaches the script through env:, never inside run:"
open(sys.argv[2] + "/action-step.sh", "w").write(step["run"])
PY
printf 'ok    the action takes the classes as a required input, and an input reaches the script only through env\n'
cp "$script" "$work/check-r8-names.sh"
list=$'  '"$A"$'\n\n'"$V"$'  \n'"$C"$'\n'
out="$(ACTION_PATH="$work" CLASSES="$list" MAPPING="$work/kept.txt" R8_KEEP_RULE_HINT='' bash "$work/action-step.sh" 2>&1 || true)"
export out
expect "the action reads one class per line, ignoring blanks and spaces" '[[ $out == *"3 class(es) keep their names"* ]]'
expect "and fails the step when a class was renamed" '! ACTION_PATH="$work" CLASSES="$A" MAPPING="$work/renamed.txt" R8_KEEP_RULE_HINT="" bash "$work/action-step.sh"'
expect "and fails the step with an empty list" '! ACTION_PATH="$work" CLASSES="" MAPPING="$work/kept.txt" R8_KEEP_RULE_HINT="" bash "$work/action-step.sh"'

# Where the reusable workflow runs it.
python3 -I - "$workflow" <<'PY' || failures=$((failures + 1))
import sys, re, yaml
wf = yaml.safe_load(open(sys.argv[1]))
call = wf[True]["workflow_call"]["inputs"]
bad = []
if call["r8_kept_classes"]["default"] != "":
    bad.append("the check is not off by default")
if call["r8_mapping"]["default"] != "app/build/outputs/mapping/release/mapping.txt":
    bad.append("the mapping default is not the release build's")
steps = wf["jobs"]["release"]["steps"]
idx = [i for i, s in enumerate(steps) if str(s.get("uses", "")).startswith("ScottCooper92/binge-ci/.github/actions/check-r8-names@")]
build = [i for i, s in enumerate(steps) if s.get("name") == "Assemble the release build"]
if len(idx) != 1 or len(build) != 1:
    bad.append("the release job must run the check exactly once, after one release build")
else:
    s = steps[idx[0]]
    if idx[0] < build[0]:
        bad.append("the check runs before the release build")
    if "inputs.r8_kept_classes != ''" not in s.get("if", ""):
        bad.append("the check runs without a list of classes")
    if not re.search(r"@v\d+\.\d+\.\d+$", s["uses"]):
        bad.append("the check is not pinned to a release tag")
    if s["with"].get("classes") != "${{ inputs.r8_kept_classes }}":
        bad.append("the check is not given the list")
for other in ("tests", "screenshots", "checks"):
    if other in wf["jobs"] and any("check-r8-names" in str(s.get("uses", "")) for s in wf["jobs"][other]["steps"]):
        bad.append(f"the {other} job runs the R8 check, which only the release build can answer")
for b in bad:
    print("FAIL  " + b)
if not bad:
    print("ok    the workflow runs the check only with a list of classes, once, after the release build, from the release tag")
sys.exit(1 if bad else 0)
PY

[ "$failures" -eq 0 ] || { echo "$failures failure(s)"; exit 1; }
echo "all passed"
