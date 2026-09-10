#!/usr/bin/env bash
# Undo claude-code-action's rewrite of the files that govern an agent, before an author job
# commits the working tree.
#
# The action treats a PR head as untrusted and overwrites the paths below with the base
# branch's copy just before the agent starts. It does that in the WORKING TREE, which is what
# bites: the author jobs then `git add -A`, so the rewrite lands in the bot's commit as though
# the agent had made it, reverting the PR's own changes with nothing on the PR saying so.
#
# Usage: restore-agent-governed-paths.sh <ref>
#   <ref> is what the job checked out - the PR as pushed, so always the right content here.
#   Prints a markdown note on stdout only when it discarded something that was NOT simply the
#   action's rewrite. Progress goes to stderr.
#
# Usage: restore-agent-governed-paths.sh --list
#   Prints the governed paths and exits. This file is their single definition, so a caller
#   reasoning about the same paths reads them from here rather than keeping a copy that can
#   narrow silently.
#
# $GOVERNED_BASE_REF (default origin/main) is the ref the action rewrote from.
set -euo pipefail

# Fixed by the pinned claude-code-action SHA in the author workflows, so it cannot drift
# without someone bumping that pin. A path absent from a repo costs nothing to list - the
# diff never fires for it - which is why one list serves every consumer.
governed=(.claude .mcp.json .claude.json .gitmodules .ripgreprc CLAUDE.md CLAUDE.local.md .husky)
if [ -n "${GOVERNED_EXTRA_PATHS:-}" ]; then
  while IFS= read -r extra_path; do
    extra_path="${extra_path#"${extra_path%%[![:space:]]*}"}"
    extra_path="${extra_path%"${extra_path##*[![:space:]]}"}"
    [ -n "$extra_path" ] && governed+=("$extra_path")
  done <<<"$GOVERNED_EXTRA_PATHS"
fi

if [ "${1:-}" = "--list" ]; then
  printf '%s\n' "${governed[@]}"
  exit 0
fi

ref="${1:?usage: restore-agent-governed-paths.sh <ref>|--list}"

# Telling the action's rewrite apart from an edit the agent made needs the base branch's copy:
# "the worktree is byte-identical to the base" is the whole discriminator. Without the ref,
# report every restore rather than assume the quiet case.
base=$(git rev-parse -q --verify "${GOVERNED_BASE_REF:-origin/main}" || true)

restored=()
discarded=()
added=()

for path in "${governed[@]}"; do
  # Per-file, not per-path, because `git checkout "$ref" -- "$path"` cannot express a
  # deletion: it only restores paths $ref HAS. A file the PR deleted and the rewrite
  # recreated survives it silently, or aborts the script on the pathspec if $path is that
  # file itself.
  path_restored=false
  path_discarded=false

  while IFS= read -r file; do
    [ -n "$file" ] || continue

    # Byte-identical to the base means the action's rewrite and nothing else; anything
    # further is an edit the agent made on top of it.
    if [ -n "$base" ] && git diff --quiet "$base" -- "$file"; then
      path_restored=true
    else
      path_discarded=true
    fi

    if git cat-file -e "$ref:$file" 2>/dev/null; then
      git checkout "$ref" -- "$file"
    else
      # The PR deleted it and the rewrite recreated it; undoing that means removing it.
      git rm -f --ignore-unmatch -- "$file" >/dev/null
    fi
  done < <(git diff --name-only "$ref" -- "$path")

  [ "$path_restored" = true ] && restored+=("$path")
  [ "$path_discarded" = true ] && discarded+=("$path")

  # Something the agent added fresh. Left in place - deleting it would be a fresh silent
  # loss, which is the fault being fixed. A file the rewrite recreated is staged rather than
  # untracked, so it never reaches here.
  extra=$(git ls-files --others --exclude-standard -- "$path")

  if [ -n "$extra" ]; then
    while IFS= read -r file; do
      [ -n "$file" ] && added+=("$file")
    done <<<"$extra"
  fi
done

if [ ${#restored[@]} -gt 0 ]; then
  echo "Restored from $ref (claude-code-action had rewritten these to the base's copy): ${restored[*]}" >&2
fi

note=""

# An agent's edit here was written on top of the base's copy, not the PR's, so keeping it
# would clobber the PR's version just as the rewrite would - the agent never saw what it was
# overwriting. Discarding is the only safe outcome; discarding silently is the fault.
if [ ${#discarded[@]} -gt 0 ]; then
  echo "Discarded changes to governed paths: ${discarded[*]}" >&2
  list=$(printf '`%s`, ' "${discarded[@]}")
  note+=$'\n'"_Note: I changed ${list%, } and threw that away. Those paths are rewritten to the base branch's copy before I run — a PR does not get to change what governs the agent reading it — so my edit was made against the wrong base, and keeping it would have reverted your version. Change them yourself if they still need changing._"$'\n'
fi

# The one unresolvable case: no version in the PR to restore, so it is committed as-is.
# Flagged rather than deleted - least-bad, not safe.
if [ ${#added[@]} -gt 0 ]; then
  echo "Kept, but flagged, new files under governed paths: ${added[*]}" >&2
  list=$(printf '`%s`, ' "${added[@]}")
  note+=$'\n'"_Note: this commit adds ${list%, }, under a path that governs the agents. I have left it in rather than delete work, but it was not reviewed as such — check it before merging._"$'\n'
fi

[ -n "$note" ] && printf '%s' "$note"
exit 0
