#!/usr/bin/env bash
#
# Holds the step that lets a self-hosted runner reuse one Claude Code and Bun install across jobs.
# The script is in the agent-claude-cache action. Each agent job still carries an inline copy, since a
# new action has no release tag to pin until a release, so this requires each copy to equal the script,
# ties each one to the pin of the claude-code-action step it serves, and runs the script against a
# stubbed installer: variable unset, cold cache, warm cache, two jobs at
# once, a corrupted file, a failed install, an unreadable version, and pruning.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work=$(mktemp -d)
trap 'chmod -R u+w "$work" 2> /dev/null; rm -rf "$work"' EXIT
failures=0
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
ok() { echo "ok    $1"; }

mkdir "$work/steps"
python3 -I - "$root" "$work/steps" <<'PY' || failures=$((failures + 1))
import sys, yaml
root, out = sys.argv[1:3]
bad, n = [], 0
for wf in ["author-ci-fix", "author-comments", "author-conflicts", "bot-review"]:
    doc = yaml.safe_load(open(f"{root}/.github/workflows/{wf}.yml"))
    for job, body in doc["jobs"].items():
        steps = body.get("steps", [])
        agent = [i for i, s in enumerate(steps) if str(s.get("uses", "")).startswith("anthropics/claude-code-action@")]
        if not agent:
            continue
        where = f"{wf}/{job}"
        a = agent[0]
        pin = steps[a]["uses"].split("@")[1].split()[0]
        cache = [i for i, s in enumerate(steps) if s.get("name") == "Reuse a runner-local Claude Code install"]
        limits = [i for i, s in enumerate(steps) if s.get("name") == "Bound the agent's network calls"]
        if len(cache) != 1:
            bad.append(f"{where}: no single cache step")
            continue
        c = cache[0]
        s = steps[c]
        n += 1
        open(f"{out}/step.{n}", "w").write(s["run"])
        if s.get("id") != "cc_cache":
            bad.append(f"{where}: the cache step has no `id: cc_cache`")
        if s.get("env", {}).get("ACTION_REF") != pin:
            bad.append(f"{where}: ACTION_REF is not the pin of the claude-code-action step ({pin})")
        if not c < a:
            bad.append(f"{where}: the cache step must come before the agent step")
        if s.get("timeout-minutes") != 10 or s.get("continue-on-error") is not True:
            bad.append(f"{where}: the cache step must be capped at 10 minutes and allowed to fail, so a slow download is left to the agent step's own install")
        if "timeout --foreground" in s["run"]:
            bad.append(f"{where}: `timeout --foreground` signals only its direct child, and the pipeline's curl would outlive it")
        if limits and not c < limits[0]:
            bad.append(f"{where}: the cache step must come before the step that sets curl's limits, which would cut the download short")
        if s.get("if") != steps[a].get("if"):
            bad.append(f"{where}: the cache step must run exactly when the agent step does")
        w = steps[a].get("with", {})
        if "steps.cc_cache.outputs.claude_path" not in str(w.get("path_to_claude_code_executable", "")):
            bad.append(f"{where}: the agent step is not given the cached Claude Code path")
        if "steps.cc_cache.outputs.bun_path" not in str(w.get("path_to_bun_executable", "")):
            bad.append(f"{where}: the agent step is not given the cached Bun path")
# The first job per version can spend the step's whole cap, so each job's default bound has to leave
# room for it after the agent's bound and the ~5 minutes of setup and ~4 of downstream steps the
# workflows describe: otherwise a cold runner cancels a job that would have posted its verdict.
for wf in ["author-ci-fix", "author-comments", "author-conflicts", "bot-review"]:
    inputs = yaml.safe_load(open(f"{root}/.github/workflows/{wf}.yml"))[True]["workflow_call"]["inputs"]
    total, agent = inputs["timeout_minutes"]["default"], inputs["agent_timeout_minutes"]["default"]
    if total - agent < 19:
        bad.append(f"{wf}: timeout_minutes ({total}) leaves {total - agent} minutes beyond agent_timeout_minutes ({agent}); a cold cache install needs 10 on top of ~9 for setup and downstream steps")
