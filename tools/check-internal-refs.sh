#!/usr/bin/env bash
#
# Two rules about how a reusable workflow here reaches this repository's own actions.
#
# 1. NO `uses: ./` inside a reusable workflow or composite action. There a local action path
#    resolves against the CALLER's workspace, not this repository. No consumer has
#    .github/actions/, so the job dies with "Can't find 'action.yml' ... Did you forget to run
#    actions/checkout" - at run time, in the consuming repo. A workflow that only ever runs here,
#    ci.yml say, runs in this repository's own checkout, where `./` is the right reference: it
#    tests the action at the PR's head rather than at a tag a release PR has not cut yet.
#
# 2. Every self-reference pins the SAME immutable vX.Y.Z tag, never the moving `v1`. A caller
#    that pins `@v1.0.2` would otherwise still get the action at whatever `v1` points to now.
#    `uses:` takes no expression, so the tag cannot be derived and is written out; this check
#    is what makes forgetting to bump it loud.
#
# Release order: tag vX.Y.Z at the merge commit FIRST, then move `v1`. Consumers resolve the
# workflow at `v1`, so until that move they are on the previous commit and never see a tag
# that does not exist yet.
#
# `--resolve` additionally requires the pinned tag to EXIST. It cannot run on a PR - the tag
# is created after the merge that names it - so tag-check.yml runs it on a tag push and on
# every push to main instead. With PUSHED_REF and PUSHED_SHA set (the ref and commit of that
# push) it also requires the tag to name THIS release: a vX.Y.Z push must be the tag the
# workflows pin, and a move of `v1` must land on the commit that tag names. Existence alone
# let a commit that edits an action without bumping its references ship the old action.
set -uo pipefail
# CHECK_ROOT is for tools/test-internal-refs.sh, which runs this against fixture trees.
cd "${CHECK_ROOT:-$(dirname "$0")/..}" || exit 1

fail=0
resolve=false
[ "${1:-}" = "--resolve" ] && resolve=true

