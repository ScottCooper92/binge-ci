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
$(mint '        ' '' REVIEWER_APP_ID '')"
expect whole-installation pass

fixture not-granted "      - name: Mint
$(mint '        ' '' AUTHOR_APP_ID 'contents issues')"
expect not-granted fail "permission-issues is not granted to the AUTHOR_APP_ID installation"

fixture unknown-app "      - name: Mint
$(mint '        ' '' REVIEWER_APP_ID 'contents')"
expect unknown-app fail "its app (REVIEWER_APP_ID) has no grant recorded"

# A step opened by `- uses:` ends at the next step's dash, which sits at the same column. Read past
# it, and the next step's app and permissions are taken for this one's: here, the reviewer mint
# would be judged as the author's and pass.
fixture dash-uses-then-step "$(mint '      ' '- ' REVIEWER_APP_ID 'contents')
      - name: Next
$(mint '        ' '' AUTHOR_APP_ID 'contents')"
expect dash-uses-then-step fail "its app (REVIEWER_APP_ID) has no grant recorded"

fixture dash-uses-blames-own-app "$(mint '      ' '- ' REVIEWER_APP_ID 'issues')
      - name: Next
$(mint '        ' '' AUTHOR_APP_ID 'contents')"
expect dash-uses-blames-own-app fail "its app (REVIEWER_APP_ID) has no grant recorded"

# A step whose `with:` comes before its `uses:` still has its app and permissions read.
fixture with-before-uses "      - name: Mint
        with:
          app-id: \${{ secrets.AUTHOR_APP_ID }}
          permission-issues: read
        uses: actions/create-github-app-token@0000000000000000000000000000000000000000 # v2"
expect with-before-uses fail "permission-issues is not granted to the AUTHOR_APP_ID installation"

fixture no-mints "      - run: 'true'"
expect no-mints fail "No create-github-app-token step found"

exit "$failures"