# A fork PR's text reaches the agent there, and the cache outlives the job.
fork = open(f"{root}/.github/workflows/fork-review.yml").read()
if "BINGE_CI_CLAUDE_CODE_CACHE" in fork or "cc_cache" in fork:
    bad.append("fork-review.yml must not use the runner-local cache")
for b in bad:
    print("FAIL  " + b)
print(f"ok    {n} agent jobs carry the cache step" if not bad else "")
sys.exit(1 if bad or n != 5 else 0)
PY
script="$root/.github/actions/agent-claude-cache/claude-cache.sh"
# The script is the step's body behind a header of comments; the body starts at its `set` line.
tail -n +"$(grep -n '^set -uo pipefail' "$script" | head -n 1 | cut -d: -f1)" "$script" > "$work/script-body"
same=true
for copy in "$work"/steps/step.*; do cmp -s "$work/script-body" "$copy" || same=false; done
if [ "$same" = true ] && [ "$(ls "$work"/steps/step.* | wc -l)" -eq 5 ]; then
  ok "the cache step is the action's script in all five agent jobs"
else
  fail "an inline cache step differs from the action's script"
fi
step="$script"

# A runner: <root>/_work/<repo> as the workspace, the action's checkout beside it under _actions.
ref=0123456789abcdef0123456789abcdef01234567
new_runner() { # $1=case name
  runner="$work/$1"
  mkdir -p "$runner/_work/repo" "$runner/_work/_actions/anthropics/claude-code-action/$ref/src/entrypoints"
  printf 'const claudeCodeVersion = "9.9.9";\n' > "$runner/_work/_actions/anthropics/claude-code-action/$ref/src/entrypoints/run.ts"
  printf 'runs:\n  steps:\n    - with:\n        bun-version: 8.8.8\n' > "$runner/_work/_actions/anthropics/claude-code-action/$ref/action.yml"
  cache="$runner/cache"
  counts="$runner/counts"; mkdir -p "$counts"
  : > "$runner/output"
}
# A stub curl that serves a fake installer for each of the two URLs. Each install counts itself, and
# leaves what the real ones leave: a symlink under HOME to a file elsewhere under HOME.
mkdir "$work/bin"
cat > "$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *claude.ai/install.sh*)
    cat <<'INSTALLER'
echo x >> "$COUNTS/claude"
[ -z "${INSTALL_FAILS:-}" ] || exit 1
mkdir -p "$HOME/.local/share/claude/versions" "$HOME/.local/bin"
printf '#!/bin/sh\necho claude %s\n' "$1" > "$HOME/.local/share/claude/versions/$1"
chmod +x "$HOME/.local/share/claude/versions/$1"
ln -s "$HOME/.local/share/claude/versions/$1" "$HOME/.local/bin/claude"
INSTALLER
    ;;
  *bun.sh/install*)
    cat <<'INSTALLER'
echo x >> "$COUNTS/bun"
sleep "${INSTALL_SLEEP:-0}"
mkdir -p "$BUN_INSTALL/bin"
printf '#!/bin/sh\necho bun %s\n' "$1" > "$BUN_INSTALL/bin/bun"
chmod +x "$BUN_INSTALL/bin/bun"
INSTALLER
    ;;
  *) echo "stub curl: unexpected $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$work/bin/curl"

run_step() { # extra env assignments as arguments
  : > "$runner/output"
  env -i PATH="$work/bin:$PATH" HOME="$runner/home" RUNNER_WORKSPACE="$runner/_work/repo" ACTION_REF="$ref" \
    GITHUB_OUTPUT="$runner/output" COUNTS="$counts" "$@" bash "$step" > "$runner/log" 2>&1
}
installs() { [ -f "$counts/$1" ] && wc -l < "$counts/$1" | tr -d ' ' || echo 0; }
out() { sed -n "s/^$1=//p" "$runner/output"; }

echo "-- the variable is unset"
new_runner unset
rc=0; run_step || rc=$?
if [ $rc -eq 0 ] && [ ! -s "$runner/output" ] && [ "$(installs claude)" = 0 ] && [ ! -e "$cache" ]; then
  ok "nothing is output, installed or created"
else
  fail "an unset variable changed something"
