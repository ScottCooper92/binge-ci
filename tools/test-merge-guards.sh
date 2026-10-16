#!/usr/bin/env bash
#
# Runs merge-guards.sh's offline subcommands against fixed inputs. `buildable` decides whether the
# review bot may treat a PR as one CI never builds, and with `merge_unbuilt` on, whether it may merge
# one with no build behind it. A path it lets through wrongly merges unbuilt code.
set -euo pipefail

guards="$(cd "$(dirname "$0")/.." && pwd)/.github/actions/merge-guards/merge-guards.sh"
export GH_REPO=fixture/fixture
failures=0
# Binge's paths-ignore, in its regex form.
regex='\.md$|^LICENSE$|^\.gitignore$|^tools/|^\.ai/|^docs/design/'

# Passes when `buildable` prints exactly the expected paths, one per line, for the given input.
expect() {
  local name=$1 input=$2 want=$3 got
  got=$(printf '%s' "$input" | bash "$guards" buildable "$regex")
  if [ "$got" = "$want" ]; then
    echo "ok    $name"
  else
    echo "FAIL  $name: expected [$want], got [$got]"
    failures=1
  fi
}

expect all-unbuilt $'README.md\ndocs/design/a.png\n.ai/agents/guide.md\ntools/x.sh\nLICENSE\n' ''
expect one-buildable $'README.md\napp/src/main/A.kt\n' 'app/src/main/A.kt'
# A rename lists both sides; moving source into docs/ still names the source.
expect rename-out-of-source $'docs/design/A.kt\napp/src/main/A.kt\n' 'app/src/main/A.kt'
# Anchors hold: a path that merely contains an ignored directory name is built.
expect anchored $'app/tools/x.kt\nsrc/docs/design/y.kt\n' $'app/tools/x.kt\nsrc/docs/design/y.kt'
# A workflow's Markdown README is unbuilt by the regex; the merge gate refuses workflow paths itself.
expect workflow-markdown $'.github/workflows/README.md\n' ''
expect blank-lines $'\n\nREADME.md\n\n' ''
# The regex reaches jq as a value: a backslash escape must not break the program.
expect regex-escape $'a.md\nab\n' 'ab'

if bash "$guards" method squash && ! bash "$guards" method fast-forward 2>/dev/null; then
  echo "ok    method"
else
  echo "FAIL  method: squash must pass and fast-forward must fail"
  failures=1
fi

exit "$failures"
