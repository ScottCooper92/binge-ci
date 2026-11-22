#!/usr/bin/env bash
#
# Holds the rule that keeps a private submodule out of a public repository's text. In a public repository the
# review, the follow-up issues, the replies and the pull request bodies the agents write are world-readable, and
# quoting a private submodule's PR numbers or file paths there leaks private work. The public-citation-rule action
# decides whether a prompt carries the rule, the same way the submodule-bump script decides whether to list a
# private submodule's commit subjects: the caller names the submodule, and the calling repository is taken to be
# public unless the API says it is private.
#
# What it holds: the rule is there for a public caller that lists a private submodule, and for one whose
# visibility could not be read; it is absent for a private caller and for a caller listing none; it names no
# repository; and every workflow that runs an agent which writes text runs the action and puts its output in the
# prompt, once per agent step.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
action="$root/.github/actions/public-citation-rule/action.yml"
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
failures=0
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
pass() { echo "ok    $1"; }
expect() { # $1=description  $2=shell condition
  if (set -e; eval "$2") > /dev/null 2>&1; then pass "$1"; else fail "$1"; fi
}

python3 -I - "$action" "$work" <<'PYX'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["runs"]["steps"]
hits = [s for s in steps if s.get("id") == "rule"]
if len(hits) != 1:
    sys.exit("the rule step is not in the action exactly once")
open(sys.argv[2] + "/rule.sh", "w").write(hits[0]["run"])
PYX

mkdir "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "${STUB_PRIVATE:-}" in
  fail) exit 1 ;;
  *) echo "$STUB_PRIVATE" ;;
esac
STUB
chmod +x "$work/bin/gh"

# Prints the block the action would hand the prompt.
block() { # $1 private-submodules, $2 what the API says (true|false|fail)
  : > "$work/out"
  env -i PATH="$work/bin:$PATH" GITHUB_OUTPUT="$work/out" PRIVATE_SUBMODULES="$1" GH_TOKEN=t GH_REPO=o/r STUB_PRIVATE="$2" \
    bash "$work/rule.sh" > "$work/rule.log" 2>&1
  # The output is `block<<delim`, the text, and the delimiter.
  awk 'NR == 1 {delim = substr($0, 8); next} $0 == delim {exit} {print}' "$work/out"
}
export -f block 2> /dev/null || true

pub=$(block "shared-lib" false); export pub
expect "a public caller that lists a private submodule gets the rule" '[[ $pub == *"never cite a private submodule"* ]]'
expect "the rule says what to call it instead" '[[ $pub == *"the shared library"* ]]'
expect "the rule covers numbers, URLs and file paths" '[[ $pub == *"pull"*"request or issue numbers, URLs or file paths"* ]]'
expect "the rule names no repository, number or path" '! grep -qE "[A-Za-z0-9_-]+/[A-Za-z0-9_-]+|#[0-9]+" <<<"$pub"'
unk=$(block "shared-lib" fail); export unk
expect "a visibility that cannot be read counts as public" '[ "$unk" = "$pub" ]'
expect "an answer that is not 'true' counts as public" '[ "$(block shared-lib maybe)" = "$pub" ]'
expect "a private caller gets nothing" '[ -z "$(block shared-lib true)" ]'
expect "a caller that lists no private submodule gets nothing" '[ -z "$(block "" false)" ]'
expect "a list of only separators gets nothing" '[ -z "$(block " , " false)" ]'
expect "several submodules still give the one rule" '[ "$(block "a,b" false)" = "$pub" ]'

python3 -I - "$root" <<'PYX' || failures=$((failures + 1))
import re, sys, yaml
root = sys.argv[1]
bad = []
for w in ("bot-review", "author-ci-fix", "author-comments", "author-conflicts"):
    wf = yaml.safe_load(open(f"{root}/.github/workflows/{w}.yml"))
    for jname, job in wf["jobs"].items():
        steps = job.get("steps", [])
        for i, s in enumerate(steps):
            if not str(s.get("uses", "")).startswith("anthropics/claude-code-action@"):
                continue
            prior = steps[:i]
            cit = [p for p in prior if str(p.get("uses", "")).startswith("ScottCooper92/binge-ci/.github/actions/public-citation-rule@")]
            if len(cit) != 1:
                bad.append(f"{w}/{jname}: the agent step is not preceded by the citation rule step exactly once")
                continue
            c = cit[0]
            if c["with"].get("private-submodules") != "${{ inputs.private_submodules }}":
                bad.append(f"{w}/{jname}: the rule is not given the caller's private_submodules")
            if f"steps.{c['id']}.outputs.block" not in s["with"]["prompt"]:
                bad.append(f"{w}/{jname}: the agent's prompt does not carry the rule")
text = open(f"{root}/.github/workflows/author-retarget.yml").read()
if "claude-code-action" in text:
    bad.append("author-retarget now runs an agent: it needs the citation rule too")
for b in bad:
    print("FAIL  " + b)
if not bad:
    print("ok    every agent step that writes text runs the rule's action and carries its output in the prompt")
sys.exit(1 if bad else 0)
PYX
[ "$failures" -eq 0 ]
