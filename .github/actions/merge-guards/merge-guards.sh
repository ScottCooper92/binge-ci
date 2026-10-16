#!/usr/bin/env bash
#
# The merge guards that bot-review's merge gate and its release-held sweep both apply. One copy,
# because two drift: a new exemption or marker added to one and not the other makes the sweep merge
# a PR the gate would hold, or the reverse.
#
# Each subcommand answers one question and prints its answer; the caller decides what to say and
# whether to hold. An API error exits non-zero and prints nothing, so a caller under `set -e` fails
# closed, as every other guard in both jobs does.
#
#   merge-guards.sh method <merge_method>
#       Exits non-zero unless it is squash, merge or rebase.
#   merge-guards.sh governed <pr>
#       Prints `yes` when a bot comment carries the governed-merged marker, else `no`.
#   merge-guards.sh feedback <pr> <since>
#       Prints `changes-requested` when a human's latest verdict requests changes, `newer` when a
#       human left feedback after <since> (an ISO 8601 timestamp), else nothing.
#   merge-guards.sh files <pr>
#       Prints every path the PR changes, one per line, with both sides of a rename. Paginated
#       REST, because `gh pr view --json files` stops at 100 files, and a rename's old path is a
#       change CI sees too: moving a source file into docs/ is not a docs-only change.
#   merge-guards.sh buildable <regex>
#       Reads paths on stdin and prints those the regex does not match: the ones CI would build,
#       given the regex form of the caller's paths-ignore. Nothing printed means none.
#   merge-guards.sh merge <pr> <merge_method> <head_sha>
#       Merges with the PR's title and body as the commit message, only if the head is still
#       <head_sha>. gh's own output and exit status pass through.
#
# Reads GH_REPO and GH_TOKEN from the environment, as gh does. Every gh call goes through
# gh-retry.sh, so a merge whose connection never opened is tried again, still matched to <head_sha>.
set -euo pipefail

: "${GH_REPO:?GH_REPO must be set}"

# shellcheck source=gh-retry.sh
. "$(dirname "${BASH_SOURCE[0]}")/gh-retry.sh"

method() {
  case "${1:-}" in
    squash|merge|rebase) ;;
    *) echo "::error::merge_method must be squash, merge or rebase - got '${1:-}'." >&2; exit 1 ;;
  esac
}

# Bot-authored comments only: the marker is a literal string, so a review quoting it or a maintainer
# asking what it does would otherwise park the PR for good. The read is separate from the test of
# it: folding a failed read into the same "no" a clean read gives is how a 502 once read as "no bot
# touched a governed path" and merged.
governed() {
  local pr=$1 bot_comments
  bot_comments=$(gh api "repos/${GH_REPO}/issues/${pr}/comments?per_page=100" \
    --paginate --jq '.[] | select(.user.type == "Bot") | .body')
  if grep -q -- '<!-- governed-merged -->' <<<"$bot_comments"; then echo yes; else echo no; fi
}

