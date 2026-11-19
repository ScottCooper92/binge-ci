#!/usr/bin/env bash
#
# Fails when a create-github-app-token step asks for a permission the app's installation does not
# grant.
#
# A `permission-*` input narrows the token, but it can only narrow: ask for one the installation
# lacks and the mint fails with "The permissions requested are not granted to this installation".
# The job then dies before its agent runs, in every consuming repository at once. actionlint cannot
# see it, and neither can a PR here: nothing in a run of this repository's CI reads an app's grant.
#
# So the grants are written down below, keyed by the secret that names the app. They mirror each
# installation's settings, and move only when those do. A mint that asks for no `permission-*` gets
# the whole installation and is not checked. One that does, from an app not listed here, fails until
# that app's grant is added.
#
# A second rule holds the write token of the author bots and of the submodule bump to the calling
# repository. With `private_submodules` set, a mint that lists those repositories would give an agent
# write access to each one, so in those workflows a mint that can write must not set `repositories:`,
# and the mint that names `private_submodules` must ask for exactly `permission-contents: read`.
#
# CHECK_ROOT names another tree to check, for tools/test-token-permissions.sh's fixtures.
set -uo pipefail
cd "${CHECK_ROOT:-$(dirname "$0")/..}" || exit 1

python3 - <<'PY'
import glob, re, sys

# The author app's installation: contents, pull requests, workflows and actions, plus the metadata every
# app gets. It has no Issues permission; a PR's conversation is read through pull requests. Actions write
# is for author-conflicts.yml, which dispatches the consumer's record-screenshots workflow; the mint that
# does it asks for no `permission-*`, so it gets the whole installation, and narrowing it would drop the
# contents write the push needs.
GRANTS = {
    "AUTHOR_APP_ID": {"contents", "pull-requests", "workflows", "actions", "metadata"},
    # The reviewer app is installed on the owner's repositories with read access to contents. Only the
    # read-only submodule mints narrow its token, and they ask for contents alone.
    "REVIEWER_APP_ID": {"contents", "metadata"},
}

# The workflows whose write token must reach the calling repository alone.
AUTHOR_BOTS = {"author-ci-fix.yml", "author-comments.yml", "author-conflicts.yml", "author-retarget.yml",
               "submodule-bump.yml", "record-screenshots.yml"}
REPOS = re.compile(r'^\s*repositories:(.*)$')

USES = re.compile(r'^(\s*(?:-\s+)?)uses:\s*actions/create-github-app-token@')
APP = re.compile(r'^\s*app-id:\s*\$\{\{\s*secrets\.([A-Za-z0-9_]+)\s*\}\}')
PERM = re.compile(r'^\s*permission-([a-z-]+):\s*(\S*)')

bad = 0
mints = 0
files = sorted(glob.glob('.github/workflows/*.yml') + glob.glob('.github/actions/*/action.yml'))
for path in files:
    lines = open(path).read().splitlines()
    for i, line in enumerate(lines):
        match = USES.match(line)
        if not match:
            continue
        mints += 1
        # The column the step's keys start at, past a `- ` the `uses:` line may open the step with.
        # Anything less indented than that - a sibling step's dash, the next job - ends the step.
        key_col = len(match.group(1))
        start = i
        if '-' not in match.group(1):
            while start > 0 and not lines[start].lstrip().startswith('- '):
                start -= 1
        app, perms, repos = None, [], []
        for j in range(start, len(lines)):
            text = lines[j]
            if j > i and text.strip() and not text.lstrip().startswith('#'):
                if len(text) - len(text.lstrip()) < key_col:
                    break
            found = APP.match(text)
            if found:
                app = found.group(1)
            found = PERM.match(text)
            if found:
                perms.append((j + 1, found.group(1), found.group(2)))
            found = REPOS.match(text)
            if found:
                repos.append((j + 1, found.group(1)))
        if path.rsplit('/', 1)[-1] in AUTHOR_BOTS and app == "AUTHOR_APP_ID":
            widened = [n for n, value in repos if value.strip() and not value.strip().startswith('#')]
            names_submodules = any('private_submodules' in value for _, value in repos)
            # A mint can write unless every permission it asks for is `read`; one that asks for none
            # inherits the installation's whole grant.
            can_write = not perms or any(value != "read" for _, _, value in perms)
            if can_write:
                # A token that can write must reach the calling repository alone.
                for n in widened:
                    print(f"::error file={path},line={n}::This author-app mint can write and sets "
                          "`repositories:`, so it would reach more than the calling repository. Mint the "
                          "private submodules' token separately, with permission-contents: read.")
                    bad += 1
            if names_submodules and sorted((name, value) for _, name, value in perms) != [("contents", "read")]:
                print(f"::error file={path},line={i + 1}::The mint for private_submodules has to ask for "
                      "permission-contents: read and nothing else.")
                bad += 1
        if not perms:
            continue
        granted = GRANTS.get(app)
        if granted is None:
            print(f"::error file={path},line={i + 1}::This mint narrows its token, but its app "
                  f"({app or 'unknown'}) has no grant recorded in tools/check-token-permissions.sh. "
                  "Add the installation's permissions there.")
            bad += 1
            continue
        for line_no, perm, _ in perms:
            if perm not in granted:
                print(f"::error file={path},line={line_no}::permission-{perm} is not granted to "
                      f"the {app} installation, so this mint fails and the job dies before its "
                      f"agent runs. It grants: {', '.join(sorted(granted))}.")
                bad += 1

if mints == 0:
    print("::error::No create-github-app-token step found. The check is reading the wrong files.")
    sys.exit(1)
if bad:
    sys.exit(1)
print(f"{mints} token mints checked; every permission asked for is granted.")
PY
