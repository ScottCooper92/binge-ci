#!/usr/bin/env bash
#
# Holds the two steps that every agent job carries: the one that bounds the agent's network calls,
# and the one that prints its last tool calls when the agent step does not succeed. Each is a
# composite action under .github/actions/ with its script. Every agent job uses the actions, with no
# inline copy left, and the scripts are run here against fixtures.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
fail() { echo "FAIL $1"; failures=$((failures + 1)); }
ok() { echo "ok   $1"; }

# Every agent job uses both actions and carries no inline copy of either.
python3 -I - "$root" <<'PY' || failures=$((failures + 1))
import re, sys, yaml
root = sys.argv[1]
bad, jobs = [], 0
LIMITS = re.compile(r"^ScottCooper92/binge-ci/\.github/actions/agent-network-limits@v\d+\.\d+\.\d+$")
DUMP = re.compile(r"^ScottCooper92/binge-ci/\.github/actions/agent-tool-calls@v\d+\.\d+\.\d+$")
for wf in ["author-ci-fix", "author-comments", "author-conflicts", "bot-review"]:
    doc = yaml.safe_load(open(f"{root}/.github/workflows/{wf}.yml"))
    n = 0
    for job, body in doc["jobs"].items():
        steps = body.get("steps", [])
        for i, s in enumerate(steps):
            if not str(s.get("uses", "")).startswith("anthropics/claude-code-action@"):
                continue
            n += 1
            jobs += 1
            where = f"{wf}/{job}"
            if s.get("id") != "claude":
                bad.append(f"{where}: the agent step has no `id: claude`")
            lim = [k for k, t in enumerate(steps) if LIMITS.match(str(t.get("uses", "")))]
            dump = [k for k, t in enumerate(steps) if DUMP.match(str(t.get("uses", "")))]
            if len(lim) != 1 or lim[0] > i:
                bad.append(f"{where}: no single use of agent-network-limits before the agent step")
            if len(dump) != 1 or dump[0] < i:
                bad.append(f"{where}: no single use of agent-tool-calls after the agent step")
                continue
            d = steps[dump[0]]
            cond = d.get("if", "")
            if "always()" not in cond or "steps.claude.outcome" not in cond:
                bad.append(f"{where}: the dump step must run after a failed agent step")
            w = d.get("with", {})
            if "steps.claude.outputs.execution_file" not in str(w.get("execution_file", "")):
                bad.append(f"{where}: the dump step is not given the agent step's execution file")
            if "inputs.show_full_output" not in str(w.get("show_full_output", "")):
                bad.append(f"{where}: the dump step is not given show_full_output")
            copies = [t.get("name") for t in steps if "run" in t and t.get("name") in
                      ("Bound the agent's network calls", "Show the agent's last tool calls")]
            if copies:
                bad.append(f"{where}: an inline copy is left: {copies}")
    if n == 0:
        bad.append(f"{wf}: no agent step found")
for b in bad:
    print("FAIL " + b)
if not bad:
    print(f"ok   all {jobs} agent jobs use both actions and carry no inline copy")
sys.exit(1 if bad else 0)
PY

limits="$root/.github/actions/agent-network-limits/limits.sh"
dump="$root/.github/actions/agent-tool-calls/tool-calls.sh"

for script in "$limits" "$dump"; do
  [ -x "$script" ] && ok "$(basename "$script") is executable" || fail "$(basename "$script") is not executable"
done

# Each action runs its script, and passes the dump step what it reads.
grep -q 'limits.sh' "$root/.github/actions/agent-network-limits/action.yml" \
  && ok "the limits action runs its script" || fail "the limits action does not run limits.sh"
grep -q 'tool-calls.sh' "$root/.github/actions/agent-tool-calls/action.yml" \
  && grep -q 'EXECUTION_FILE: ${{ inputs.execution_file }}' "$root/.github/actions/agent-tool-calls/action.yml" \
  && grep -q 'SHOW_FULL_OUTPUT: ${{ inputs.show_full_output }}' "$root/.github/actions/agent-tool-calls/action.yml" \
  && ok "the tool-calls action runs its script with both inputs" || fail "the tool-calls action is not wired to its script"

