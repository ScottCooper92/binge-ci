#!/usr/bin/env bash
#
# Runs the upstream-watch script against a stubbed `gh`, one case per outcome it has to tell apart:
# a newer stable release, an equal or older one, drafts and prereleases, an unparsable tag, a
# missing state entry, a duplicate (open or closed), a dry run, and numeric rather than text order
# (10.9 against 10.11). Also holds the workflow to the properties its safety rests on. The real
# releases API needs the network, and a change here would otherwise surface only in a consumer.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/.github/actions/upstream-watch/upstream-watch.sh"
workflow="$root/.github/workflows/upstream-watch.yml"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
pass() { echo "ok    $1"; }

mkdir "$work/bin"
# The stub serves releases from $FAKE/releases/<owner>__<repo>.json and issues from
# $FAKE/issues.json, and records each `issue create` in $FAKE/created.log with its body kept.
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ -n "${GH_TOKEN:-}" ] || { echo "stub: no token" >&2; exit 3; }
case "$1 $2" in
  "api repos/"*)
    path=${2#repos/}; repo=${path%%/releases*}
    file="$FAKE/releases/${repo/\//__}.json"
    [ -f "$file" ] || { echo "HTTP 404" >&2; exit 1; }
    cat "$file" ;;
  "label list") printf '%s\n' "$FAKE_LABELS" ;;
  "label create") echo "label $3" >> "$FAKE/created.log" ;;
  "issue list")
    [ -z "${FAKE_ISSUES_FAIL:-}" ] || { echo "HTTP 502" >&2; exit 1; }
    # Honours the query the script sends: --label keeps issues carrying it, and a --search phrase
    # keeps issues whose title contains it, as the real `in:title` search does.
    label=''; phrase=''
    while [ $# -gt 0 ]; do
      case $1 in --label) label=$2 ;; --search) phrase=${2%\" in:title}; phrase=${phrase#\"} ;; esac
      shift
    done
    jq --arg l "$label" --arg p "$phrase" \
      '[.[] | select(($l == "" or ((.labels // []) | index($l))) and ($p == "" or (.title | contains($p))))]' "$FAKE/issues.json" ;;
  "issue create")
    title=''; body=''
    shift 2
    while [ $# -gt 0 ]; do
      case $1 in --title) title=$2; shift ;; --body-file) body=$2; shift ;; esac
      shift
    done
    n=$(grep -c '^issue ' "$FAKE/created.log" 2>/dev/null || true)
    cp "$body" "$FAKE/body-$n.md"
    echo "issue $title" >> "$FAKE/created.log" ;;
  *) echo "stub: unexpected: $*" >&2; exit 4 ;;
esac
STUB
chmod +x "$work/bin/gh"

# release <tag> [prerelease] [draft] [body]
release() {
  jq -n --arg t "$1" --argjson p "${2:-false}" --argjson d "${3:-false}" --arg b "${4:-notes for $1}" \
    '{tag_name: $t, prerelease: $p, draft: $d, body: $b, html_url: ("https://github.com/x/y/releases/tag/" + $t)}'
}
releases_file() { # $1=owner__repo, rest: release objects
  local f=$1; shift
  jq -s '.' <(printf '%s\n' "$@") > "$FAKE/releases/$f.json"
}

# run_case <label> <expected exit> <state json> <upstreams json> [DRY_RUN]
run_case() {
  local label=$1 want=$2 state=$3 ups=$4 dry=${5:-false} rc=0
  : > "$FAKE/created.log"; rm -f "$FAKE"/body-*.md
  printf '%s' "$state" > "$FAKE/state.json"
  : > "$FAKE/summary.md"; : > "$FAKE/output.txt"
  env PATH="$work/bin:$PATH" FAKE="$FAKE" FAKE_LABELS="${FAKE_LABELS-upstream}" GH_TOKEN=t REPO=o/r \
    UPSTREAMS="$ups" STATE_FILE="$FAKE/state.json" LABEL=upstream DRY_RUN="$dry" \
    GITHUB_STEP_SUMMARY="$FAKE/summary.md" GITHUB_OUTPUT="$FAKE/output.txt" \
    bash "$script" > "$FAKE/stdout.txt" 2>&1 || rc=$?
  if [ "$rc" -ne "$want" ]; then
    fail "$label: exit $rc, wanted $want"; sed 's/^/        /' "$FAKE/stdout.txt"
    return 1
  fi
}
created() { grep -c '^issue ' "$FAKE/created.log" || true; }
expect() { # $1=label $2=condition result
  if eval "$2"; then pass "$1"; else fail "$1"; sed 's/^/        /' "$FAKE/stdout.txt"; fi
}

