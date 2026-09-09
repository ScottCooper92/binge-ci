#!/usr/bin/env bash
# Undo claude-code-action's rewrite of the files that govern an agent, before an author
# job commits the working tree.
#
# The action treats a PR head as untrusted and, just before starting the agent, overwrites
# the paths below with the base branch's copy - otherwise a PR could edit the agent's own
# instructions and have the agent execute them. It says so in the step log ("Restoring
# .claude, .mcp.json, ... from origin/<base> (PR head is untrusted)") and it does it in the
# WORKING TREE, which is the part that bites: the author jobs then `git add -A`, so the
# rewrite lands in the bot's commit as though the agent had made it, reverting the PR's own
# changes to those files with nothing on the PR saying so.
#
# That is Binge#2029. On #2027 it deleted the 24 lines the PR had added to
# .claude/skills/create-pr/SKILL.md, and the reply the same job posted said the file was
# "left as-is" - truthfully, from the agent's point of view: it had never touched it.
#
# Usage: restore-agent-governed-paths.sh <ref>
#   <ref> is what the job checked out (origin/$BRANCH) - the PR as pushed, and so always the
#   right content for these paths. Prints a markdown note on stdout when it discarded
#   anything that was NOT simply the action's rewrite, and nothing at all on the ordinary
#   path. Progress goes to stderr, for the step log.
#
# The base branch the action rewrites FROM is read from $GOVERNED_BASE_REF (default
# origin/main). It is the discriminator for "this is the action's rewrite and nothing else",
# so a wrong value does not corrupt anything - it just reports every restore instead of only
# the interesting ones.
#
# Usage: restore-agent-governed-paths.sh --list
#   Prints the governed paths, one per line, and exits. This file is the single definition
#   of that list; a caller that needs to reason about the same paths (author-conflicts.yml
#   refusing to resolve a conflict in one) reads them from here rather than keeping a second
#   copy that can narrow silently. #2050.
set -euo pipefail

# Kept in step with the pinned claude-code-action SHA in the author workflows, which is what
# fixes this list - it cannot drift without someone bumping that pin. A path absent from the
# repo costs nothing to list: the diff below simply never fires for it, which is why one list
# serves every consuming repo rather than each keeping its own.
#
# $GOVERNED_EXTRA_PATHS appends repo-specific ones, newline-separated. Appends only: a repo
# cannot narrow this list, because narrowing it is precisely the silent loss the whole script
# exists to prevent.
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
  # Per-file, not per-path: a path-level `git diff --quiet` plus a single `git checkout
  # "$ref" -- "$path"` cannot express a deletion. If the PR deleted a file under here and
  # the action's rewrite recreated it from master, that recreated file has no counterpart in
  # $ref at all - `git checkout "$ref" -- "$path"` only ever restores paths $ref has, so it
  # silently keeps the resurrected file (directory case), or - if $path itself is a single
  # file $ref has none of - fails the pathspec outright and aborts the script (file case).
  path_restored=false
  path_discarded=false

  while IFS= read -r file; do
    [ -n "$file" ] || continue

    # Byte-identical to the base is the whole discriminator: that is the action's rewrite and
    # nothing else. Anything further is an edit the agent made on top of it.
    if [ -n "$base" ] && git diff --quiet "$base" -- "$file"; then
      path_restored=true
    else
      path_discarded=true
    fi

    if git cat-file -e "$ref:$file" 2>/dev/null; then
      git checkout "$ref" -- "$file"
    else
      # $ref has no version of this file to restore - the PR deleted it and the action's
      # rewrite recreated it from master. Undoing that means removing it, not checking it out.
      git rm -f --ignore-unmatch -- "$file" >/dev/null
    fi
  done < <(git diff --name-only "$ref" -- "$path")

  [ "$path_restored" = true ] && restored+=("$path")
  [ "$path_discarded" = true ] && discarded+=("$path")

  # Untracked and not ignored under a governed path - something the agent added fresh. Left
  # in place: deleting it here would be a fresh silent loss, which is the fault being fixed,
  # not a fix for it. (A file the action recreated from master is staged by its `git
  # checkout`, not untracked, so it never lands here - it's handled by the loop above.)
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

# An edit the agent made to one of these cannot be kept. It was written on top of master's
# copy rather than the PR's, so committing it would clobber the PR's version just as surely
# as the rewrite would - the agent never saw what it was overwriting. Discarding it is the
# only safe outcome; discarding it silently is the failure this guard exists to end.
if [ ${#discarded[@]} -gt 0 ]; then
  echo "Discarded changes to governed paths: ${discarded[*]}" >&2
  list=$(printf '`%s`, ' "${discarded[@]}")
  note+=$'\n'"_Note: I changed ${list%, } and threw that away. Those paths are rewritten to the base branch's copy before I run — a PR does not get to change what governs the agent reading it — so my edit was made against the wrong base, and keeping it would have reverted your version. Change them yourself if they still need changing._"$'\n'
fi

# A new file under a governed path is the one case that is NOT resolvable here: it has no
# version in the PR to restore, so it is committed as-is. Say so, because the same "a PR
# does not get to change what governs the agent" reasoning applies to it and a human should
# decide - this is the least-bad option, not a safe one.
if [ ${#added[@]} -gt 0 ]; then
  echo "Kept, but flagged, new files under governed paths: ${added[*]}" >&2
  list=$(printf '`%s`, ' "${added[@]}")
  note+=$'\n'"_Note: this commit adds ${list%, }, under a path that governs the agents. I have left it in rather than delete work, but it was not reviewed as such — check it before merging._"$'\n'
fi

[ -n "$note" ] && printf '%s' "$note"
exit 0
