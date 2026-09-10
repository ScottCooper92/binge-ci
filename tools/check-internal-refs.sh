#!/usr/bin/env bash
#
# Two rules about how a reusable workflow here reaches this repository's own actions.
#
# 1. NO `uses: ./`. Inside a reusable workflow, a local action path resolves against the
#    CALLER's workspace, not against the repository defining the workflow. No consumer has
#    .github/actions/, so the job dies with "Can't find 'action.yml' ... Did you forget to
#    run actions/checkout before running your local action?" - at run time, in the consuming
#    repo, which is the one place the failure is expensive.
#
# 2. Every self-reference pins the SAME immutable vX.Y.Z tag, never the moving `v1`. A caller
#    that pins `@v1.0.2` for stability would otherwise still get the action at whatever `v1`
#    points to now, so its pin would not be a pin. `uses:` takes no expression, so the tag
#    cannot be derived from the ref this workflow was called at - it is written out, and this
#    check is what makes forgetting to bump it loud instead of silent.
#
# Release order matters and is what keeps the window safe: tag vX.Y.Z at the merge commit
# FIRST, then move `v1` onto it. Consumers resolve the workflow at `v1`, so until that move
# they are still on the previous commit and never see a tag that does not exist yet.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail=0
resolve=false
[ "${1:-}" = "--resolve" ] && resolve=true

# Both globs: a composite action referencing another action as `./` has the same problem, and
# nothing today does, so this is about the next one.
scan=(.github/workflows/*.yml .github/actions/*/action.yml)

local_refs=$(grep -nE '^[[:space:]]*(- )?uses:[[:space:]]*\./' "${scan[@]}" || true)
if [ -n "$local_refs" ]; then
  echo "FAIL  a reusable workflow cannot reference a local action - './' is the caller's workspace:"
  printf '%s\n' "$local_refs" | sed 's/^/      /'
  fail=1
fi

refs=$(grep -hoE '^[[:space:]]*(- )?uses:[[:space:]]*ScottCooper92/binge-ci/[^[:space:]]*' "${scan[@]}" \
       | sed 's/.*@//' | sort -u)
count=$(printf '%s\n' "$refs" | grep -c . || true)

if [ "$count" -eq 0 ]; then
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
    if git ls-remote --exit-code --tags origin "refs/tags/$refs" >/dev/null 2>&1; then
      echo "ok    $refs exists"
    else
      echo "FAIL  the workflows reference $refs, which does not exist."
      echo "      Every consumer's next agent run dies on 'unable to resolve action'."
      echo "      Tag $refs at the commit these workflows are on, THEN move v1."
      fail=1
    fi
  fi
fi

exit $fail
