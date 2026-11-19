#!/usr/bin/env bash
#
# Runs check-token-permissions.sh against fixture workflows, one per case it has to tell apart. The
# check reads the real repository in CI, where every mint passes, so without these the failures it
# exists to report would never be exercised. Each case names the line the check must print, so a
# fixture that fails for some other reason does not pass.
set -euo pipefail

check="$(cd "$(dirname "$0")" && pwd)/check-token-permissions.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

# A tree with one workflow whose steps are the argument.
fixture() {
  local name=$1 steps=$2
  mkdir -p "$work/$name/.github/workflows"
  printf 'on: push\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n%s\n' "$steps" \
    > "$work/$name/.github/workflows/sample.yml"
}

# Passes when the check exits as expected and, for a failure, prints the expected text.
expect() {
  local name=$1 want=$2 text=${3:-} status=0
  CHECK_ROOT="$work/$name" "$check" > "$work/$name.out" 2>&1 || status=$?
  local got=pass
  [ "$status" -eq 0 ] || got=fail
  if [ "$got" = "$want" ] && { [ -z "$text" ] || grep -qF -- "$text" "$work/$name.out"; }; then
    echo "ok    $name: ${want}, as expected"
  else
    echo "FAIL  $name: expected it to $want${text:+ with \"$text\"}, exit $status:"
    sed 's/^/      /' "$work/$name.out"
    failures=1
  fi
}

mint() { # indent, first-line prefix, secret, permission lines
  local pad=$1 lead=$2 secret=$3 perms=$4
  printf '%s%suses: actions/create-github-app-token@0000000000000000000000000000000000000000 # v2\n' "$pad" "$lead"
  printf '%s  with:\n%s    app-id: ${{ secrets.%s }}\n%s    private-key: ${{ secrets.KEY }}\n' \
    "$pad" "$pad" "$secret" "$pad"
  local p
  for p in $perms; do printf '%s    permission-%s: read\n' "$pad" "$p"; done
}

fixture granted "      - name: Mint
$(mint '        ' '' AUTHOR_APP_ID 'contents pull-requests')"
expect granted pass

fixture whole-installation "      - name: Mint
$(mint '        ' '' UNLISTED_APP_ID '')"
expect whole-installation pass

fixture not-granted "      - name: Mint
$(mint '        ' '' AUTHOR_APP_ID 'contents issues')"
expect not-granted fail "permission-issues is not granted to the AUTHOR_APP_ID installation"

fixture unknown-app "      - name: Mint
$(mint '        ' '' UNLISTED_APP_ID 'contents')"
expect unknown-app fail "its app (UNLISTED_APP_ID) has no grant recorded"

# A step opened by `- uses:` ends at the next step's dash, which sits at the same column. Read past
# it, and the next step's app and permissions are taken for this one's: here, the reviewer mint
# would be judged as the author's and pass.
fixture dash-uses-then-step "$(mint '      ' '- ' UNLISTED_APP_ID 'contents')
      - name: Next
$(mint '        ' '' AUTHOR_APP_ID 'contents')"
expect dash-uses-then-step fail "its app (UNLISTED_APP_ID) has no grant recorded"

fixture dash-uses-blames-own-app "$(mint '      ' '- ' UNLISTED_APP_ID 'issues')
      - name: Next
$(mint '        ' '' AUTHOR_APP_ID 'contents')"
expect dash-uses-blames-own-app fail "its app (UNLISTED_APP_ID) has no grant recorded"

# A step whose `with:` comes before its `uses:` still has its app and permissions read.
fixture with-before-uses "      - name: Mint
        with:
          app-id: \${{ secrets.AUTHOR_APP_ID }}
          permission-issues: read
        uses: actions/create-github-app-token@0000000000000000000000000000000000000000 # v2"
expect with-before-uses fail "permission-issues is not granted to the AUTHOR_APP_ID installation"

fixture no-mints "      - run: 'true'"
expect no-mints fail "No create-github-app-token step found"

# The author bots' write token stays the calling repository's. The same steps are judged by the file
# name, so these fixtures are written under an author workflow's name.
bot_fixture() {
  local name=$1 file=$2 steps=$3
  mkdir -p "$work/$name/.github/workflows"
  printf 'on: push\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n%s\n' "$steps" \
    > "$work/$name/.github/workflows/$file"
}
widened_write="      - name: Mint author app token
        uses: actions/create-github-app-token@0000000000000000000000000000000000000000 # v2
        with:
          app-id: \${{ secrets.AUTHOR_APP_ID }}
          private-key: \${{ secrets.KEY }}
          repositories: \${{ inputs.private_submodules != '' && format('{0},{1}', 'x', inputs.private_submodules) || '' }}"