# The limits step: the curl config lands under RUNNER_TEMP, and the env file carries the rest.
tmp="$work/runner"; mkdir -p "$tmp"; : > "$work/env"
RUNNER_TEMP="$tmp" GITHUB_ENV="$work/env" bash "$limits"
grep -qx 'connect-timeout = 10' "$tmp/agent-curl-home/.curlrc" && grep -qx 'max-time = 120' "$tmp/agent-curl-home/.curlrc" \
  && ok "curl gets a connect and a total timeout" || fail "the curl config is wrong"
grep -qx "CURL_HOME=$tmp/agent-curl-home" "$work/env" && grep -qx 'GIT_HTTP_LOW_SPEED_LIMIT=1000' "$work/env" \
  && grep -qx 'GIT_HTTP_LOW_SPEED_TIME=60' "$work/env" && ok "the env file points curl at it and bounds git" \
  || fail "the env file is wrong"

# The dump step: an execution file (an array) and a transcript (lines) read the same way.
tool() { jq -nc --arg n "$1" --arg c "$2" '{type:"assistant",message:{content:[{type:"text",text:"x"},{type:"tool_use",name:$n,input:{command:$c}}]}}'; }
{ for i in $(seq 1 12); do tool Bash "echo call$i"; done
  tool Bash "curl https://example.invalid/$(printf 'a%.0s' $(seq 1 400))"
  tool Bash "export T=ghp_abcdefghijklmnopqrstuvwxyz0123456789"
  jq -nc '{type:"result",result:"done"}'; } > "$work/transcript.jsonl"
jq -s '.' "$work/transcript.jsonl" > "$work/exec.json"

out=$(SHOW_FULL_OUTPUT=true EXECUTION_FILE="$work/exec.json" HOME="$work/home" bash "$dump")
grep -q 'call3$' <<<"$out" && fail "an old call was printed" || ok "only the last 10 calls are printed"
grep -q 'call12' <<<"$out" && ok "the newest call is printed" || fail "the newest call is missing"
grep -q 'ghp_abc' <<<"$out" && fail "a token was printed" || ok "token shapes are masked"
[ "$(grep -c 'aaaaaaaaaaaaaaaa' <<<"$out")" -eq 1 ] && ! grep -q 'a\{320\}' <<<"$out" && ok "a long command is cut" || fail "a long command was not cut"

# A killed step has no execution file: the newest transcript under HOME is read instead.
mkdir -p "$work/home/.claude/projects/p"; cp "$work/transcript.jsonl" "$work/home/.claude/projects/p/s.jsonl"
out=$(SHOW_FULL_OUTPUT=true EXECUTION_FILE="" HOME="$work/home" bash "$dump")
grep -q 'call12' <<<"$out" && ok "with no execution file the transcript is read" || fail "the transcript fallback failed"

# A killed CLI can leave a half-written last line: the complete lines still print.
{ cat "$work/transcript.jsonl"; printf '{"type":"assistant","message":{"content":[{"type":"tool_use","na'; } > "$work/home/.claude/projects/p/s.jsonl"
out=$(SHOW_FULL_OUTPUT=true EXECUTION_FILE="" HOME="$work/home" bash "$dump")
grep -qi 'parse error' <<<"$out" && fail "a half-written last line broke the read" \
  || { grep -q 'Bash: ' <<<"$out" && ok "a half-written last line is skipped"; } || fail "a half-written last line broke the read"

# show_full_output off, the default: tool names only, no command text, in a log anyone can read.
for flag in false ""; do
  out=$(SHOW_FULL_OUTPUT="$flag" EXECUTION_FILE="$work/exec.json" HOME="$work/home" bash "$dump")
  if grep -q 'Bash' <<<"$out" && ! grep -qE 'echo call|curl|example\.invalid|export T=' <<<"$out"; then
    ok "with show_full_output '${flag:-unset}' only tool names are printed"
  else
    fail "with show_full_output '${flag:-unset}' command text reached the log"
  fi
done

out=$(EXECUTION_FILE="$work/missing.json" HOME="$work/empty" bash "$dump") && rc=0 || rc=$?
{ [ "$rc" -eq 0 ] && grep -q 'No execution file' <<<"$out"; } && ok "nothing to read is reported, not failed" || fail "a missing file broke the step"

# The review prompt keeps its rule about URLs.
grep -q 'Do not fetch any URL' "$root/.github/workflows/bot-review.yml" \
  && ok "the review prompt forbids fetching URLs from PR content" || fail "the review prompt lost its URL rule"

[ "$failures" -eq 0 ] || { echo "$failures failure(s)"; exit 1; }
