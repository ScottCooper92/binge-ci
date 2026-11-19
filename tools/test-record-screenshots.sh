#!/usr/bin/env bash
#
# Holds record-screenshots.yml, which pushes a commit to a branch on a maintainer's word. What it must never do
# is what this checks: start for anyone but a person with write access, record on the default branch, put
# anything but PNG files into the commit, or force a push. The two steps that decide that are cut out of the
# workflow and run here against stubs and scratch repositories, so this tests what runs.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
workflow="$root/.github/workflows/record-screenshots.yml"
caller="$root/callers/example/record-screenshots.yml"
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
failures=0
ok() { echo "ok    $1"; }
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }

python3 -I - "$workflow" "$caller" "$work" <<'PY' || failures=$((failures + 1))
import re, sys, yaml
wf_path, caller_path, work = sys.argv[1:4]
text = open(wf_path).read()
wf = yaml.safe_load(text)
caller = yaml.safe_load(open(caller_path))
bad = []
triggers = wf[True]
if set(triggers) != {"workflow_call"}:
    bad.append(f"the workflow has triggers of its own: {sorted(triggers)}")
if set(caller[True]) != {"workflow_dispatch"}:
    bad.append(f"the worked caller is not dispatch only: {sorted(caller[True])}")
steps = wf["jobs"]["record"]["steps"]
names = [s.get("name", s.get("uses", "")) for s in steps]
i_check = names.index("Check the request")
for n, s in enumerate(steps):
    if n < i_check and ("uses" in s):
        bad.append("a step that uses an action runs before the request is checked")
    if str(s.get("uses", "")).startswith(("actions/create-github-app-token", "actions/checkout")) and n < i_check:
        bad.append("a token is minted or code checked out before the request is checked")
if i_check != 0:
    bad.append("the request is not checked first")
by_name = {s.get("name"): s for s in steps}
open(f"{work}/request.sh", "w").write(by_name["Check the request"]["run"])
commit = by_name["Commit the changed frames"]["run"]
open(f"{work}/commit.sh", "w").write(commit)
# What the commit step may stage and how it may push.
if re.search(r"git add (-A|--all|\.)", commit) or 'git add -- "${pngs[@]}"' not in commit:
    bad.append("the commit step stages more than the PNG list")
if re.search(r"git push[^\n]*(--force|-f\b|\+HEAD|--force-with-lease)", commit):
    bad.append("the commit step forces its push")
if 'git push origin "HEAD:refs/heads/$REF"' not in commit:
    bad.append("the commit step pushes anything but the named branch")
# The report job holds no secrets and always runs.
report = wf["jobs"]["report"]
if "always()" not in str(report.get("if", "")) or "secrets." in str(report):
    bad.append("the report job is not `always()` or reads a secret")
# The push runs on the author app's token, so CI starts on the commit; the report on the workflow's own.
checkout = [s for s in steps if str(s.get("uses", "")).startswith("actions/checkout@")][0]
if "steps.token.outputs.token" not in str(checkout["with"].get("token")):
    bad.append("the checkout, whose token pushes, is not the author app's")
if wf["permissions"] != {"contents": "read", "pull-requests": "write"}:
    bad.append(f"the workflow's permissions are not contents read and pull requests write: {wf['permissions']}")
# Every Gradle argument list comes from an input through the environment.
for s in steps:
    run = str(s.get("run", ""))
    if "./gradlew \"${args[@]}\"" in run:
        if "inputs." not in str(s.get("env", {}).get("TASKS", "")) or "${{" in run:
            bad.append(f"{s.get('name')}: its Gradle arguments are not an input through the environment")
for ref in re.findall(r"^\s*(?:- )?uses:\s*(\S+)", text, re.M):
    if not (re.search(r"@[0-9a-f]{40}$", ref) or re.search(r"@v\d+\.\d+\.\d+$", ref)):
        bad.append(f"{ref}: an action is not pinned")
for b in bad:
    print("FAIL  " + b)
if not bad:
    print("ok    dispatch only, the request checked first, the push on the author app's token and never forced, PNG files only, the report always")
sys.exit(1 if bad else 0)
PY