plain_write="      - name: Mint author app token
        uses: actions/create-github-app-token@0000000000000000000000000000000000000000 # v2
        with:
          app-id: \${{ secrets.AUTHOR_APP_ID }}
          private-key: \${{ secrets.KEY }}"
read_mint="      - name: Mint a read-only token for private submodules
        uses: actions/create-github-app-token@0000000000000000000000000000000000000000 # v2
        with:
          app-id: \${{ secrets.AUTHOR_APP_ID }}
          private-key: \${{ secrets.KEY }}
          repositories: \${{ inputs.private_submodules }}
          permission-contents: read"

bot_fixture write-widened author-comments.yml "$widened_write"
expect write-widened fail "would reach more than the calling repository"

bot_fixture write-plus-read author-comments.yml "$plain_write
$read_mint"
expect write-plus-read pass

bot_fixture read-too-wide author-comments.yml "$plain_write
$read_mint
          permission-pull-requests: read"
expect read-too-wide fail "has to ask for permission-contents: read and nothing else"

# The value is read, not just the name: a contents mint that can write is the old problem again.
bot_fixture read-mint-writes author-comments.yml "$plain_write
${read_mint/permission-contents: read/permission-contents: write}"
expect read-mint-writes fail "has to ask for permission-contents: read and nothing else"

bot_fixture write-mint-other-repos author-comments.yml "      - name: Mint author app token
        uses: actions/create-github-app-token@0000000000000000000000000000000000000000 # v2
        with:
          app-id: \${{ secrets.AUTHOR_APP_ID }}
          private-key: \${{ secrets.KEY }}
          repositories: other-repo
          permission-contents: write"
expect write-mint-other-repos fail "would reach more than the calling repository"

# submodule-bump.yml is held to the same rule: its write token reaches the calling repository alone.
bot_fixture bump-widens submodule-bump.yml "$widened_write"
expect bump-widens fail "would reach more than the calling repository"

bot_fixture bump-split submodule-bump.yml "$plain_write
$read_mint"
expect bump-split pass

# The submodule fetch step the author bots share. Each of the five copies must be the same, no checkout
# may fetch submodules itself (that would use the write token), and the step, run against a stubbed
# `git`, must give the read token to the listed repositories only: never on a broader URL key.
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$work/fetch"
python3 -I - "$root" "$work/fetch" <<'PY' || failures=1
import sys, yaml
root, out = sys.argv[1:3]
n, bad = 0, []
for wf in ["author-ci-fix", "author-comments", "author-conflicts", "author-retarget"]:
    doc = yaml.safe_load(open(f"{root}/.github/workflows/{wf}.yml"))
    for job, body in doc["jobs"].items():
        steps = body.get("steps", [])
        for s in steps:
            if str(s.get("uses", "")).startswith("actions/checkout@"):
                if "submodules" in s.get("with", {}):
                    bad.append(f"{wf}/{job}: the checkout fetches submodules itself, with the write token")
                names = [t.get("name") for t in steps]
                if names.count("Fetch the submodules") != 1:
                    bad.append(f"{wf}/{job}: no single 'Fetch the submodules' step beside the checkout")
        for s in steps:
            if s.get("name") == "Fetch the submodules":
                n += 1
                open(f"{out}/step.{n}", "w").write(s["run"])
                env = s.get("env", {})
                if "token" in "".join(env.keys()).lower() and set(env) - {"SUBMODULE_TOKEN", "PRIVATE_SUBMODULES", "OWNER"}:
                    bad.append(f"{wf}/{job}: the fetch step has an unexpected token in its environment")
                if "steps.token." in str(env):
                    bad.append(f"{wf}/{job}: the fetch step is handed the write token")
for b in bad:
    print("FAIL  " + b)
print(f"{n} fetch steps found")
sys.exit(1 if bad or n != 5 else 0)
PY
same=true
for copy in "$work"/fetch/step.*; do cmp -s "$work/fetch/step.1" "$copy" || same=false; done
if [ "$(ls "$work"/fetch/step.* 2>/dev/null | wc -l)" -eq 5 ] && [ "$same" = true ]; then
  echo "ok    the fetch step is the same in all five places"
