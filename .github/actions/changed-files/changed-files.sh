#!/usr/bin/env bash
# Writes `product`, `screens` and `release` to $OUT for the diff this run has to vouch for.
#
# Everything is true unless the event is a pull request and a baseline is found. The baseline is the
# last commit of this PR that a whole run passed on, when it is an ancestor of this head: what changed
# since is all that run has to vouch for, and each skip is of a delta that cannot reach the job. Without
# one, or after a force push, it is the merge base with the base branch, which is the PR's own files.
# `HEAD` on a pull request is GitHub's merge commit, so the delta also holds what the base branch gained
# since the fork point. That covers a semantic merge conflict; do not switch to the PR head SHA to save runs.
#
# A rename is listed as a deletion and an addition (`--no-renames`), since `--name-only` alone prints only
# the new path and a source file moved into a set that cannot reach a job would hide the path it left.
#
# This runs with `-e` off around everything that can fail for a reason outside the diff (a run list that
# cannot be read, a fetch that fails) because the answer to all of them is the same: run everything. A
# wrong skip is the only costly error here, a wasted run is not.
set -uo pipefail

: "${OUT:?}" "${EVENT:?}"
summary="${SUMMARY:-/dev/null}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"

all() {
  printf 'product=true\nscreens=true\nrelease=true\n' >> "$OUT"
  echo "$1: running everything." >> "$summary"
  echo "$1: running everything." >&2
  exit 0
}

[ "$EVENT" = pull_request ] || all "Not a pull request"

head="$(git rev-parse HEAD 2>/dev/null)" || all "No commit to diff"
base=""
label=""
# A fork's branch name is not ours, so a fork PR never borrows a green run.
if [ "${SAME_REPO:-false}" = true ] && [ -n "${HEAD_REF:-}" ]; then
  green="$(gh run list --workflow "${WORKFLOW:-ci.yml}" --branch "$HEAD_REF" --event pull_request --status success --limit 5 \
    --json headSha,databaseId -q '.[] | "\(.headSha) \(.databaseId)"' 2>/dev/null || true)"
  while read -r sha run_id; do
    [ -n "$sha" ] || continue
    # A draft's run skips every job, the gate job too, and may still conclude success: only a run whose
    # gate job itself succeeded vouches for its commit.
    built="$(gh api "repos/${REPOSITORY:?}/actions/runs/$run_id/jobs?per_page=100" \
      -q "[.jobs[] | select(.name == \"${GREEN_JOB:-build}\" and .conclusion == \"success\")] | length" 2>/dev/null || echo 0)"
    [ "${built:-0}" -gt 0 ] 2>/dev/null || continue
    if [ "$sha" != "$head" ] && git cat-file -e "$sha^{commit}" 2>/dev/null && git merge-base --is-ancestor "$sha" "$head" 2>/dev/null; then
      base="$sha"
      label="its last green run ($sha)"
      break
    fi
  done <<< "$green"
fi
if [ -z "$base" ]; then
  git fetch --no-tags origin "${BASE_REF:-}" > /dev/null 2>&1 || true
  base="$(git merge-base "origin/${BASE_REF:-}" "$head" 2>/dev/null || true)"
  label="the merge base ($base)"
fi
[ -n "$base" ] || all "No baseline to diff against"

git diff --no-renames --name-only "$base" "$head" > "$tmp/changed.txt" 2>/dev/null || all "The diff could not be read"

set -e
bash "$here/classify-changes.sh" "$tmp/changed.txt" | tee -a "$OUT"
{
  echo "Diff against $label:"
  echo '```'
  cat "$tmp/changed.txt"
  echo '```'
} >> "$summary"
