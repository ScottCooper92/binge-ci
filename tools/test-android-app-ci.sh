#!/usr/bin/env bash
#
# Holds the properties android-app-ci.yml's callers rely on, none of which actionlint or the caller check
# can see. The workflow is the CI of every Android app, and a job that loses its `if:` or its runner
# input changes what a consumer's required check means.
#
# What it holds: every job runs on the `runner` input, so an app moves to a self-hosted runner by
# changing that alone; every job that builds is skipped unless `changes` succeeded and said its part of
# the diff mattered, so a failed `changes` never reads as "nothing to build"; the Gradle jobs stop their
# daemon when they end, so a shared runner keeps none alive; every Gradle argument list comes from an
# input and reaches the shell through the environment; every third-party action is pinned to a commit;
# and the worked caller keeps a `build` job of its own, since a required check named `build` has to be a
# job of the caller and not one of the reusable workflow's.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
python3 -I - "$root" <<'PY'
import re, sys, yaml

root = sys.argv[1]
wf_path = f"{root}/.github/workflows/android-app-ci.yml"
caller_path = f"{root}/callers/example/android-app-ci.yml"
text = open(wf_path).read()
wf = yaml.safe_load(text)
caller = yaml.safe_load(open(caller_path))
bad = []
ok = []

jobs = wf["jobs"]
inputs = wf[True]["workflow_call"]["inputs"]

for name, job in jobs.items():
    if job.get("runs-on") != "${{ fromJSON(inputs.runner) }}":
        bad.append(f"{name}: does not run on the runner input")
if inputs["runner"]["default"] != '["ubuntu-latest"]':
    bad.append("the runner input does not default to a hosted runner as a JSON array")
if not bad:
    ok.append(f"all {len(jobs)} jobs run on the runner input, a JSON array")

# The jobs that build wait for `changes` and run only when it succeeded and says they matter.
wanted = {"checks": "product", "tests": "product"}
for name, output in wanted.items():
    job = jobs.get(name)
    if job is None:
        bad.append(f"{name}: missing")
        continue
    if job.get("needs") != "changes":
        bad.append(f"{name}: does not need `changes`")
    cond = str(job.get("if", ""))
    for part in ("!cancelled()", "needs.changes.result == 'success'", f"needs.changes.outputs.{output} == 'true'"):
        if part not in cond:
            bad.append(f"{name}: its `if:` lacks `{part}`")
    if not str(job.get("timeout-minutes", "")).startswith("${{ inputs."):
        bad.append(f"{name}: its timeout is not an input")
    steps = job["steps"]
    stop = [s for s in steps if "gradlew --stop" in str(s.get("run", ""))]
    if not stop or "always()" not in str(stop[-1].get("if", "")) or steps[-1] is not stop[-1]:
        bad.append(f"{name}: the last step is not an `always()` Gradle daemon stop")
    gradle = [s for s in steps if "./gradlew \"${args[@]}\"" in str(s.get("run", ""))]
    if len(gradle) != 1:
        bad.append(f"{name}: expected one Gradle step that takes its arguments from an input")
    else:
        env = gradle[0].get("env", {})
        if "inputs." not in str(env.get("TASKS", "")):
            bad.append(f"{name}: its Gradle arguments do not come from an input through the environment")
        if "${{" in gradle[0]["run"]:
            bad.append(f"{name}: an expression is interpolated into the Gradle step's script")
    checkout = [s for s in steps if str(s.get("uses", "")).startswith("actions/checkout@")]
    if not checkout or checkout[0].get("with", {}).get("clean") is not True:
        bad.append(f"{name}: the checkout is not asked to clean, which a self-hosted runner needs")
if jobs["changes"].get("if") != "github.event_name != 'pull_request' || github.event.pull_request.draft == false":
    bad.append("changes: a draft pull request is not skipped, or another event is")
if not bad:
    ok.append("checks and tests wait for `changes`, skip unless it succeeded and said so, and stop their daemon")

# Every action is pinned: a commit for a third party, a release tag for this repository's own.
for ref in re.findall(r"^\s*(?:- )?uses:\s*(\S+)", text, re.M):
    if ref.startswith("ScottCooper92/binge-ci/"):
        if not re.search(r"@v\d+\.\d+\.\d+$", ref):
            bad.append(f"{ref}: a self-reference must pin a release tag")
    elif not re.search(r"@[0-9a-f]{40}$", ref):
        bad.append(f"{ref}: a third-party action must be pinned to a full commit")
if not any("pinned" in b or "pin" in b for b in bad):
    ok.append("every action is pinned")

# The worked caller: a job of its own named `build` that fails unless the shared run passed.
before = len(bad)
cjobs = caller["jobs"]
build = cjobs.get("build")
if build is None or build.get("needs") != "ci" or "always()" not in str(build.get("if", "")):
    bad.append("the worked caller has no `build` job that needs the shared run and runs `always()`")
elif "needs.ci.result" not in str(build["steps"]):
    bad.append("the worked caller's `build` does not read the shared run's result")
if caller.get("name") != "CI":
    bad.append("the worked caller's workflow is not named `CI`, which the bots match by name")
if len(bad) == before:
    ok.append("the worked caller keeps `CI` and a `build` job of its own")

for line in ok:
    print("ok    " + line)
for line in bad:
    print("FAIL  " + line)
sys.exit(1 if bad else 0)
PY
echo "all passed"
