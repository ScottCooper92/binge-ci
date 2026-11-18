#!/usr/bin/env bash
#
# Bounds every network call the agent makes from a shell: curl gets a connect and a total timeout,
# git gives up on a stalled transfer. A hung call would otherwise hold the job to its timeout.
# Environment: RUNNER_TEMP, GITHUB_ENV.
set -euo pipefail
home="$RUNNER_TEMP/agent-curl-home"
mkdir -p "$home"
printf '%s\n' 'connect-timeout = 10' 'max-time = 120' > "$home/.curlrc"
{
  echo "CURL_HOME=$home"
  echo 'GIT_HTTP_LOW_SPEED_LIMIT=1000'
  echo 'GIT_HTTP_LOW_SPEED_TIME=60'
} >> "$GITHUB_ENV"