# --- the request check, run against a stubbed gh ---
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *collaborators/*/permission*) echo "${STUB_PERMISSION:-write}" ;;
  *branches/*) [ "${STUB_BRANCH_MISSING:-}" = 1 ] && exit 1 || echo branch ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$work/bin/gh"
request() { # extra env assignments
  : > "$work/out"
  env -i PATH="$work/bin:$PATH" GITHUB_OUTPUT="$work/out" EVENT=workflow_dispatch SENDER_TYPE=User ACTOR=maintainer \
    GH_TOKEN=t GH_REPO=o/r REF=feature/x TESTS='com.example.home.*ScreenshotTest' DEFAULT_BRANCH=main TRUSTED_DISPATCHER= "$@" \
    bash "$work/request.sh" > "$work/request.log" 2>&1
}
accepts() { if request "${@:2}"; then ok "$1"; else fail "$1 was refused: $(grep -m1 error "$work/request.log")"; fi; }
refuses() { if request "${@:2}"; then fail "$1 was accepted"; else grep -q 'refusal=' "$work/out" && ok "$1" || fail "$1 failed without a reason"; fi; }
accepts "a dispatch by a person with write access, on a branch, with a class filter"
accepts "two filters, one a pattern" TESTS='a.b.HomeScreenshotTest,a.c.*Detail*'
accepts "admin permission" STUB_PERMISSION=admin
refuses "a push event" EVENT=push
refuses "a pull request event" EVENT=pull_request
refuses "a bot sender" SENDER_TYPE=Bot
refuses "a bot with no trusted dispatcher named" SENDER_TYPE=Bot ACTOR=author-bot
refuses "a bot other than the one named" SENDER_TYPE=Bot ACTOR=other-bot TRUSTED_DISPATCHER=author-bot
refuses "a bot whose login differs in case" SENDER_TYPE=Bot ACTOR=Author-Bot TRUSTED_DISPATCHER=author-bot
refuses "a user whose login is the one named, with no write access" ACTOR=author-bot TRUSTED_DISPATCHER=author-bot STUB_PERMISSION=none
refuses "the named bot on the default branch" SENDER_TYPE=Bot ACTOR=author-bot TRUSTED_DISPATCHER=author-bot REF=main
refuses "the named bot on a push event" SENDER_TYPE=Bot ACTOR=author-bot TRUSTED_DISPATCHER=author-bot EVENT=push
refuses "the named bot with a bad filter" SENDER_TYPE=Bot ACTOR=author-bot TRUSTED_DISPATCHER=author-bot 'TESTS=$(id)'
accepts "the bot the caller names, which is not a collaborator" SENDER_TYPE=Bot ACTOR=author-bot TRUSTED_DISPATCHER=author-bot STUB_PERMISSION=none
refuses "a user with read permission" STUB_PERMISSION=read
refuses "a user with no permission" STUB_PERMISSION=none
refuses "the default branch" REF=main
refuses "a branch name with .." REF=a/../b
refuses "a branch name that starts with a dash" REF=-x
refuses "a branch name with a space" "REF=a b"
refuses "a branch that does not exist" STUB_BRANCH_MISSING=1
refuses "a filter with a semicolon" 'TESTS=a.B; rm -rf /'
refuses "a filter with a command substitution" 'TESTS=$(id)'
refuses "a filter with a space" 'TESTS=a.B --tests c.D'
refuses "an empty filter" TESTS=
refuses "a leading comma" TESTS=,a.B
refuses "an empty element" TESTS=a.B,,c.D

# --- the commit step, run against scratch repositories ---
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
git init -q --bare -b main "$work/origin.git"
git clone -q "$work/origin.git" "$work/repo" 2> /dev/null
cd "$work/repo"
git config user.email dev@example.com && git config user.name Dev
git checkout -q -b main
mkdir -p app/src/screenshotTest/reference docs
printf 'one' > app/src/screenshotTest/reference/Home_Default.png
printf 'two' > "app/src/screenshotTest/reference/Home Dark.png"
printf 'lock' > app.lockfile
echo '*.log' > .gitignore
git add -A && git commit -q -m base && git push -q origin main
git checkout -q -b feature/x && git push -q origin feature/x
reset_to_branch() { git checkout -q feature/x && git reset -q --hard origin/feature/x && git clean -qfdx; }
# A wrapper that records the credential environment git is given at a push, then runs the real git.
mkdir -p "$work/gitbin"
real_git=$(command -v git)
cat > "$work/gitbin/git" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = push ]; then { echo "ARGV: \$*"; env | grep '^GIT_CONFIG_' | sort -V; echo "--"; } >> "\$PUSH_LOG"; fi
exec "$real_git" "\$@"
STUB
chmod +x "$work/gitbin/git"
commit_step() {
  : > "$work/out"
  env -i PATH="$work/gitbin:$PATH" HOME="$work" PUSH_LOG="$work/push.log" APP_TOKEN=APPTOKEN123 SERVER_URL=https://github.com GITHUB_TOKEN=ACTIONSTOKEN GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GITHUB_OUTPUT="$work/out" GITHUB_STEP_SUMMARY="$work/summary" \
    REF=feature/x TESTS='a.b.*ScreenshotTest' bash "$work/commit.sh" > "$work/commit.log" 2>&1
}
outcome() { sed -n 's/^outcome=//p' "$work/out"; }

echo "-- the frames changed"
printf 'one-new' > app/src/screenshotTest/reference/Home_Default.png
printf 'brand-new' > "app/src/screenshotTest/reference/New Frame.png"
rm "app/src/screenshotTest/reference/Home Dark.png"
printf 'noise' > build.log
if commit_step && [ "$(outcome)" = recorded ]; then ok "changed, new and deleted PNGs are committed and pushed"; else fail "PNG changes were not recorded: $(cat "$work/commit.log")"; fi
files=$(git diff --name-only HEAD~1 HEAD | sort | tr '\n' ',')
[ "$files" = 'app/src/screenshotTest/reference/Home Dark.png,app/src/screenshotTest/reference/Home_Default.png,app/src/screenshotTest/reference/New Frame.png,' ] \
  && ok "the commit has exactly those three files, and not the ignored log" || fail "the commit holds: $files"
[ "$(git log -1 --format=%s)" = "chore: record screenshots for a.b.*ScreenshotTest" ] && ok "the message names the filter" || fail "message: $(git log -1 --format=%s)"
[ "$(git rev-parse HEAD)" = "$(git -C "$work/origin.git" rev-parse feature/x)" ] && ok "the branch on the remote is the new commit" || fail "the remote branch did not move"
[ "$(git -C "$work/origin.git" rev-parse main)" = "$(git rev-parse main)" ] && ok "and the default branch is untouched" || fail "main moved"
grep -q 'Recorded 3 frame' "$work/summary" && ok "the step summary says how many" || fail "no summary"

echo "-- the push is made with the author app's token"
# GITHUB_TOKEN starts no workflow, so a push made with it leaves the consumer's CI unrun and its required check
# missing. The step has to name the installation token itself, and never put it where another process can read it.
if python3 -I - "$work/push.log" <<'INNER'
import base64, re, sys
text = open(sys.argv[1]).read()
push = text.split("--")[0]
argv = re.search(r"^ARGV: (.*)$", push, re.M).group(1)
entries = {}
for m in re.finditer(r"^GIT_CONFIG_(KEY|VALUE)_(\d+)=(.*)$", push, re.M):
    entries.setdefault(int(m.group(2)), {})[m.group(1)] = m.group(3)
pairs = [(e["KEY"], e["VALUE"]) for _, e in sorted(entries.items())]
count = re.search(r"^GIT_CONFIG_COUNT=(\d+)$", push, re.M)
want = "AUTHORIZATION: basic " + base64.b64encode(b"x-access-token:APPTOKEN123").decode()
key = "http.https://github.com/.extraheader"
bad = []
headers = [v for k, v in pairs if k == key]
if headers != ["", want]:
    bad.append(f"expected an empty reset then the app token's header, got {headers!r}")
if not count or int(count.group(1)) != len(pairs):
    bad.append("GIT_CONFIG_COUNT does not cover the entries, so git would ignore them")
if "APPTOKEN123" in argv or "ACTIONSTOKEN" in argv or want in argv:
    bad.append("a token is in the push's argv")
if "ACTIONSTOKEN" in push or any("ACTIONSTOKEN" in v for _, v in pairs):
    bad.append("GITHUB_TOKEN reached the push")
print("\n".join("      " + b for b in bad))
sys.exit(1 if bad else 0)
INNER
then ok "the push carries the installation token's header after an empty reset, with no token in argv and no GITHUB_TOKEN"; else fail "the push is not made with the installation token alone"; fi
if grep -q 'APPTOKEN123' "$work/commit.log"; then fail "the token is in the log in the clear"; else ok "and the token is not in the step's log"; fi
grep -q "Pushed with the author app's installation token" "$work/summary" && ok "the step summary says which token pushed" || fail "the summary does not say which token pushed"

echo "-- nothing changed"
reset_to_branch
before=$(git rev-parse HEAD)
if commit_step && [ "$(outcome)" = unchanged ] && [ "$(git rev-parse HEAD)" = "$before" ]; then ok "no change is not an error and makes no commit"; else fail "an unchanged run: $(cat "$work/commit.log")"; fi

echo "-- a file that is not a PNG"
reset_to_branch
printf 'one-newer' > app/src/screenshotTest/reference/Home_Default.png
printf 'lock-changed' > app.lockfile
before=$(git rev-parse HEAD)
if commit_step; then fail "a changed lock file went into a recording"; elif [ "$(outcome)" = other-files ] && grep -q 'app.lockfile' "$work/commit.log" && [ "$(git rev-parse HEAD)" = "$before" ]; then ok "a changed non-PNG file fails the run, is named, and nothing is committed"; else fail "wrong handling of a non-PNG change: $(cat "$work/commit.log")"; fi
reset_to_branch
printf 'one-newer' > app/src/screenshotTest/reference/Home_Default.png
mkdir -p docs && printf 'generated' > docs/new.kt
if commit_step; then fail "a new source file went into a recording"; elif [ "$(outcome)" = other-files ]; then ok "a new untracked non-PNG file fails the run too"; else fail "a new file was not refused"; fi

echo "-- a branch that moved under the run"
reset_to_branch
git clone -q "$work/origin.git" "$work/other" 2> /dev/null
( cd "$work/other" && git config user.email a@b.c && git config user.name A && git checkout -q feature/x && printf 'x' > person.txt && git add -A && git commit -q -m "a person's push" && git push -q origin feature/x )
moved=$(git -C "$work/origin.git" rev-parse feature/x)
printf 'one-again' > app/src/screenshotTest/reference/Home_Default.png
if commit_step; then fail "a push to a branch that had moved was accepted"; elif [ "$(git -C "$work/origin.git" rev-parse feature/x)" = "$moved" ]; then ok "the push is not forced: the person's commit is still the branch's head"; else fail "the remote branch was overwritten"; fi

[ "$failures" -eq 0 ] || { echo "$failures failure(s)"; exit 1; }
echo "all passed"
