#!/usr/bin/env bash
#
# Compares the newest stable release of each upstream with the version the calling repository
# says it last checked, and opens one issue per upstream: for the newest release, naming any
# releases between that and the checked one.
#
# Environment: UPSTREAMS (JSON), STATE_FILE, LABEL, DRY_RUN, REPO, GH_TOKEN. GITHUB_OUTPUT and
# GITHUB_STEP_SUMMARY are written when set.
#
# Every upstream is processed even after one fails, so one broken tag does not hide a release of
# another; the run then fails. It must not guess a version: a stable tag that is not exactly
# [v]<MAJOR>.<MINOR> or [v]<MAJOR>.<MINOR>.<PATCH> is an error, never skipped. Jellyfin tags v12.4,
# and v10.11.11 too. A missing patch compares as 0, but the version is kept as the upstream wrote it.
export GH_REPO="${REPO:-}"
set -euo pipefail

: "${UPSTREAMS:?UPSTREAMS is required}"
: "${REPO:?REPO is required}"
STATE_FILE=${STATE_FILE:-docs/upstream.json}
LABEL=${LABEL:-upstream}
DRY_RUN=${DRY_RUN:-false}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
out=${GITHUB_OUTPUT:-/dev/null}

version_re='^[0-9]+\.[0-9]+(\.[0-9]+)?$'
tag_re='^v?[0-9]+\.[0-9]+(\.[0-9]+)?$'

errors=()
lines=()
opened='[]'
newest='{}'

report() {
  {
    echo "### Upstream watch"
    printf '%s\n' "${lines[@]+"${lines[@]}"}"
    if [ "${#errors[@]}" -gt 0 ]; then
      echo
      echo "**Failures**"
      printf -- '- %s\n' "${errors[@]}"
    fi
  } >> "$summary"
  echo "opened=$opened" >> "$out"
  echo "newest=$newest" >> "$out"
}
# The summary and outputs are written whatever happens, a failure included.
trap report EXIT

fail() { # $1=upstream  $2=what went wrong
  errors+=("$1: $2")
  echo "::error::$1: $2"
}

# Dotted versions as sortable text: 10.11.6 -> 000010.000011.000006, and 12.4 -> 000012.000004.000000.
sortable() { awk -F. '{ printf "%06d.%06d.%06d\n", $1, $2, $3 + 0 }' <<<"$1"; }

# Whether $1 is a newer version than $2.
newer() { [ "$(sortable "$1")" \> "$(sortable "$2")" ]; }

ensure_label() {
  [ "$DRY_RUN" != "true" ] || return 0
  local names
  names=$(gh label list --limit 1000 --json name --jq '.[].name')
  grep -qixF -- "$LABEL" <<<"$names" || gh label create "$LABEL" --description "A server the apps use shipped a release" >/dev/null
}