else
  echo "FAIL  the fetch step differs between jobs"; failures=1
fi

mkdir -p "$work/bin"
cat > "$work/bin/git" <<'STUB'
#!/usr/bin/env bash
echo "git $*" >> "$STUB_LOG"
env | grep '^GIT_CONFIG_' | sort -V >> "$STUB_LOG" || true
STUB
chmod +x "$work/bin/git"
run_fetch() { # the list of repositories, "" for none
  : > "$work/fetch.log"
  # Starts from a clean GIT_CONFIG_*, as a runner does, unless the case presets one (second argument).
  local v args=()
  while IFS= read -r v; do args+=(-u "$v"); done < <(env | grep -o '^GIT_CONFIG_[^=]*' || true)
  [ -z "${2:-}" ] || args+=(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.x GIT_CONFIG_VALUE_0=kept)
  env "${args[@]}" PATH="$work/bin:$PATH" STUB_LOG="$work/fetch.log" SUBMODULE_TOKEN=READTOKEN \
    PRIVATE_SUBMODULES="$1" OWNER=acme bash "$work/fetch/step.1" >/dev/null
}
run_fetch ""
# Only the ssh-to-https rewrite, as actions/checkout set it: no http.* entry, so no credential.
if grep -qx 'GIT_CONFIG_COUNT=1' "$work/fetch.log" && grep -qx 'GIT_CONFIG_KEY_0=url.https://github.com/.insteadOf' "$work/fetch.log" \
   && ! grep -q 'GIT_CONFIG_KEY_[0-9]*=http\.' "$work/fetch.log" \
   && grep -q 'git submodule update --init --recursive' "$work/fetch.log"; then
  echo "ok    with no private submodules the step adds no credential and still fetches"
else
  echo "FAIL  the step added a credential, or lost the ssh rewrite, with no private submodules"; failures=1
fi
run_fetch "lib-one" preset
if grep -qx 'GIT_CONFIG_KEY_0=core.x' "$work/fetch.log" && grep -qx 'GIT_CONFIG_VALUE_0=kept' "$work/fetch.log" \
   && grep -qx 'GIT_CONFIG_KEY_1=url.https://github.com/.insteadOf' "$work/fetch.log"; then
  echo "ok    configuration already in the environment is kept, and the step's entries come after it"
else
  echo "FAIL  the step overwrote GIT_CONFIG entries that were already set"; failures=1
fi
run_fetch $'lib-one, lib-two\nlib-three'
if python3 -I - "$work/fetch.log" <<'PY'
import base64, re, sys
entries = {}
for line in open(sys.argv[1]):
    m = re.match(r"GIT_CONFIG_(KEY|VALUE)_(\d+)=(.*)$", line.rstrip("\n"))
    if m:
        entries.setdefault(int(m.group(2)), {})[m.group(1)] = m.group(3)
pairs = [(e["KEY"], e["VALUE"]) for _, e in sorted(entries.items())]
read = "AUTHORIZATION: basic " + base64.b64encode(b"x-access-token:READTOKEN").decode()
bad = []
for repo in ("lib-one", "lib-two", "lib-three"):
    for name in (repo, repo + ".git"):
        key = f"http.https://github.com/acme/{name}.extraheader"
        values = [v for k, v in pairs if k == key]
        if values != ["", read]:
            bad.append(f"{key}: expected an empty reset then the read header, got {values!r}")
for k, v in pairs:
    if k.startswith("http.") and not re.match(r"http\.https://github\.com/acme/lib-(one|two|three)(\.git)?\.extraheader$", k):
        bad.append(f"{k} is keyed on a broader URL than the listed repositories")
    if "READTOKEN" in v:
        bad.append("the token is in the clear")
print("\n".join("      " + b for b in bad))
sys.exit(1 if bad else 0)
PY
then
  echo "ok    each listed repository, with and without .git, gets a reset then the read header, and nothing wider"
else
  echo "FAIL  the read header is not scoped to the listed repositories"; failures=1
fi