FAKE="$work/fake"; mkdir -p "$FAKE/releases"
echo '[]' > "$FAKE/issues.json"
J='[{"name":"jellyfin","repo":"jellyfin/jellyfin"}]'

releases_file jellyfin__jellyfin "$(release v10.11.6)" "$(release v10.11.5)" "$(release v10.9.11)" "$(release v10.12.0-rc1 true)" "$(release v10.13.0 false true)"
if run_case "a newer stable opens one issue" 0 '{"jellyfin":{"checked":"10.11.5"}}' "$J"; then
  expect "  one issue, titled with server and version" '[ "$(created)" = 1 ] && grep -q "^issue jellyfin 10.11.6: new upstream release$" "$FAKE/created.log"'
  expect "  prerelease and draft are not the newest" 'grep -q "^newest=" "$FAKE/output.txt" && grep -qx "newest={\"jellyfin\":\"10.11.6\"}" "$FAKE/output.txt"'
  expect "  body has the marker and the checklist" 'grep -q "<!-- upstream-watch:jellyfin:10.11.6 -->" "$FAKE/body-0.md" && grep -q "Upgrade a disposable test server" "$FAKE/body-0.md"'
  expect "  opened output names it" 'grep -qx "opened=\[\"jellyfin@10.11.6\"\]" "$FAKE/output.txt"'
fi

if run_case "equal to checked opens nothing" 0 '{"jellyfin":{"checked":"10.11.6"}}' "$J"; then
  expect "  none opened" '[ "$(created)" = 0 ]'
fi
if run_case "checked ahead of newest opens nothing" 0 '{"jellyfin":{"checked":"10.12.0"}}' "$J"; then
  expect "  none opened" '[ "$(created)" = 0 ]'
fi
if run_case "10.11 is newer than 10.9 (numeric order)" 0 '{"jellyfin":{"checked":"10.9.11"}}' "$J"; then
  expect "  opens 10.11.5 and 10.11.6, oldest first" '[ "$(created)" = 2 ] && [ "$(grep "^issue " "$FAKE/created.log" | sed -n 1p)" = "issue jellyfin 10.11.5: new upstream release" ]'
fi

# An existing issue, open or closed, stops a duplicate; a stranger's title match does not.
echo '[{"title":"jellyfin 10.11.6: new upstream release","body":"x","labels":["upstream"]}]' > "$FAKE/issues.json"
if run_case "a duplicate by title is skipped" 0 '{"jellyfin":{"checked":"10.11.5"}}' "$J"; then
  expect "  none opened" '[ "$(created)" = 0 ]'
fi
echo '[{"title":"Jellyfin 10.11.6 compatibility","body":"<!-- upstream-watch:jellyfin:10.11.6 -->","labels":["upstream"]}]' > "$FAKE/issues.json"
if run_case "a duplicate by marker is skipped" 0 '{"jellyfin":{"checked":"10.11.5"}}' "$J"; then
  expect "  none opened" '[ "$(created)" = 0 ]'
fi
echo '[{"title":"jellyfin 10.11.60: new upstream release","body":"<!-- upstream-watch:jellyfin:10.11.60 -->","labels":["upstream"]}]' > "$FAKE/issues.json"
if run_case "another version's issue is not a duplicate" 0 '{"jellyfin":{"checked":"10.11.5"}}' "$J"; then
  expect "  one opened" '[ "$(created)" = 1 ]'
fi
# A lookup that fails must not read as "no issue": nothing is opened and the run fails.
echo '[]' > "$FAKE/issues.json"
if FAKE_ISSUES_FAIL=1 run_case "a failed issue lookup opens nothing and fails" 1 '{"jellyfin":{"checked":"10.11.5"}}' "$J"; then
  expect "  none opened" '[ "$(created)" = 0 ]'
  expect "  the summary says why" 'grep -q "could not list" "$FAKE/summary.md"'
