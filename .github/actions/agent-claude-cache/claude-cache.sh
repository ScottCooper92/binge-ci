#!/usr/bin/env bash
# Lets a self-hosted runner reuse one Claude Code and Bun install across jobs. Unset
# BINGE_CI_CLAUDE_CODE_CACHE does nothing, and anything that goes wrong leaves the outputs empty so the
# claude-code-action step installs them itself. The five agent jobs run it through the action beside it.
set -uo pipefail
# No -e: this step only ever helps. Anything that goes wrong leaves its output empty, and the
# agent step then installs Claude Code and Bun itself, as it does on a runner without a cache.
cache=${BINGE_CI_CLAUDE_CODE_CACHE:-}
if [ -z "$cache" ]; then
  echo "BINGE_CI_CLAUDE_CODE_CACHE is not set: the agent step installs Claude Code itself."
  exit 0
fi
case "$cache" in
  /*) ;;
  *) echo "::warning::BINGE_CI_CLAUDE_CODE_CACHE must be an absolute path, not '$cache'. Not using the cache."; exit 0 ;;
esac
# The caller's curl limits are set by the step after this one; none apply to this download.
unset CURL_HOME
version_re='^[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z.]+)?$'

# The versions are the ones the pinned action would install. Its checkout is downloaded at job setup,
# next to the workspace, under the pin the `uses:` line names.
action_dir="${RUNNER_WORKSPACE%/*}/_actions/anthropics/claude-code-action/$ACTION_REF"
cc_ver=$(sed -nE 's/.*claudeCodeVersion = "([^"]+)".*/\1/p' "$action_dir/src/entrypoints/run.ts" 2> /dev/null | head -n 1)
bun_ver=$(sed -nE 's/^[[:space:]]*bun-version:[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/p' "$action_dir/action.yml" 2> /dev/null | head -n 1)
if ! [[ $cc_ver =~ $version_re ]] || ! [[ $bun_ver =~ $version_re ]]; then
  echo "::warning::Could not read the Claude Code and Bun versions from the pinned action (got '${cc_ver:-}' and '${bun_ver:-}'). Not using the cache."
  exit 0
fi

mkdir -p "$cache" || { echo "::warning::Could not create $cache. Not using the cache."; exit 0; }
# One download per version, however many jobs start at once. The lock only saves the duplicate
# download: the install below is a rename, so without it a race still leaves one clean winner.
if command -v flock > /dev/null; then
  exec 9> "$cache/.lock"
  flock -w 480 9 || { echo "::warning::Waited 8 minutes for another job's install in $cache. Not using the cache."; exit 0; }
fi
find "$cache" -maxdepth 1 -name '.tmp.*' -mmin +1440 -exec rm -rf {} + 2> /dev/null || true

# $1=name (claude or bun)  $2=version. Prints the cached path on success; says why on stderr and
# prints nothing otherwise.
ensure() {
  local name=$1 version=$2 dir tmp built
  dir="$cache/$name-$version"
  if [ -x "$dir/$name" ]; then
    # Recorded at install and checked on every use: this catches a truncated or corrupted file, not
    # a deliberate change by the user the runner runs as, who could change the record too.
    if (cd "$dir" && sha256sum --check --status "$name.sha256") 2> /dev/null; then
      touch "$dir" 2> /dev/null || true
      printf '%s' "$dir/$name"
      return 0
    fi
    echo "::warning::$dir does not match the checksum recorded when it was installed. Deleted; the agent step installs $name itself." >&2
    chmod -R u+w "$dir" 2> /dev/null || true
    rm -rf "$dir"
    return 1
  fi
  tmp=$(mktemp -d "$cache/.tmp.XXXXXX") || return 1
  mkdir "$tmp/home" "$tmp/out"
  # One attempt, bounded. `timeout` without --foreground, so the pipeline's curl and installer are
  # signalled with it and cannot outlive it. A download that does not fit is not retried here: the step
  # has its own cap, and the agent step's own install is the fallback.
  case "$name" in
    claude)
      HOME="$tmp/home" timeout --kill-after=10 480 \
        bash -c 'set -o pipefail; curl -fsSL https://claude.ai/install.sh | bash -s -- "$1"' _ "$version" \
        > "$tmp/log" 2>&1 ;;
    bun)
      HOME="$tmp/home" BUN_INSTALL="$tmp/home/.bun" timeout --kill-after=10 480 \
        bash -c 'set -o pipefail; curl -fsSL https://bun.sh/install | bash -s -- "bun-v$1"' _ "$version" \
        > "$tmp/log" 2>&1 ;;
  esac || {
    tail -n 20 "$tmp/log" >&2
    echo "::warning::Could not install $name $version into the cache. The agent step installs it itself." >&2
    rm -rf "$tmp"
    return 1
  }
  # The installer leaves a symlink into the temporary HOME; what is cached is the file it points at.
  case "$name" in
    claude) built=$(readlink -f "$tmp/home/.local/bin/claude" 2> /dev/null) ;;
    bun) built=$(readlink -f "$tmp/home/.bun/bin/bun" 2> /dev/null) ;;
  esac
  if [ -z "$built" ] || [ ! -f "$built" ] || [ ! -x "$built" ]; then
    echo "::warning::The $name installer left no executable where it was expected. The agent step installs it itself." >&2
    rm -rf "$tmp"; return 1
  fi
  cp "$built" "$tmp/out/$name" && (cd "$tmp/out" && sha256sum "$name" > "$name.sha256") || { rm -rf "$tmp"; return 1; }
  # A rename within the cache: atomic, and it fails if another job got there first, in which case
  # theirs is used and ours is discarded.
  if ! mv -T "$tmp/out" "$dir" 2> /dev/null; then
    rm -rf "$tmp"
    [ -x "$dir/$name" ] || return 1
  else
    chmod -R a-w "$dir"
    rm -rf "$tmp"
  fi
  printf '%s' "$dir/$name"
}

claude_path=$(ensure claude "$cc_ver") || claude_path=""
bun_path=$(ensure bun "$bun_ver") || bun_path=""

# Keep the version in use and the one other used most recently (every use touches its directory); the
# rest are pinned by nothing.
prune() { # $1=name  $2=version in use
  local d
  find "$cache" -maxdepth 1 -name "$1-*" -printf '%T@ %p\n' 2> /dev/null | sort -rn | cut -d' ' -f2- \
    | grep -vxF "$cache/$1-$2" | tail -n +2 | while IFS= read -r d; do
      chmod -R u+w "$d" 2> /dev/null || true
      rm -rf "$d"
    done
}
prune claude "$cc_ver"
prune bun "$bun_ver"

{
  echo "claude_path=$claude_path"
  echo "bun_path=$bun_path"
} >> "$GITHUB_OUTPUT"
echo "Claude Code ${claude_path:-(the action installs it)}"
echo "Bun ${bun_path:-(the action installs it)}"
