#!/usr/bin/env bash
#
# Holds the ci-setup action's sizing ladder. Gradle's heap and the screenshot workers are chosen from the
# runner's usable memory, and a wrong rung is an out-of-memory kill in a consumer's build, not a Gradle
# error. This runs the two steps that decide it against each size, with the memory and the runner kind
# filled in the way the action's own expressions would.
#
# What it holds: a hosted runner keeps its settings whatever the memory says; an undetected runner (0) and
# one of 24 GB or more get the large rung; a runner under 12 GB gets the small one and a single worker;
# a runner from 12 to 23 GB keeps the middle rung; and the screenshot workers follow the same sizes.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
action="$root/.github/actions/ci-setup/action.yml"
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
failures=0
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
pass() { echo "ok    $1"; }

python3 -I - "$action" "$work" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["runs"]["steps"]
for key, name in (("tune", "Tune Gradle for CI runners"), ("workers", "Size screenshot workers to runner RAM")):
    hits = [s for s in steps if s.get("name") == name]
    if len(hits) != 1:
        sys.exit(f"{name} is not in the action exactly once")
    open(f"{sys.argv[2]}/{key}.sh", "w").write(hits[0]["run"])
PY

# $1 hosted, $2 memory in GB: prints "<jvmargs>|<kotlin>|<workers max>|<screenshot workers>".
run() {
  local dir="$work/home-$1-$2"
  mkdir -p "$dir"
  : > "$dir/env"
  local sub="s/\${{ steps.runner.outputs.mem_gb }}/$2/g; s/\${{ steps.runner.outputs.hosted }}/$1/g"
  sed "$sub" "$work/tune.sh" > "$dir/tune.sh"
  sed "$sub" "$work/workers.sh" > "$dir/workers.sh"
  GRADLE_USER_HOME="$dir/gradle" bash "$dir/tune.sh" > /dev/null
  GITHUB_ENV="$dir/env" bash "$dir/workers.sh" > /dev/null
  local props="$dir/gradle/gradle.properties"
  printf '%s|%s|%s|%s' \
    "$(sed -n 's/^org.gradle.jvmargs=-\(Xmx[0-9a-z]*\) .*/\1/p' "$props")" \
    "$(sed -n 's/^kotlin.daemon.jvmargs=-//p' "$props")" \
    "$(sed -n 's/^org.gradle.workers.max=//p' "$props")" \
    "$(sed -n 's/^SCREENSHOT_MAX_WORKERS=//p' "$dir/env")"
}
check() { # $1 description, $2 hosted, $3 memory, $4 expected
  local got
  got=$(run "$2" "$3")
  [ "$got" = "$4" ] && pass "$1" || fail "$1: expected $4, got $got"
}

check "an 8 GB runner gets the small rung and one worker" false 8 "Xmx4g|Xmx768m|1|1"
check "a 1 GB runner gets the small rung" false 1 "Xmx4g|Xmx768m|1|1"
check "an 11 GB runner is still small" false 11 "Xmx4g|Xmx768m|1|1"
check "a 12 GB runner keeps the middle rung" false 12 "Xmx6g|Xmx1g|2|2"
check "a 23 GB runner keeps the middle rung" false 23 "Xmx6g|Xmx1g|2|2"
check "a 24 GB runner gets the large rung" false 24 "Xmx10g|Xmx2g|5|2"
check "a 28 GB runner gets four screenshot workers" false 28 "Xmx10g|Xmx2g|5|4"
check "a 40 GB runner gets six screenshot workers" false 40 "Xmx10g|Xmx2g|5|6"
check "an undetected runner gets the large rung and four workers" false 0 "Xmx10g|Xmx2g|5|4"
check "a hosted runner is the same whatever its memory" true 8 "Xmx4g|Xmx1g|2|2"
check "a hosted runner with more memory is the same" true 64 "Xmx4g|Xmx1g|2|2"

props=$(cat "$work/home-false-8/gradle/gradle.properties")
for opt in "-XX:MaxMetaspaceSize=768m" "-XX:+UseParallelGC" "-XX:+HeapDumpOnOutOfMemoryError"; do
  grep -qF -- "$opt" <<<"$props" && pass "the small rung keeps $opt" || fail "the small rung lost $opt"
done
[ "$failures" -eq 0 ]