fi
rc=0; run_step BINGE_CI_CLAUDE_CODE_CACHE= || rc=$?
[ $rc -eq 0 ] && [ ! -s "$runner/output" ] && ok "an empty variable is the same as an unset one" || fail "an empty variable was used"
rc=0; run_step BINGE_CI_CLAUDE_CODE_CACHE=relative/dir || rc=$?
[ $rc -eq 0 ] && [ ! -s "$runner/output" ] && grep -q '::warning::.*absolute' "$runner/log" \
  && ok "a relative path is refused with a warning, and the job goes on" || fail "a relative cache path was used"

echo "-- an empty cache"
new_runner cold
rc=0; run_step BINGE_CI_CLAUDE_CODE_CACHE="$cache" || rc=$?
if [ $rc -eq 0 ] && [ "$(installs claude)" = 1 ] && [ "$(installs bun)" = 1 ] \
   && [ "$(out claude_path)" = "$cache/claude-9.9.9/claude" ] && [ "$(out bun_path)" = "$cache/bun-8.8.8/bun" ]; then
  ok "each is installed once, at the version the action pins, and the paths are output"
else
  fail "a cold cache did not install once and output the paths"; sed 's/^/      /' "$runner/log"
fi
[ "$("$cache/claude-9.9.9/claude")" = "claude 9.9.9" ] && [ ! -L "$cache/claude-9.9.9/claude" ] \
  && ok "what is cached is the installed file itself, not a link into the installer's temporary home" || fail "the cached claude is not the real file"
[ "$(stat -c %a "$cache/claude-9.9.9/claude")" = 555 ] && [ "$(stat -c %a "$cache/claude-9.9.9")" = 555 ] && [ -f "$cache/claude-9.9.9/claude.sha256" ] \
  && ok "it is read-only and its checksum is recorded" || fail "the cached install is writable or has no checksum"
[ -z "$(find "$cache" -maxdepth 1 -name '.tmp.*')" ] && ok "no temporary directory is left behind" || fail "a temporary directory was left"

echo "-- a warm cache"
rc=0; run_step BINGE_CI_CLAUDE_CODE_CACHE="$cache" || rc=$?
if [ $rc -eq 0 ] && [ "$(installs claude)" = 1 ] && [ "$(installs bun)" = 1 ] && [ "$(out claude_path)" = "$cache/claude-9.9.9/claude" ]; then
  ok "nothing is downloaded and the same paths are output"
else
  fail "a warm cache downloaded again"
fi

echo "-- two jobs at once"
new_runner race
rc=0
run_step BINGE_CI_CLAUDE_CODE_CACHE="$cache" INSTALL_SLEEP=2 & first=$!
sleep 0.5
cp "$runner/output" "$runner/output.first" 2> /dev/null || true
env -i PATH="$work/bin:$PATH" HOME="$runner/home" RUNNER_WORKSPACE="$runner/_work/repo" ACTION_REF="$ref" \
  GITHUB_OUTPUT="$runner/output2" COUNTS="$counts" BINGE_CI_CLAUDE_CODE_CACHE="$cache" INSTALL_SLEEP=2 bash "$step" > "$runner/log2" 2>&1 & second=$!
wait "$first" || rc=1
wait "$second" || rc=1
if [ $rc -eq 0 ] && [ "$(installs claude)" = 1 ] && [ "$(installs bun)" = 1 ] \
   && [ "$(sed -n 's/^claude_path=//p' "$runner/output2")" = "$cache/claude-9.9.9/claude" ]; then
  ok "one download serves both, and both get a path"
else
  fail "two jobs downloaded twice, or one got nothing"
fi

echo "-- a cached file that no longer matches its checksum"
new_runner corrupt
run_step BINGE_CI_CLAUDE_CODE_CACHE="$cache"
chmod u+w "$cache/claude-9.9.9" "$cache/claude-9.9.9/claude"; echo tampered >> "$cache/claude-9.9.9/claude"
rc=0; run_step BINGE_CI_CLAUDE_CODE_CACHE="$cache" || rc=$?
if [ $rc -eq 0 ] && [ -z "$(out claude_path)" ] && [ ! -e "$cache/claude-9.9.9" ] && grep -q '::warning::.*checksum' "$runner/log" \
   && [ "$(out bun_path)" = "$cache/bun-8.8.8/bun" ]; then
  ok "it is deleted with a warning, no path is output for it (the action installs it), and the other tool is unaffected"
