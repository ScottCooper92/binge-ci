#!/usr/bin/env bash
#
# A bounded retry for gh, on a connection error only. Sourced, not run: it defines `gh` as a
# function, so every gh call in the sourcing shell after this line goes through it. `command gh`
# reaches the real one, for a call that has its own retry and must not be retried twice.
#
# A runner on a flaky network can fail a call with `error connecting to api.github.com` some 20s
# in. That call never reached GitHub, so trying again is safe, a POST included. Everything else is
# passed through on the first failure: an HTTP status is GitHub's answer, and a 4xx or a refused
# merge stays refused however often it is asked. So the match is kept to failures that happen
# before a request is sent. A connection cut mid-response is not among them, because the request
# may already have landed.
#
# The first call and up to three retries, 5, 15 and 30s apart. A failed attempt's stdout is
# dropped, so a page that printed before the connection died is not printed twice. The last
# attempt's stdout and stderr pass through, with its exit status, so a caller reading gh's
# output on a non-zero exit (`gh pr checks`) still sees it.
#
# A call that reads its body from stdin (`--body-file -`, `--input -`) has it read once and fed to
# every attempt; a retry would otherwise post an empty body. Only then, because a call that does
# not read stdin must not swallow a loop's.

GH_RETRY_WAITS=(5 15 30)

# True when the stderr in $1 is a failure to connect, and carries no HTTP status.
gh_connection_error() {
  ! grep -qE '\(HTTP [0-9]{3}\)|^HTTP [0-9]{3}' "$1" \
    && grep -qiE 'error connecting to|dial tcp|TLS handshake timeout|no such host|connection refused' "$1"
}

gh() {
  local out err in=/dev/null status wait arg
  out=$(mktemp)
  err=$(mktemp)
  for arg in "$@"; do
    if [ "$arg" = - ]; then
      in=$(mktemp)
      cat >"$in"
      break
    fi
  done
  for wait in "${GH_RETRY_WAITS[@]}" last; do
    status=0
    command gh "$@" <"$in" >"$out" 2>"$err" || status=$?
    if [ "$status" -eq 0 ] || [ "$wait" = last ] || ! gh_connection_error "$err"; then
      break
    fi
    echo "gh ${1:-}: could not connect; retrying in ${wait}s." >&2
    sleep "$wait"
  done
  cat "$out"
  cat "$err" >&2
  rm -f "$out" "$err"
  [ "$in" = /dev/null ] || rm -f "$in"
  return "$status"
}
