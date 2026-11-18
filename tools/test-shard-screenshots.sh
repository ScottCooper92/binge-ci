#!/usr/bin/env bash
#
# Holds the shard-screenshots action: the script that splits a module's screenshot test classes into
# shards, and the step that hands one shard's `--tests` filters to a matrix job. A class no shard names
# is a frame nothing validates and CI stays green, so the cases here are about completeness and about
# failing closed: every class in exactly one shard, the same split each time, an error and not an
# empty run for a stray frame, an orphaned reference or a bad argument.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$root/.github/actions/shard-screenshots"
script="$dir/shard-screenshots.sh"
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
failures=0
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
ok() { echo "ok    $1"; }

shard() { bash "$script" "$@"; }
classes_of() { { grep -v '^--tests$' || true; } | sort; }

tests="$work/tests"
refs="$work/refs"
mkdir -p "$tests" "$refs"
# Class, frames: one heavy class, a few middling, several light, and one with no frames yet.
for spec in Big:40 MidA:12 MidB:11 MidC:10 SmallA:3 SmallB:2 SmallC:2 SmallD:1 New:0; do
  name="${spec%%:*}ScreenshotTest" n="${spec##*:}"
  printf 'package x\nclass %s {\n}\n' "$name" > "$tests/$name.kt"
  mkdir -p "$refs/ui/$name"
  for ((i = 0; i < n; i++)); do : > "$refs/ui/$name/f$i.png"; done
done
expected="$(printf '*.%sScreenshotTest\n' Big MidA MidB MidC SmallA SmallB SmallC SmallD New | sort)"

echo "-- the split"
for n in 1 2 3 4 5 9 12; do
  all="$(for ((i = 0; i < n; i++)); do shard "$n" "$i" "$tests" "$refs" | classes_of; done | sort)"
  if [ "$all" = "$expected" ]; then
    ok "with $n shard(s), every class is in exactly one shard"
  else
    fail "with $n shard(s) the shards together are not every class exactly once"; echo "$all"
  fi
done
a="$(shard 3 1 "$tests" "$refs")"; b="$(shard 3 1 "$tests" "$refs")"
[ "$a" = "$b" ] && ok "the same split every time" || fail "the split changed between two runs"
first="$(shard 3 0 "$tests" "$refs" | classes_of | head -1)"
[ "$first" = "*.BigScreenshotTest" ] && ok "the heaviest class opens shard 0" || fail "the heaviest class should open shard 0, got $first"
n="$(shard 3 0 "$tests" "$refs" | grep -c '^--tests$')"
m="$(shard 3 0 "$tests" "$refs" | grep -c '^\*\.')"
[ "$n" -eq "$m" ] && ok "every class has its own --tests line" || fail "--tests lines ($n) and classes ($m) differ"
for i in 0 1 2; do
  c="$(shard 3 "$i" "$tests" "$refs" | grep -c '^\*\.' || true)"
  [ "$c" -ge 1 ] || fail "shard $i is empty"
done
shard 9 8 "$tests" "$refs" > "$work/last" && [ "$(grep -c '^\*\.' "$work/last" || true)" -le 1 ] \
  && ok "as many shards as classes puts at most one on each" || fail "9 shards over 9 classes put several on one"
c="$(shard 12 11 "$tests" "$refs" | grep -c '^\*\.' || true)"
[ "$c" -eq 0 ] && ok "more shards than classes leaves the last ones empty, which is not an error" || fail "a surplus shard was not empty"

echo "-- failing closed"
bad() { # $1=description  $2...=args
  local d=$1; shift
  if shard "$@" > /dev/null 2>&1; then fail "$d"; else ok "$d"; fi
}
mkdir -p "$work/none" "$work/noRefs" "$work/mod" "$work/top" "$work/stray" "$work/doc"
bad "no classes at all is an error, not an empty run that passes" 3 0 "$work/none" "$refs"
printf 'package x\ninternal class ModScreenshotTest {\n  @PreviewTest fun a() {}\n}\n' > "$work/mod/M.kt"
mod="$(shard 1 0 "$work/mod" "$work/noRefs" | classes_of)"
[ "$mod" = "*.ModScreenshotTest" ] && ok "a class with a modifier is found" || fail "a class with a modifier should be found, got $mod"
printf 'package x\nclass AScreenshotTest {\n}\n@PreviewTest fun c() {}\n' > "$work/top/T.kt"
bad "a top-level @PreviewTest, in no class and so in no shard, is an error" 3 0 "$work/top" "$work/noRefs"
printf 'package x\nclass AScreenshotTest {\n}\n' > "$work/stray/A.kt"
printf 'package x\nclass Other {\n  @PreviewTest fun b() {}\n}\n' > "$work/stray/B.kt"
bad "a @PreviewTest in a file with no *ScreenshotTest class is an error" 3 0 "$work/stray" "$work/noRefs"
printf 'package x\nclass DScreenshotTest {\n}\n' > "$work/doc/D.kt"
printf 'package x\n/**\n * Not a @PreviewTest frame, only prose about one.\n */\nobject Data\n' > "$work/doc/Data.kt"
doc="$(shard 1 0 "$work/doc" "$work/noRefs" | classes_of)"
[ "$doc" = "*.DScreenshotTest" ] && ok "a comment that names the annotation is not a frame" || fail "a comment naming @PreviewTest should not fail, got $doc"
bad "a reference directory that does not exist is an error, not a silent exit" 3 0 "$work/mod" "$work/missingRefs"
msg="$(shard 3 0 "$work/mod" "$work/missingRefs" 2>&1 >/dev/null || true)"
grep -q "missingRefs.*does not exist.*reference_dir" <<<"$msg" && ok "and the message names the directory and the input" || fail "the missing-directory message was '$msg'"
mkdir -p "$refs/ui/GoneScreenshotTest"; : > "$refs/ui/GoneScreenshotTest/f.png"
bad "reference PNGs no class renders are an error, so they cannot pile up" 3 0 "$tests" "$refs"
rm -rf "$refs/ui/GoneScreenshotTest"
bad "a shard count of 0" 0 0 "$tests" "$refs"
bad "a shard count that is not a number" three 0 "$tests" "$refs"
bad "an index past the last shard" 3 3 "$tests" "$refs"
bad "an index that is not a number" 3 x "$tests" "$refs"
bad "a negative index" 3 -1 "$tests" "$refs"