else
  fail "a mismatch was used, or broke the step"; sed 's/^/      /' "$runner/log"
fi
rc=0; run_step BINGE_CI_CLAUDE_CODE_CACHE="$cache" || rc=$?
[ $rc -eq 0 ] && [ -x "$cache/claude-9.9.9/claude" ] && [ "$(installs claude)" = 2 ] \
  && ok "the next job installs it afresh" || fail "the cache did not recover after a mismatch"

echo "-- an install that fails"
new_runner failing
rc=0; run_step BINGE_CI_CLAUDE_CODE_CACHE="$cache" INSTALL_FAILS=1 || rc=$?
if [ $rc -eq 0 ] && [ -z "$(out claude_path)" ] && [ ! -e "$cache/claude-9.9.9" ] && grep -q '::warning::.*claude' "$runner/log" \
   && [ -z "$(find "$cache" -maxdepth 1 -name '.tmp.*')" ]; then
  ok "the step still succeeds, outputs nothing for it, and leaves no partial install"
else
  fail "a failed install failed the step or left something behind"; sed 's/^/      /' "$runner/log"
fi

echo "-- the versions cannot be read"
new_runner unreadable
rm "$runner/_work/_actions/anthropics/claude-code-action/$ref/src/entrypoints/run.ts"
rc=0; run_step BINGE_CI_CLAUDE_CODE_CACHE="$cache" || rc=$?
[ $rc -eq 0 ] && [ ! -s "$runner/output" ] && [ "$(installs claude)" = 0 ] && grep -q '::warning::.*versions' "$runner/log" \
  && ok "it warns and falls back to the action's own install" || fail "an unreadable version was not handled"
printf 'const claudeCodeVersion = "../../etc";\n' > "$runner/_work/_actions/anthropics/claude-code-action/$ref/src/entrypoints/run.ts"
rc=0; run_step BINGE_CI_CLAUDE_CODE_CACHE="$cache" || rc=$?
[ $rc -eq 0 ] && [ ! -s "$runner/output" ] && [ "$(installs claude)" = 0 ] \
  && ok "a version that is not a version is never used in a path" || fail "an odd version string was used"

echo "-- old versions"
new_runner prune
for v in 1.0.0 2.0.0 3.0.0; do
  mkdir -p "$cache/claude-$v"; touch "$cache/claude-$v/claude"
done
touch -d '3 days ago' "$cache/claude-1.0.0"; touch -d '2 days ago' "$cache/claude-2.0.0"; touch -d '1 day ago' "$cache/claude-3.0.0"
chmod -R a-w "$cache/claude-1.0.0"
rc=0; run_step BINGE_CI_CLAUDE_CODE_CACHE="$cache" || rc=$?
if [ $rc -eq 0 ] && [ -d "$cache/claude-9.9.9" ] && [ -d "$cache/claude-3.0.0" ] && [ ! -e "$cache/claude-2.0.0" ] && [ ! -e "$cache/claude-1.0.0" ]; then
  ok "the version in use and the one used most recently are kept, the rest (read-only too) are removed"
else
  fail "pruning kept or removed the wrong versions: $(ls "$cache" | tr '\n' ' ')"
fi

echo "-- the action"
python3 -I - "$root/.github/actions/agent-claude-cache/action.yml" <<'PY' && ok "the pin reaches the script through env, is required, and both outputs are the step's" || fail "the action's wiring is wrong"
import sys, yaml
a = yaml.safe_load(open(sys.argv[1]))
step = a["runs"]["steps"][0]
assert a["inputs"]["action_ref"]["required"] is True
assert step["env"]["ACTION_REF"] == "${{ inputs.action_ref }}"
assert "${{" not in step["run"] and step.get("shell") == "bash"
assert step.get("id") == "cache"
for o in ("claude_path", "bun_path"):
    assert a["outputs"][o]["value"] == "${{ steps.cache.outputs.%s }}" % o
PY

[ "$failures" -eq 0 ] || { echo "$failures failure(s)"; exit 1; }
