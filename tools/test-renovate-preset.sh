#!/usr/bin/env bash
#
# Holds renovate/binge-ci-pins.json, the preset each consumer extends to get its binge-ci pins as one pull request.
# What it must never do is reach a consumer's `v1` or a branch head: the exact SHA pins are what stop a bad release
# reaching every consumer at once, so the preset may only ever offer a v1.0.N tag. It checks the file's own rules
# (the version restriction, the one group, the label, no `hold`, no schedule that would override the consumer's) and
# runs Renovate's own validator when it is installed.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
preset="$root/renovate/binge-ci-pins.json"
failures=0
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
ok() { echo "ok    $1"; }

if python3 -I - "$preset" <<'PY'
import json, re, sys
p = json.load(open(sys.argv[1]))
assert len(p["packageRules"]) == 3, len(p["packageRules"])
actions, off, sub = p["packageRules"]
assert actions["matchManagers"] == ["github-actions"] and sub["matchManagers"] == ["git-submodules"]
# Every other submodule is off: the disable rule matches the whole manager and comes before binge-ci's, which wins.
assert off["matchManagers"] == ["git-submodules"] and off["enabled"] is False and "matchPackageNames" not in off, off
assert sub["enabled"] is True

def js_regex(text):
    assert text.startswith("/") and text.endswith("/"), text
    return re.compile(text[1:-1])

# Only v1.0.N is ever a target.
allowed = js_regex(actions["allowedVersions"])
for good in ("v1.0.0", "v1.0.51", "v1.0.100"):
    assert allowed.search(good), good
for bad in ("v1", "v1.1.0", "v2.0.0", "v1.0", "v1.0.5-rc1", "1.0.5", "latest", "v1.0.5.1", "xv1.0.5"):
    assert not allowed.search(bad), bad
assert actions["pinDigests"] is True
assert actions["matchPackageNames"] == ["ScottCooper92/binge-ci"]

# The submodule rule matches binge-ci's own name and URL, and nothing that merely ends alike.
name = js_regex(sub["matchPackageNames"][0])
for good in ("binge-ci", "https://github.com/ScottCooper92/binge-ci", "https://github.com/ScottCooper92/binge-ci.git", "git@github.com:ScottCooper92/binge-ci.git", "libs/binge-ci"):
    assert name.search(good), good
for bad in ("binge-ci-fork", "not-binge-ci2", "binge-ci/sub", "other/binge-cix"):
    assert not name.search(bad), bad
assert p["git-submodules"] == {"enabled": True}

# One pull request: the same group, the same slug, the agent label, never hold.
assert actions["groupName"] == sub["groupName"] == "binge-ci" and actions["groupSlug"] == sub["groupSlug"] == "binge-ci"
for r in (actions, sub):
    assert r["addLabels"] == ["agent"], r["addLabels"]
    assert "hold" not in json.dumps(r)
    assert r["automerge"] is False
    # Now, not weekly: a new tag is a pin PR as soon as Renovate runs.
    assert r["schedule"] == ["at any time"] and r["prCreation"] == "immediate" and r["minimumReleaseAge"] is None
# A rule inside packageRules only: a top-level schedule or label would override the consumer's own.
assert not ({"schedule", "labels", "addLabels", "extends", "automerge"} & set(p))
PY
then ok "the preset offers only v1.0.N, groups the pins and the submodule into one agent-labelled pull request, and adds no hold"; else fail "the preset's rules are wrong"; fi

if command -v renovate-config-validator > /dev/null; then
  if renovate-config-validator --strict "$preset" > /dev/null 2>&1; then ok "Renovate's own validator accepts it"; else fail "Renovate's validator rejects the preset"; fi
else
  echo "skip  renovate-config-validator is not installed; run: npx --package renovate renovate-config-validator --strict renovate/binge-ci-pins.json"
fi

[ "$failures" -eq 0 ] || { echo "$failures failure(s)"; exit 1; }
echo "all passed"
