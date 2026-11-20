#!/usr/bin/env bash
#
# Holds the Robolectric cache action. Robolectric fetches its android-all jars from Maven Central itself, into
# ~/.m2, outside Gradle's cache; a 429 there fails every test. The action caches that directory on a hosted runner,
# keyed on the Robolectric version(s) the build declares, and can fetch named jars with a retry. This runs its two
# shell steps against scratch repositories and a stubbed `curl`, and checks the cache step's shape and where the
# action is used.
#
# What it holds: the version scan finds a catalog entry and a Gradle coordinate and joins several; a build that
# declares none, and a self-hosted runner, find nothing and so cache nothing; the cache is keyed on the versions
# with a restore key on the prefix; the pre-fetch retries, skips a jar it already has, refuses a bad name, and
# removes a partial download.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
action="$root/.github/actions/robolectric-cache/action.yml"
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
failures=0
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
pass() { echo "ok    $1"; }
expect() { # $1=description  $2=shell condition
  if (set -e; eval "$2") > /dev/null 2>&1; then pass "$1"; else fail "$1"; fi
}

python3 -I - "$action" "$work" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["runs"]["steps"]
for key, step_id, name in (("find", "find", None), ("fetch", None, "Fetch the named jars, retrying on a rate limit")):
    hits = [s for s in steps if (s.get("id") == step_id if step_id else s.get("name") == name)]
    if len(hits) != 1:
        sys.exit(f"the {key} step is not in the action exactly once")
    open(f"{sys.argv[2]}/{key}.sh", "w").write(hits[0]["run"])
PY

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=Dev GIT_AUTHOR_EMAIL=dev@example.com GIT_COMMITTER_NAME=Dev GIT_COMMITTER_EMAIL=dev@example.com

# $1 case, $2 runner environment, remaining args: "path=content" files the repository tracks.
versions_for() {
  local dir="$work/repo-$1" env=$2 spec out
  shift 2
  rm -rf "$dir"; git init -q -b main "$dir"
  for spec in "$@"; do
    mkdir -p "$dir/$(dirname "${spec%%=*}")"
    printf '%s\n' "${spec#*=}" > "$dir/${spec%%=*}"
  done
  git -C "$dir" add -A; git -C "$dir" commit -q --allow-empty -m c
  : > "$work/out"
  (cd "$dir" && RUNNER_ENVIRONMENT=$env GITHUB_OUTPUT="$work/out" bash "$work/find.sh" > /dev/null)
  out=$(sed -n 's/^versions=//p' "$work/out")
  printf '%s' "$out"
}
check() { # description expected got
  [ "$3" = "$2" ] && pass "$1" || fail "$1: expected '$2', got '$3'"
}

check "a catalog entry is found" "4.14.1" "$(versions_for a github-hosted 'gradle/libs.versions.toml=[versions]
robolectric = "4.14.1"
junit = "4.13.2"')"
check "a Gradle coordinate is found" "4.13" "$(versions_for b github-hosted 'app/build.gradle.kts=testImplementation("org.robolectric:robolectric:4.13")')"
check "a Groovy coordinate is found" "4.12.2" "$(versions_for c github-hosted "app/build.gradle=testImplementation 'org.robolectric:robolectric:4.12.2'")"
check "several versions are sorted and joined" "4.13_4.14.1" "$(versions_for d github-hosted 'gradle/libs.versions.toml=robolectric = "4.14.1"' 'lib/build.gradle.kts=testImplementation("org.robolectric:robolectric:4.13")')"
check "the same version twice is one" "4.14.1" "$(versions_for e github-hosted 'gradle/libs.versions.toml=robolectric = "4.14.1"' 'lib/build.gradle.kts=testImplementation("org.robolectric:robolectric:4.14.1")')"
check "a build that declares none finds none" "" "$(versions_for f github-hosted 'gradle/libs.versions.toml=junit = "4.13.2"')"
check "a similarly named library is not Robolectric" "" "$(versions_for g github-hosted 'gradle/libs.versions.toml=robolectric-shadows = "9.9.9"')"
check "a self-hosted runner caches nothing" "" "$(versions_for h self-hosted 'gradle/libs.versions.toml=robolectric = "4.14.1"')"

# The cache step and the wiring.
python3 -I - "$action" "$root" <<'PY' || failures=$((failures + 1))
import sys, yaml, glob, re
act = yaml.safe_load(open(sys.argv[1]))
root = sys.argv[2]
bad = []
steps = act["runs"]["steps"]
cache = [s for s in steps if str(s.get("uses", "")).startswith("actions/cache@")]
ro = [s for s in steps if str(s.get("uses", "")).startswith("actions/cache/restore@")]
if len(ro) != 1 or not re.search(r"@[0-9a-f]{40}$", ro[0]["uses"].split(" ")[0]) \
        or "inputs.read-only == 'true'" not in str(ro[0].get("if")) or ro[0]["with"] != cache[0]["with"]:
    bad.append("the read-only step is not one pinned restore with the saving step's path and keys")
if "inputs.read-only != 'true'" not in str(cache[0].get("if")):
    bad.append("the saving step runs for a read-only caller")
if len(cache) != 1:
    bad.append("the cache step is not in the action exactly once")