echo "-- the step leaves each submodule at the pin the PR head records"
# A render has to see the PR's own submodule pin: a frame rendered against the old one reads as no change.
# These run the step with real git against scratch repositories, as it runs on a runner whose workspace
# may hold an earlier checkout of the same repository.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=Dev GIT_AUTHOR_EMAIL=dev@example.com GIT_COMMITTER_NAME=Dev GIT_COMMITTER_EMAIL=dev@example.com
sub="$work/sub"; super="$work/super"
git init -q -b main "$sub"
printf 'one\n' > "$sub/tokens.txt" && git -C "$sub" add -A && git -C "$sub" commit -q -m one && pin_old=$(git -C "$sub" rev-parse HEAD)
printf 'two\n' > "$sub/tokens.txt" && git -C "$sub" add -A && git -C "$sub" commit -q -m two && pin_new=$(git -C "$sub" rev-parse HEAD)
git init -q -b main "$super"
git -C "$super" -c protocol.file.allow=always submodule add -q "$sub" design > /dev/null 2>&1
git -C "$super/design" checkout -q "$pin_old"
git -C "$super" add -A && git -C "$super" commit -q -m "base pins the old design system"
git -C "$super" checkout -q -b pr
git -C "$super/design" checkout -q "$pin_new"
git -C "$super" add -A && git -C "$super" commit -q -m "bump the design system"
real_fetch() { # $1 = the working copy the step runs in
  ( cd "$1" && env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always \
      SUBMODULE_TOKEN=X PRIVATE_SUBMODULES="" OWNER=acme bash "$work/fetch/step.1" > "$work/real.log" 2>&1 )
}
at_pin() { [ "$(git -C "$1/design" rev-parse HEAD)" = "$pin_new" ] && [ "$(git -C "$1" ls-tree HEAD design | awk '{print $3}')" = "$pin_new" ]; }
# A fresh clone of the PR head.
rm -rf "$work/fresh" && git -c protocol.file.allow=always clone -q -b pr "$super" "$work/fresh" 2> /dev/null
if real_fetch "$work/fresh" && at_pin "$work/fresh"; then echo "ok    a fresh checkout of the head gets the new pin"; else echo "FAIL  a fresh checkout is not at the PR's pin: $(cat "$work/real.log")"; failures=1; fi
# A workspace that still holds the base's checkout, with the submodule at the old pin, moved to the head.
rm -rf "$work/stale" && git -c protocol.file.allow=always clone -q --recurse-submodules -b main "$super" "$work/stale" 2> /dev/null
git -C "$work/stale" -c protocol.file.allow=always fetch -q origin pr && git -C "$work/stale" checkout -q FETCH_HEAD
if [ "$(git -C "$work/stale/design" rev-parse HEAD)" = "$pin_old" ] && real_fetch "$work/stale" && at_pin "$work/stale"; then
  echo "ok    a workspace left at the old pin is moved to the new one"
else echo "FAIL  a stale submodule checkout stayed at the old pin: $(cat "$work/real.log")"; failures=1; fi
# The same, with an edit in the submodule that would block the checkout.
rm -rf "$work/dirty" && git -c protocol.file.allow=always clone -q --recurse-submodules -b main "$super" "$work/dirty" 2> /dev/null
git -C "$work/dirty" -c protocol.file.allow=always fetch -q origin pr && git -C "$work/dirty" checkout -q FETCH_HEAD
printf 'local\n' > "$work/dirty/design/tokens.txt"
if real_fetch "$work/dirty" && at_pin "$work/dirty" && [ "$(cat "$work/dirty/design/tokens.txt")" = "two" ]; then
  echo "ok    an edit left in the submodule does not keep the old pin"
else echo "FAIL  a modified submodule checkout blocked the move to the new pin: $(cat "$work/real.log")"; failures=1; fi

# A submodule that is still not at the recorded pin after the update fails the step instead of rendering.
mkdir -p "$work/bin-off"
cat > "$work/bin-off/git" <<'STUB'
#!/usr/bin/env bash
if [ "$1 $2" = "submodule status" ]; then echo "+0123456789abcdef0123456789abcdef01234567 design (heads/main)"; fi
exit 0
STUB
chmod +x "$work/bin-off/git"
if PATH="$work/bin-off:$PATH" SUBMODULE_TOKEN=X PRIVATE_SUBMODULES="" OWNER=acme bash "$work/fetch/step.1" > "$work/off.log" 2>&1; then
  echo "FAIL  a submodule at the wrong commit let the step pass"; failures=1
elif grep -q 'a submodule is not at the pin this commit records' "$work/off.log"; then
  echo "ok    a submodule that is not at the recorded pin fails the step and is named"
else echo "FAIL  the step failed without saying why: $(cat "$work/off.log")"; failures=1; fi

exit "$failures"
