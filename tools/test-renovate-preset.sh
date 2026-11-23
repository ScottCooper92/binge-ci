#!/usr/bin/env bash
#
# Holds renovate/binge-ci-pins.json, the preset each consumer extends to get its binge-ci pins as one pull request, and
# renovate/shared-libraries.json, which only groups the libraries the apps share.
# What it must never do is reach a consumer's `v1` or a branch head: the exact SHA pins are what stop a bad release
# reaching every consumer at once, so the preset may only ever offer a v1.0.N tag. It checks the file's own rules
# (the version restriction, the one group, the label, no `hold`, no schedule that would override the consumer's, and the
# submodule manager left on for binge-ci alone) and
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
actions_rules = [r for r in p["packageRules"] if r["matchManagers"] == ["github-actions"]]
sub_rules = [r for r in p["packageRules"] if r["matchManagers"] == ["git-submodules"]]
assert len(actions_rules) == 1 and len(sub_rules) == 2 and len(p["packageRules"]) == 3, [r["matchManagers"] for r in p["packageRules"]]
actions = actions_rules[0]
# The manager is on for the whole repository, so a rule has to turn it off for every submodule but binge-ci's, and
# it has to come first: of the rules that match a dependency, the later one wins.
off, sub = sub_rules
assert p["packageRules"].index(off) < p["packageRules"].index(sub)
assert off["enabled"] is False and "matchPackageNames" not in off
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
# Which submodules end up with the manager on: binge-ci's only. Renovate applies the matching rules in order.
def enabled_for(dep):
    on = p["git-submodules"]["enabled"]
    for r in sub_rules:
        pats = r.get("matchPackageNames")
        if pats is None or any(js_regex(x).search(dep) for x in pats):
            on = r.get("enabled", on)
    return on
for dep in ("binge-ci", "https://github.com/ScottCooper92/binge-ci.git"):
    assert enabled_for(dep) is True, dep
for dep in ("other-library", "shared-ui", "other-module", "https://github.com/ScottCooper92/other-library.git", "binge-ci-fork"):
    assert enabled_for(dep) is False, dep

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

# The shared-libraries preset only groups. It must set nothing a consumer owns: no schedule, label, automerge, version
# limit or enabled flag, and each library family has its own group, so one pull request moves one library.
shared="$root/renovate/shared-libraries.json"
if python3 -I - "$shared" <<'PY'
import json, re, sys
p = json.load(open(sys.argv[1]))
assert set(p) == {"$schema", "description", "packageRules"}, sorted(p)
rules = p["packageRules"]
want = {"DataStore", "OkHttp", "kotlinx.serialization", "Robolectric"}
assert {r["groupName"] for r in rules} == want and len(rules) == len(want), [r["groupName"] for r in rules]
assert len({r["groupSlug"] for r in rules}) == len(rules), "two groups share a slug"
allowed = {"description", "matchManagers", "matchPackageNames", "groupName", "groupSlug"}
for r in rules:
    assert set(r) <= allowed, sorted(set(r) - allowed)
    assert r["matchManagers"] == ["gradle"] and len(r["matchPackageNames"]) == 1

def glob(g):
    return re.compile("^" + ".*".join(re.escape(x) for x in g.split("*")) + "$")
def group_of(dep):
    hits = [r["groupName"] for r in rules if glob(r["matchPackageNames"][0]).match(dep)]
    assert len(hits) <= 1, (dep, hits)
    return hits[0] if hits else None
for dep, group in (("androidx.datastore:datastore-preferences", "DataStore"), ("androidx.datastore:datastore", "DataStore"),
                   ("com.squareup.okhttp3:okhttp", "OkHttp"), ("com.squareup.okhttp3:logging-interceptor", "OkHttp"),
                   ("org.jetbrains.kotlinx:kotlinx-serialization-json", "kotlinx.serialization"),
                   ("org.robolectric:robolectric", "Robolectric"), ("org.robolectric:android-all-instrumented", "Robolectric"),
                   ("org.jetbrains.kotlinx:kotlinx-coroutines-core", None), ("androidx.datastore2:x", None),
                   ("com.squareup.okio:okio", None), ("org.robolectricx:robolectric", None)):
    assert group_of(dep) == group, (dep, group_of(dep), group)
PY
then ok "the shared-libraries preset only groups four library families, one pull request each, and sets nothing a consumer owns"; else fail "the shared-libraries preset's rules are wrong"; fi

if command -v renovate-config-validator > /dev/null; then
  for f in "$preset" "$shared"; do
    if renovate-config-validator --strict "$f" > /dev/null 2>&1; then ok "Renovate's own validator accepts ${f##*/}"; else fail "Renovate's validator rejects ${f##*/}"; fi
  done
else
  echo "skip  renovate-config-validator is not installed; run: npx --package renovate renovate-config-validator --strict renovate/*.json"
fi

[ "$failures" -eq 0 ] || { echo "$failures failure(s)"; exit 1; }
echo "all passed"