shopt -s nullglob
scan=(.github/workflows/*.yml .github/actions/*/action.yml)
# Nothing to read is a failure, not a pass: a check that finds no files has checked nothing.
if [ ${#scan[@]} -eq 0 ]; then
  echo "FAIL  no workflows or composite actions under $(pwd) - nothing was checked."
  exit 1
fi

# Rule 1's files: every composite action, and every workflow that names `workflow_call` as a
# trigger. The match is loose on purpose: any uncommented mention of `workflow_call` counts, so the
# mapping, inline, block-sequence and quoted forms all do. A file wrongly counted as reusable only
# loses `./`, while one wrongly left out would ship a reference that breaks in every consumer.
reusable=(.github/actions/*/action.yml)
callable=0
for wf in .github/workflows/*.yml; do
  if grep -qE '^[^#]*workflow_call' "$wf"; then reusable+=("$wf"); callable=$((callable + 1)); fi
done

local_refs=""
if [ ${#reusable[@]} -gt 0 ]; then
  local_refs=$(grep -nE '^[[:space:]]*(- )?uses:[[:space:]]*\./' "${reusable[@]}" || true)
fi
if [ -n "$local_refs" ]; then
  echo "FAIL  a reusable workflow or composite action cannot reference a local action - './' is the caller's workspace:"
  printf '%s\n' "$local_refs" | sed 's/^/      /'
  fail=1
fi

refs=$(grep -hoE '^[[:space:]]*(- )?uses:[[:space:]]*ScottCooper92/binge-ci/[^[:space:]]*' "${scan[@]}" \
       | sed 's/.*@//' | sort -u)
count=$(printf '%s\n' "$refs" | grep -c . || true)

if [ "$count" -eq 0 ] && [ "$callable" -gt 0 ]; then
  # A tree that ships reusable workflows pins its own actions, so finding none means the pattern
  # missed them (a quoted `uses:`, say) and every tag check below would pass on nothing.
  echo "FAIL  $callable reusable workflow(s), but no self-reference in a form this check reads"
  echo "      (uses: ScottCooper92/binge-ci/...@vX.Y.Z) - nothing was pinned or checked."
  fail=1
elif [ "$count" -eq 0 ]; then
  echo "ok    no self-references to pin"
elif [ "$count" -gt 1 ]; then
  echo "FAIL  self-references disagree on their tag: $(printf '%s ' $refs)"
  fail=1
elif ! printf '%s' "$refs" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "FAIL  self-references pin '$refs'; an immutable vX.Y.Z tag is required, not a moving alias"
  fail=1
else
  n=$(grep -cE '^[[:space:]]*(- )?uses:[[:space:]]*ScottCooper92/binge-ci/' "${scan[@]}" | awk -F: '{s+=$2} END{print s}')
  echo "ok    $n self-reference(s), all at $refs"

  if [ "$resolve" = true ]; then
    # Both the tag and its peeled form: an annotated tag lists twice, and the commit is the
    # second line; a lightweight one lists once, already a commit.
    remote=$(git ls-remote --tags origin "refs/tags/$refs" "refs/tags/$refs^{}" 2>/dev/null || true)
    if [ -z "$remote" ]; then
      echo "FAIL  the workflows reference $refs, which does not exist."
      echo "      Every consumer's next agent run dies on 'unable to resolve action'."
      echo "      Tag $refs at the commit these workflows are on, THEN move v1."
      fail=1
    else
      echo "ok    $refs exists"
      pinned_commit=$(printf '%s\n' "$remote" | awk '/\^\{\}$/ {p=$1} !/\^\{\}$/ {c=$1} END {print (p != "" ? p : c)}')
      pushed_ref="${PUSHED_REF:-}"
      pushed_commit=$(git rev-parse -q --verify "${PUSHED_SHA:-}^{commit}" 2>/dev/null || true)
      if printf '%s' "$pushed_ref" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        if [ "$pushed_ref" = "$refs" ]; then
          echo "ok    $pushed_ref is the tag the workflows pin"
        else
          echo "FAIL  $pushed_ref was pushed, but the workflows still pin $refs."
          echo "      Bump the self-references to $pushed_ref before tagging, or the actions at"
          echo "      $pushed_ref are not the ones that shipped with it."
          fail=1
        fi
      elif printf '%s' "$pushed_ref" | grep -qE '^v[0-9]+$'; then
        if [ -n "$pushed_commit" ] && [ "$pushed_commit" = "$pinned_commit" ]; then
          echo "ok    $pushed_ref now points at the commit $refs names"
        else
          echo "FAIL  $pushed_ref moved to ${pushed_commit:-an unknown commit}, but $refs names ${pinned_commit}."
          echo "      Every @$pushed_ref consumer now runs these workflows with the actions from $refs,"
          echo "      which is a different commit. Tag the release first, then move $pushed_ref to it."
          fail=1
        fi
      else
        # A branch push. Existing is not enough: a bump that pins a tag already cut at an older
        # commit passes that test, no tag push follows to catch it, and the first red is the v1 move,
        # after consumers already run these workflows with that older commit's actions. A release
        # tag is cut at its own bump, so its tree pins itself; one that pins anything else is reused.
        if ! git rev-parse -q --verify "$refs^{commit}" >/dev/null; then
          git fetch -q --depth=1 origin "refs/tags/$refs:refs/tags/$refs" 2>/dev/null || true
        fi
        tag_pins=$(git grep -hoE '^[[:space:]]*(- )?uses:[[:space:]]*ScottCooper92/binge-ci/[^[:space:]]*' \
                     "$refs" -- '.github/workflows/*.yml' '.github/actions/*/action.yml' 2>/dev/null \
                   | sed 's/.*@//' | sort -u)
        if [ -z "$tag_pins" ]; then
          echo "FAIL  could not read the self-references in $refs's own tree, so whether it is this"
          echo "      release's tag or a reused one is unknown."
          fail=1
        elif [ "$tag_pins" != "$refs" ]; then
          echo "FAIL  the workflows pin $refs, but $refs is an older commit whose own tree pins"
          echo "      $(printf '%s ' $tag_pins)- the tag was reused. Bump to a new tag, cut it at that"
          echo "      bump, and only then move v1."
          fail=1
        else
          echo "ok    $refs is the release that pins itself"
        fi
      fi
    fi
  fi
fi

exit $fail