echo "-- the action"
python3 -I - "$dir/action.yml" "$work/step.sh" <<'PY' || failures=$((failures + 1))
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
bad = []
if doc["runs"]["using"] != "composite":
    bad.append("not a composite action")
for need in ("shards", "index"):
    if not doc["inputs"][need].get("required"):
        bad.append(f"{need} is not required")
steps = doc["runs"]["steps"]
if len(steps) != 1 or steps[0].get("id") != "shard":
    bad.append("expected one step with id shard")
env = steps[0].get("env", {})
for key, want in (("SHARDS", "inputs.shards"), ("INDEX", "inputs.index"), ("TEST_DIR", "inputs.test_dir"),
                  ("REFERENCE_DIR", "inputs.reference_dir"), ("ACTION_PATH", "github.action_path")):
    if want not in str(env.get(key, "")):
        bad.append(f"{key} is not {want}")
run = steps[0]["run"]
if "${{" in run:
    bad.append("the run block interpolates an expression: inputs must come through env")
for out, val in (("filters", "steps.shard.outputs.filters"), ("empty", "steps.shard.outputs.empty")):
    if val not in str(doc["outputs"][out]["value"]):
        bad.append(f"output {out} does not read {val}")
open(sys.argv[2], "w").write(run)
for b in bad:
    print("FAIL  " + b)
if not bad:
    print("ok    inputs reach the script through env, nothing is interpolated into the shell, and both outputs are wired")
sys.exit(1 if bad else 0)
PY
run_step() { # $1=index  $2=shards  $3=test dir
  : > "$work/gh_output"
  ACTION_PATH="$dir" SHARDS="$2" INDEX="$1" TEST_DIR="$3" REFERENCE_DIR="$refs" GITHUB_OUTPUT="$work/gh_output" \
    bash "$work/step.sh" > "$work/step.log" 2>&1
}
run_step 0 3 "$tests"
# The output is read back the way a runner reads it: a name, a heredoc delimiter, lines, the delimiter.
read_output() {
  python3 -I - "$work/gh_output" "$1" <<'PY'
import sys
lines = open(sys.argv[1]).read().split("\n")
name, out, i = sys.argv[2], None, 0
while i < len(lines):
    line = lines[i]
    if line.startswith(name + "<<"):
        delim, i, body = line.split("<<", 1)[1], i + 1, []
        while lines[i] != delim:
            body.append(lines[i]); i += 1
        out = "\n".join(body); break
    if line.startswith(name + "="):
        out = line.split("=", 1)[1]; break
    i += 1
print(out if out is not None else "<unset>")
PY
}
filters="$(read_output filters)"
[ "$filters" = "$(shard 3 0 "$tests" "$refs")" ] && ok "the filters output is the script's own output for the shard" || fail "the filters output differs from the script's"
[ "$(read_output empty)" = false ] && ok "a shard with classes is not empty" || fail "a shard with classes reported empty"
run_step 11 12 "$tests"
[ "$(read_output empty)" = true ] && ok "a shard with no class reports empty, so the caller can skip Gradle instead of running the whole suite" || fail "an empty shard did not report empty"
if run_step 5 3 "$tests"; then fail "a bad index through the action did not fail the step"; else ok "a bad index fails the step"; fi
if run_step 0 3 "$work/none"; then fail "a test dir with no classes through the action did not fail the step"; else ok "a test dir with no classes fails the step"; fi

[ "$failures" -eq 0 ] || { echo "$failures failure(s)"; exit 1; }
echo "all passed"