fi

if run_case "dry run opens nothing and reports" 0 '{"jellyfin":{"checked":"10.11.5"}}' "$J" true; then
  expect "  nothing created" '[ "$(created)" = 0 ]'
  expect "  summary says would open" 'grep -q "would open" "$FAKE/summary.md"'
fi

if FAKE_LABELS=other run_case "a missing label is created" 0 '{"jellyfin":{"checked":"10.11.5"}}' "$J"; then
  expect "  label created" 'grep -q "^label upstream$" "$FAKE/created.log"'
fi

# Failures: loud, never skipped, and the other upstreams still run.
releases_file jellyfin__jellyfin "$(release v10.11.6)" "$(release 10.11.7)"
if run_case "an unparsable stable tag fails" 1 '{"jellyfin":{"checked":"10.11.5"}}' "$J"; then
  expect "  names the tag" 'grep -q "10.11.7" "$FAKE/stdout.txt"'
  expect "  opens nothing for it" '[ "$(created)" = 0 ]'
fi
releases_file jellyfin__jellyfin "$(release v10.11.6)" "$(release v10.11.7-rc1)"
run_case "a suffixed stable tag fails" 1 '{"jellyfin":{"checked":"10.11.5"}}' "$J" || true
releases_file jellyfin__jellyfin "$(release v10.11.6)"
run_case "a missing state entry fails" 1 '{}' "$J" || true
run_case "a checked version with a v fails" 1 '{"jellyfin":{"checked":"v10.11.5"}}' "$J" || true
run_case "a missing state file fails" 1 '{}' "$J" || true
rm -f "$FAKE/releases/seerr-team__seerr.json"
TWO='[{"name":"seerr","repo":"seerr-team/seerr"},{"name":"jellyfin","repo":"jellyfin/jellyfin"}]'
if run_case "one upstream failing still processes the next" 1 '{"seerr":{"checked":"3.5.0"},"jellyfin":{"checked":"10.11.5"}}' "$TWO"; then :; fi
expect "  the good one still opened its issue" '[ "$(created)" = 1 ]'
expect "  the failure is in the summary" 'grep -q "seerr" "$FAKE/summary.md" && grep -q "Failures" "$FAKE/summary.md"'
releases_file jellyfin__jellyfin
run_case "no stable release at all fails" 1 '{"jellyfin":{"checked":"10.11.5"}}' "$J" || true

run_case "a repeated name fails" 1 '{}' '[{"name":"a","repo":"o/a"},{"name":"a","repo":"o/b"}]' || true
run_case "a bad repo fails" 1 '{}' '[{"name":"a","repo":"not a repo"}]' || true
run_case "an empty list fails" 1 '{}' '[]' || true
run_case "not JSON fails" 1 '{}' 'jellyfin' || true

# Release notes are quoted as code, so an @mention in them notifies nobody.
releases_file jellyfin__jellyfin "$(release v10.11.6 false false $'thanks @someone\n~~~~~~~~~~\n@other')"
if run_case "notes are fenced" 0 '{"jellyfin":{"checked":"10.11.5"}}' "$J"; then
  expect "  the notes sit between fences and a fence in them is dropped" \
    '[ "$(grep -cx "~~~~~~~~~~" "$FAKE/body-0.md")" = 2 ] && grep -q "^thanks @someone" "$FAKE/body-0.md"'
fi

# The workflow's own properties. The logic is in the action, so the workflow has no shell of its own
# to interpolate an expression into.
if grep -qE '^\s+run:' "$workflow"; then fail "upstream-watch.yml has a run: block; the logic belongs in the action"; else pass "the workflow has no run: block"; fi
grep -q 'issues: write' "$workflow" && pass "the workflow asks for issues: write" || fail "the workflow does not declare issues: write"
grep -qE 'secrets:' "$workflow" && fail "the workflow declares secrets, which it must not need" || pass "no secrets declared"

echo
if [ "$failures" -ne 0 ]; then echo "$failures case(s) failed"; exit 1; fi
echo "all cases passed"