feedback() {
  local pr=$1 since=$2 blocks newer n endpoint answered

  # --paginate is load-bearing: /reviews pages at 30, oldest first, so a CHANGES_REQUESTED past the
  # first page would be invisible and the merge would go straight through it.
  #
  # Only the LATEST review per person counts, as GitHub's own merge box does - otherwise a
  # maintainer who requests changes, gets them fixed and then approves leaves a block that can
  # never clear. COMMENTED is dropped first: it does not supersede a prior verdict.
  blocks=$(gh api "repos/${GH_REPO}/pulls/${pr}/reviews?per_page=100" --paginate \
    --jq '.[] | select(.user.type != "Bot") | select(.state != "COMMENTED")
              | {login: .user.login, state: .state, at: .submitted_at}' \
    | jq -s '[group_by(.login)[] | (sort_by(.at) | last)
              | select(.state == "CHANGES_REQUESTED")] | length')
  if [ "$blocks" != "0" ]; then echo changes-requested; return 0; fi

  # Anything a human left after <since> is unaddressed by definition, and it lands in three places.
  # Reading only the third is how a review carrying inline objections gets merged over: a COMMENTED
  # review lives in /reviews, its inline notes in the review threads, and only top-level chat in
  # /issues/{n}/comments.
  #
  # These page at 30, oldest first, so unpaginated the newest feedback - the only kind this guard
  # exists to find - is the first thing off the end. --jq runs once per page, hence the awk sum.
  #
  # Two exemptions, on different grounds. `<!-- answered -->` is a top-level comment's counterpart
  # to resolving a thread, since it has no resolved state of its own: without it, answering the
  # reviewer bot parked the PR until unrelated code happened to be pushed. It is set deliberately,
  # per comment, and reviews do not honour it - a review body is the objection itself, not a note
  # about one.
  #
  # The Claude Code footer is exempt because an agent session posts as the repo owner, so
  # `author_association` reads OWNER and this guard cannot tell its comments from a maintainer's -
  # which collides with the convention that REQUIRES a comment when standing down on a CI failure
  # that is not the PR's own. It keys on a signal already mandated on every agent-authored comment.
  # A human who pastes it is skipped too, and that fails safe: the only consequence is a merge the
  # reviewer had already approved.
  newer=0
  for endpoint in "pulls/${pr}/reviews" "issues/${pr}/comments"; do
    # Both exemptions are markers anyone can paste, so they exempt a comment only when its author
    # could have been trusted without them: a maintainer or collaborator by association. A drive-by
    # comment carrying the marker holds the merge like any other.
    answered='select(true)'
    if [ "$endpoint" = "issues/${pr}/comments" ]; then
      answered='select(
                  (((.body // "") | test("<!--\\s*answered\\s*-->"))
                    or ((.body // "") | test("Generated by \\[Claude Code\\]")))
                  and ((.author_association // "") | IN("OWNER", "MEMBER", "COLLABORATOR"))
                  | not)'
    fi
    n=$(gh api "repos/${GH_REPO}/${endpoint}?per_page=100" --paginate \
      --jq "[.[]
             | select(.user.type != \"Bot\")
             | select(.state != \"APPROVED\")
             | select((.submitted_at // .created_at) > \"$since\")
             | $answered] | length" \
      | awk '{ s += $1 } END { print s + 0 }')
    newer=$((newer + ${n:-0}))
  done

  # Inline notes are counted by THREAD, not by comment, which is why they come from GraphQL. A
  # thread's RESOLVED state is the question: resolved means addressed, whoever resolved it, and an
  # unresolved thread counts however its newest comment is shaped. Counting replies instead
  # penalised the reviews that were ANSWERED - push the fix, say so on the thread, and that reply is
  # always newer than the head - while exempting replies let a reviewer's escalation on their own
  # thread go unseen.
  #
  # `isResolved` is GraphQL-only, absent from the REST payload, which is why this reads differently
  # from the two endpoints above.
  #
  # The one case this misses is a reply added to an already-resolved thread and left resolved.
  # Telling that apart needs a resolution timestamp, and the published schema has none: `resolvedAt`
  # is on no type, the timeline carries the thread but no resolve event, and `resolvedBy` says who
  # and never when. Un-resolving is the affordance for reopening a point, and a reviewer who does
  # that is counted again here.
  n=$(gh api graphql --paginate \
    -f owner="${GH_REPO%%/*}" -f name="${GH_REPO##*/}" -F pr="$pr" \
    -f query='
      query($owner: String!, $name: String!, $pr: Int!, $endCursor: String) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $pr) {
            reviewThreads(first: 100, after: $endCursor) {
              pageInfo { hasNextPage endCursor }
              nodes {
                isResolved
                comments(first: 100) { nodes { createdAt author { __typename } } }
              }
            }
          }
        }
      }' \
    --jq "[.data.repository.pullRequest.reviewThreads.nodes[]
           | select(.isResolved | not)
           | .comments.nodes[]
           | select((.author.__typename // \"\") != \"Bot\")
           | select(.createdAt > \"$since\")] | length" \
    | awk '{ s += $1 } END { print s + 0 }')
  newer=$((newer + ${n:-0}))

  if [ "$newer" != "0" ]; then echo newer; fi
}

files() {
  gh api "repos/${GH_REPO}/pulls/$1/files?per_page=100" --paginate \
    --jq '.[] | .filename, (.previous_filename // empty)'
}

# The regex reaches jq as a value, not as source text: spliced into a program, a caller's `\.md$`
# is an invalid escape inside a jq string literal. jq rather than grep -E, so `\d` and the other
# extensions mean what they did under gh's own --jq.
buildable() {
  jq -R -r --arg re "$1" 'select(length > 0) | select(test($re) | not)'
}

merge() {
  local pr=$1 merge_method=$2 head=$3 view message=()
  method "$merge_method"
  # GitHub ignores a commit title and message on a REBASE merge, and gh sends them anyway - there is
  # no validation in cli/cli rejecting the pair, so they go into the payload and are dropped
  # server-side. Passing them only where they mean something keeps the command honest about what
  # it is asking for.
  if [ "$merge_method" != "rebase" ]; then
    view=$(gh pr view "$pr" --json title,body)
    message=(--subject "$(jq -r .title <<<"$view") (#$pr)" --body "$(jq -r .body <<<"$view")")
  fi
  # --match-head-commit: the guards above are minutes old by the time this runs, and the author
  # bots push unattended. GitHub refuses the merge when the head is no longer the commit the review
  # and the CI run were for.
  gh pr merge "$pr" "--${merge_method}" --match-head-commit "$head" "${message[@]}"
}

cmd=${1:-}
shift || true
case "$cmd" in
  method) method "$@" ;;
  governed) [ "$#" -eq 1 ] || { echo "usage: $0 governed <pr>" >&2; exit 2; }; governed "$@" ;;
  feedback) [ "$#" -eq 2 ] || { echo "usage: $0 feedback <pr> <since>" >&2; exit 2; }; feedback "$@" ;;
  files) [ "$#" -eq 1 ] || { echo "usage: $0 files <pr>" >&2; exit 2; }; files "$@" ;;
  buildable) [ "$#" -eq 1 ] || { echo "usage: $0 buildable <regex>" >&2; exit 2; }; buildable "$@" ;;
  merge) [ "$#" -eq 3 ] || { echo "usage: $0 merge <pr> <merge_method> <head_sha>" >&2; exit 2; }; merge "$@" ;;
  *) echo "usage: $0 {method|governed|feedback|files|buildable|merge} ..." >&2; exit 2 ;;
esac
