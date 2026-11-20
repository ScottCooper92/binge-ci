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
  (cd "$dir" && RUNNER_ENVIRONMENT=$env JARS="${JARS:-}" GITHUB_OUTPUT="$work/out" bash "$work/find.sh" > /dev/null)
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

# The jars the caller names are part of the key, so a jar added later reaches a saved entry.
catalog='gradle/libs.versions.toml=robolectric = "4.14.1"'
plain=$(versions_for j github-hosted "$catalog"); export plain
with_jars=$(JARS='android-all-instrumented:14-r1' versions_for k github-hosted "$catalog")
more_jars=$(JARS='android-all-instrumented:14-r1
android-all-instrumented:13-r2' versions_for l github-hosted "$catalog")
reordered=$(JARS='android-all-instrumented:13-r2
android-all-instrumented:14-r1' versions_for m github-hosted "$catalog")
export with_jars more_jars reordered
expect "naming a jar changes the key but keeps the version in front" '[[ $with_jars == 4.14.1-???????? ]] && [ "$with_jars" != "$plain" ]'
expect "naming another jar changes it again" '[ "$more_jars" != "$with_jars" ]'
expect "the order the jars are named in does not" '[ "$reordered" = "$more_jars" ]'
expect "no jar named leaves the key as the version alone" '[ "$plain" = "4.14.1" ]'
check "naming jars where there is no Robolectric version still caches nothing" "" "$(JARS='a:b' versions_for n github-hosted 'gradle/libs.versions.toml=junit = "4.13.2"')"

# The cache steps and the wiring.
python3 -I - "$action" "$root" <<'PY' || failures=$((failures + 1))
import sys, yaml, glob, re
act = yaml.safe_load(open(sys.argv[1]))
root = sys.argv[2]
bad = []
steps = act["runs"]["steps"]
ro = [s for s in steps if str(s.get("uses", "")).startswith("actions/cache/restore@")]
rw = [s for s in steps if str(s.get("uses", "")).startswith("actions/cache@")]
if len(ro) != 1 or len(rw) != 1:
    bad.append("the action does not have exactly one restore-only step and one restore-and-save step")
else:
    for c in (ro[0], rw[0]):
        if not re.search(r"@[0-9a-f]{40}$", c["uses"].split(" ")[0]):
            bad.append("an actions/cache step is not pinned to a commit")
        if "steps.find.outputs.versions != ''" not in str(c.get("if")):
            bad.append("a cache step runs without a declared version")
        w = c["with"]
        if w["path"] != "~/.m2/repository/org/robolectric":
            bad.append("the cache path is not Robolectric's directory")
        if "steps.find.outputs.versions" not in w["key"] or "runner.os" not in w["key"]:
            bad.append("the key does not name the OS and the versions")
        rk = w["restore-keys"].strip().splitlines()
        if rk != ["robolectric-${{ runner.os }}-${{ steps.find.outputs.versions }}-", "robolectric-${{ runner.os }}-"]:
            bad.append("the restore keys are not the version's prefix, then any version's")
    if "inputs.read-only == 'true'" not in str(ro[0].get("if")) or "!= 'true'" not in str(rw[0].get("if")):
        bad.append("the read-only input does not choose between the restore-only and the saving step")
    if act["inputs"]["read-only"].get("default") != "false":
        bad.append("read-only does not default to false")
    outs = act.get("outputs", {})
    if "versions" not in outs or "matched-key" not in outs or "cache-matched-key" not in outs["matched-key"]["value"]:
        bad.append("the action does not hand the versions and the matched key on")
for path, label in ((root + "/.github/workflows/android-app-ci.yml", "the Android app workflow"),
                    (root + "/.github/actions/ci-setup/action.yml", "ci-setup")):
    text = open(path).read()
    want = 2 if "workflows" in path else 1
    if len(re.findall(r"robolectric-cache@v\d+\.\d+\.\d+", text)) != want:
        bad.append(f"{label} does not use the cache action {want} time(s)")
    if "ci-setup" in label and "read-only: ${{ inputs.gradle-cache-read-only == 'true'" not in text:
        bad.append("ci-setup does not pass the Gradle cache's read-only rule to the Robolectric cache")
    if "workflow" in label:
        # The tests job is the one writer, on the default branch; the screenshots job restores only.
        t = text[text.index("\n  tests:\n"):text.index("\n  screenshots:\n")]
        sc = text[text.index("\n  screenshots:\n"):text.index("\n  release:\n")]
        if "robolectric-cache@" not in t or "read-only: 'true'" not in t:
            bad.append("the tests job does not restore through the restore-only path")
        m = re.search(r"robolectric-cache-save@v\d+\.\d+\.\d+\n\s+if: (.*)\n\s+with:\n\s+versions: (.*)\n\s+restored-key: (.*)\n", t)
        if not m:
            bad.append("the tests job does not save after the tests")
        else:
            cond = m.group(1)
            if "success()" not in cond or "github.ref_name == github.event.repository.default_branch" not in cond:
                bad.append("the save is not after a green run on the default branch only")
            if "steps.robolectric.outputs.versions" not in m.group(2) or "steps.robolectric.outputs.matched-key" not in m.group(3):
                bad.append("the save is not given the versions and the matched key")
            if t.index("robolectric-cache-save@") < t.index("Unit tests and coverage"):
                bad.append("the save runs before the tests")
        if "robolectric-cache-save@" in sc:
            bad.append("the screenshots job saves")
        if "robolectric-cache@" not in sc or "read-only: 'true'" not in sc:
            bad.append("the screenshots job is not restore-only")
for b in bad:
    print("FAIL  " + b)
if not bad:
    print("ok    the cache is pinned, keyed on the versions with a prefix restore key, and wired where Robolectric runs")
sys.exit(1 if bad else 0)
PY

# The save step's key: it names the jars present, so a jar added later is a new entry (#427).
python3 -I - "$root/.github/actions/robolectric-cache-save/action.yml" "$work" <<'PYX'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["runs"]["steps"]
k = [s for s in steps if s.get("id") == "key"]
sv = [s for s in steps if str(s.get("uses", "")).startswith("actions/cache/save@")]
if len(k) != 1 or len(sv) != 1:
    sys.exit("the save action does not have one key step and one save step")
open(sys.argv[2] + "/savekey.sh", "w").write(k[0]["run"])
if "steps.key.outputs.key != ''" not in str(sv[0].get("if")) or sv[0]["with"]["key"] != "${{ steps.key.outputs.key }}":
    sys.exit("the save does not use the named key, or runs without one")
PYX
savekey() { # $1 home, $2 versions, $3 restored key, $4 runner environment
  : > "$work/out"
  env -i PATH="$PATH" HOME="$1" VERSIONS="$2" RESTORED="$3" OS=Linux RUNNER_ENVIRONMENT="${4:-github-hosted}" GITHUB_OUTPUT="$work/out" bash "$work/savekey.sh" > "$work/savekey.out" 2>&1
  sed -n 's/^key=//p' "$work/out"
}
jars="$work/save-home/.m2/repository/org/robolectric/android-all-instrumented"
mkdir -p "$jars/14-r1"; printf 'one' > "$jars/14-r1/android-all-instrumented-14-r1.jar"
key1=$(savekey "$work/save-home" 4.14.1 ""); export key1
expect "the key names the OS, the versions and a hash of the jars present" '[[ $key1 == robolectric-Linux-4.14.1-???????????? ]]'
expect "the same jars give the same key" '[ "$(savekey "$work/save-home" 4.14.1 "")" = "$key1" ]'
expect "the entry that was restored is not saved again" '[ -z "$(savekey "$work/save-home" 4.14.1 "$key1")" ]'
mkdir -p "$jars/13-r2"; printf 'two' > "$jars/13-r2/android-all-instrumented-13-r2.jar"
key2=$(savekey "$work/save-home" 4.14.1 "$key1"); export key2
expect "a jar added under the same version is a new key, saved though the old one was restored" '[ -n "$key2" ] && [ "$key2" != "$key1" ]'
expect "and it still starts with the version, so the restore key finds it" '[[ $key2 == robolectric-Linux-4.14.1-* ]]'
expect "no version means nothing is saved" '[ -z "$(savekey "$work/save-home" "" "")" ]'
expect "a self-hosted runner saves nothing" '[ -z "$(savekey "$work/save-home" 4.14.1 "" self-hosted)" ]'
mkdir -p "$work/empty-home/.m2/repository/org/robolectric"
expect "a directory with no jar saves nothing" '[ -z "$(savekey "$work/empty-home" 4.14.1 "")" ]'
expect "a missing directory saves nothing" '[ -z "$(savekey "$work/none-home" 4.14.1 "")" ]'

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