issue_body() { # $1=name $2=version $3=checked $4=release json $5=skipped releases json (array)
  local url notes fence='~~~~~~~~~~' skipped=''
  url=$(jq -r '.html_url' <<<"$4")
  # Release notes are quoted as code so an @mention in them notifies nobody here.
  notes=$(jq -r '(.body // "")[0:6000]' <<<"$4" | grep -vF "$fence" || true)
  if [ "$(jq 'length' <<<"$5")" -gt 0 ]; then
    skipped=$(jq -r '"### Also released since " + $c + "\n\nThis issue covers " + $v + ". These came out in between, newest first, and are covered by the same check:\n\n" + ([.[] | "- [" + (.tag_name | ltrimstr("v")) + "](" + .html_url + ")"] | join("\n")) + "\n"' \
      --arg c "$3" --arg v "$2" <<<"$5")
  fi
  cat <<BODY
<!-- upstream-watch:$1:$2 -->
$1 $2 is out, and this repository was last checked against $3.

- Release: $url
- Last checked: $3
- Newest stable: $2

$skipped

### Release notes

<details><summary>Notes for $2 (cut at 6000 characters)</summary>

$fence
$notes
$fence

</details>

### Checklist

- [ ] Upgrade a disposable test server to $2.
- [ ] Run the device checks and the settings sweep against it.
- [ ] Read the release notes for API changes and removed options, for $2 and any release listed above.
- [ ] Update the server-compatibility notes and the feature gates if anything moved.
- [ ] Bump \`$1.checked\` to \`$2\` in \`$STATE_FILE\` in a PR that closes this issue.
BODY
}

# Every issue this workflow has opened, in any state, read once. By label, not by a title search: a
# person renames an issue, and only the marker in its body still names the release. A failed read
# is an error, never "no issues", or a rate limit would open a duplicate.
issues_json=''
load_issues() {
  [ -n "$issues_json" ] && return 0
  local out
  out=$(gh issue list --state all --label "$LABEL" --limit 1000 --json title,body) || return 1
  jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1 || return 1
  issues_json=$out
}

# Whether an issue for this release exists, by its generated title or by the marker in its body.
# Returns 0 for yes, 1 for no, 2 when the issues could not be read.
exists() { # $1=name $2=version $3=title
  load_issues || return 2
  jq -e --arg t "$3" --arg m "<!-- upstream-watch:$1:$2 -->" \
    'any(.[]; .title == $t or ((.body // "") | contains($m)))' <<<"$issues_json" >/dev/null
}

process() { # $1=name $2=repo
  local name=$1 repo=$2 checked releases bad eligible top
  checked=$(jq -r --arg n "$name" '.[$n].checked // empty' "$STATE_FILE")
  if [ -z "$checked" ]; then
    fail "$name" "no \"checked\" version in $STATE_FILE. Add \`\"$name\": {\"checked\": \"X.Y\"}\` for the version last reviewed."
    return 1
  fi
  if ! [[ $checked =~ $version_re ]]; then
    fail "$name" "checked version \"$checked\" in $STATE_FILE is not MAJOR.MINOR or MAJOR.MINOR.PATCH (no leading v)."
    return 1
  fi
  if ! releases=$(gh api "repos/$repo/releases?per_page=30"); then
    fail "$name" "could not list releases of $repo."
    return 1
  fi
  eligible=$(jq -c '[.[] | select(.draft == false and .prerelease == false)]' <<<"$releases")
  bad=$(jq -r --arg re "$tag_re" '.[] | select(.tag_name | test($re) | not) | .tag_name' <<<"$eligible")
  if [ -n "$bad" ]; then
    fail "$name" "stable release tag(s) of $repo not in the form [v]MAJOR.MINOR or [v]MAJOR.MINOR.PATCH: $(tr '\n' ' ' <<<"$bad")"
    return 1
  fi
  top=$(jq -r '.[].tag_name | ltrimstr("v")' <<<"$eligible" | while read -r v; do echo "$(sortable "$v") $v"; done | sort | tail -n 1 | cut -d' ' -f2)
  if [ -z "$top" ]; then
    fail "$name" "no stable release among the latest 30 of $repo."
    return 1
  fi
  newest=$(jq -c --arg n "$name" --arg v "$top" '. + {($n): $v}' <<<"$newest")

  local pending
  pending=$(jq -r '.[].tag_name | ltrimstr("v")' <<<"$eligible" | while read -r v; do
    if newer "$v" "$checked"; then echo "$(sortable "$v") $v"; fi
  done | sort | cut -d' ' -f2)
  if [ -z "$pending" ]; then
    lines+=("- $name: $top is the newest stable, checked $checked. Nothing to do.")
    return 0
  fi

  # One issue, for the newest release. The ones between it and `checked` are listed in its body, so a
  # first run against an old baseline is one issue rather than a dozen.
  local v title release skipped seen=0
  v=$(tail -n 1 <<<"$pending")
  title="$name $v: new upstream release"
  exists "$name" "$v" "$title" || seen=$?
  if [ "$seen" -eq 0 ]; then
    lines+=("- $name $v: an issue exists already. Skipped.")
    return 0
  elif [ "$seen" -ne 1 ]; then
    fail "$name" "could not list the \`$LABEL\` issues to look for $v, so none was opened."
    return 1
  fi
  if [ "$DRY_RUN" = "true" ]; then
    lines+=("- $name $v: would open \"$title\", naming $(($(wc -l <<<"$pending") - 1)) release(s) in between.")
    opened=$(jq -c --arg e "$name@$v" '. + [$e]' <<<"$opened")
    return 0
  fi
  release=$(jq -c --arg v "$v" '.[] | select((.tag_name | ltrimstr("v")) == $v)' <<<"$eligible" | head -n 1)
  # Newest first by version, not in the API's order.
  skipped=$(tac <<<"$pending" | sed 1d | while read -r sv; do
    jq -c --arg v "$sv" '.[] | select((.tag_name | ltrimstr("v")) == $v)' <<<"$eligible" | head -n 1
  done | jq -sc '.')
  if issue_body "$name" "$v" "$checked" "$release" "$skipped" > "$bodyfile" \
     && gh issue create --title "$title" --label "$LABEL" --body-file "$bodyfile" >/dev/null; then
    lines+=("- $name $v: opened \"$title\".")
    opened=$(jq -c --arg e "$name@$v" '. + [$e]' <<<"$opened")
  else
    fail "$name" "could not open the issue for $v."
    return 1
  fi
}

# --- validate the inputs ---
if ! jq -e 'type == "array" and length > 0 and all(.[]; type == "object")' <<<"$UPSTREAMS" >/dev/null 2>&1; then
  fail inputs "upstreams must be a non-empty JSON array of {\"name\", \"repo\"} objects."
  exit 1
fi
[ -f "$STATE_FILE" ] || { fail inputs "state file $STATE_FILE does not exist. Create it with the version last checked per upstream."; exit 1; }
jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>&1 || { fail inputs "$STATE_FILE is not a JSON object."; exit 1; }

rows=$(jq -r '.[] | [(.name // ""), (.repo // "")] | @tsv' <<<"$UPSTREAMS")
dupes=$(cut -f1 <<<"$rows" | sort | uniq -d)
[ -z "$dupes" ] || { fail inputs "upstream name(s) repeated: $(tr '\n' ' ' <<<"$dupes")"; exit 1; }
while IFS=$'\t' read -r name repo; do
  if ! [[ $name =~ ^[a-z0-9-]+$ ]] || ! [[ $repo =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    fail inputs "bad upstream: name \"$name\" must match [a-z0-9-]+ and repo \"$repo\" must be owner/repo."
    exit 1
  fi
done <<<"$rows"

bodyfile=$(mktemp)
trap 'rm -f "$bodyfile"; report' EXIT
ensure_label

status=0
while IFS=$'\t' read -r name repo; do
  process "$name" "$repo" || status=1
done <<<"$rows"

if [ "$status" -ne 0 ]; then
  exit 1
fi