else:
    c = cache[0]
    if not re.search(r"@[0-9a-f]{40}$", c["uses"].split(" ")[0]):
        bad.append("actions/cache is not pinned to a commit")
    if "steps.find.outputs.versions != ''" not in str(c.get("if")):
        bad.append("the cache runs without a declared version")
    w = c["with"]
    if w["path"] != "~/.m2/repository/org/robolectric":
        bad.append("the cache path is not Robolectric's directory")
    if "steps.find.outputs.versions" not in w["key"] or "runner.os" not in w["key"]:
        bad.append("the key does not name the OS and the versions")
    rk = w["restore-keys"].strip().splitlines()
    if len(rk) != 1 or not w["key"].startswith(rk[0]) or "versions" in rk[0]:
        bad.append("the restore key is not the key's prefix without the versions")
for path, label in ((root + "/.github/workflows/android-app-ci.yml", "the Android app workflow"),
                    (root + "/.github/actions/ci-setup/action.yml", "ci-setup")):
    n = len(re.findall(r"robolectric-cache@v\d+\.\d+\.\d+", open(path).read()))
    want = 2 if "workflows" in path else 1
    if n != want:
        bad.append(f"{label} uses the cache action {n} times, not {want}")
ci = open(root + "/.github/actions/ci-setup/action.yml").read()
if not re.search(r"robolectric-cache@[^\n]*\n\s+with:\n(?:\s+[^\n]*\n)*?\s+read-only: \$\{\{ inputs\.gradle-cache-read-only == 'true'", ci):
    bad.append("ci-setup does not pass its read-only expression to the cache")
wf = open(root + "/.github/workflows/android-app-ci.yml").read()
uses = [m.start() for m in re.finditer(r"robolectric-cache@", wf)]
tails = [wf[u:u + 400] for u in uses]
if sum("read-only: 'true'" in t.split("- ")[0] or "read-only: 'true'" in t.split("\n\n")[0] for t in tails) != 1:
    bad.append("exactly one of the app workflow's two cache steps (screenshots) must be read-only")
for b in bad:
    print("FAIL  " + b)
if not bad:
    print("ok    the cache is pinned, keyed on the versions with a prefix restore key, and wired where Robolectric runs")
sys.exit(1 if bad else 0)
PY

# The pre-fetch, with curl stubbed.
mkdir "$work/bin"
cat > "$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CURL_LOG"
out=""; prev=""
for a in "$@"; do [ "$prev" = --output ] && out=$a; prev=$a; done
[ "${CURL_FAILS:-}" = 1 ] && { printf 'partial' > "$out"; exit 22; }
printf 'jar' > "$out"
STUB
chmod +x "$work/bin/curl"
fetch() { # $1 home, $2 jars, rest env
  local home=$1 jars=$2; shift 2
  mkdir -p "$home"; : > "$work/curl.log"
  env -i PATH="$work/bin:$PATH" HOME="$home" CURL_LOG="$work/curl.log" JARS="$jars" "$@" bash "$work/fetch.sh" > "$work/fetch.out" 2>&1
}
jar='android-all-instrumented:14-robolectric-10818077-i7'
fetch "$work/h1" "$jar" || fail "a named jar was not fetched"
expect "a named jar is fetched from Maven Central" 'grep -q "repo1.maven.org/maven2/org/robolectric/android-all-instrumented/14-robolectric-10818077-i7/android-all-instrumented-14-robolectric-10818077-i7.jar" "$work/curl.log"'
expect "with a retry that covers a rate limit, and a time cap" 'grep -q -- "--retry 6" "$work/curl.log" && grep -q -- "--retry-max-time 300" "$work/curl.log" && grep -q -- "--fail" "$work/curl.log"'
expect "into the layout Robolectric reads" '[ -s "$work/h1/.m2/repository/org/robolectric/android-all-instrumented/14-robolectric-10818077-i7/android-all-instrumented-14-robolectric-10818077-i7.jar" ]'
fetch "$work/h1" "$jar" || fail "a second fetch failed"
expect "a jar already in the cache is not fetched again" '[ ! -s "$work/curl.log" ] && grep -q "already here" "$work/fetch.out"'
if fetch "$work/h2" 'android-all-instrumented:14; rm -rf /'; then fail "a bad name was accepted"; else pass "a name with a shell metacharacter is refused"; fi
if fetch "$work/h3" 'nocolon'; then fail "a name with no version was accepted"; else pass "a name with no version is refused"; fi
fetch "$work/h4" "$jar" CURL_FAILS=1 || fail "a failed download stopped the job"
expect "a failed download is a warning, not a failure" 'grep -q "::warning::Could not fetch" "$work/fetch.out"'
expect "and leaves no partial jar behind" '[ ! -e "$work/h4/.m2/repository/org/robolectric/android-all-instrumented/14-robolectric-10818077-i7/android-all-instrumented-14-robolectric-10818077-i7.jar" ]'
fetch "$work/h5" "$jar
android-all:13-robolectric-9030017-i2" || fail "two jars were not fetched"
expect "several jars, one per line, are all fetched" '[ "$(wc -l < "$work/curl.log")" -eq 2 ]'
[ "$failures" -eq 0 ]
