#!/usr/bin/env bash
#
# Downloads the pinned actionlint release into $1 and verifies it against its published SHA-256.
#
# Needs VERSION, SHA256 and GH_TOKEN in the environment. The asset is fetched with the job's token,
# not anonymously: on 2026-11-09 GitHub's anonymous-traffic incident served a 504 HTML page for
# anonymous release downloads and the checksum failed in every consumer. An authenticated request
# is rate-limited per token instead of shed with the anonymous crowd.
#
# A truncated or error-page download passes the transfer and fails here, so the check gets one fresh
# download before it fails the job. A second failure is a real one.
set -euo pipefail

dir=${1:?usage: download-actionlint.sh DIR}
: "${VERSION:?}" "${SHA256:?}" "${GH_TOKEN:?}"
asset="actionlint_${VERSION}_linux_amd64.tar.gz"
tarball="$dir/$asset"
delay=${RETRY_DELAY:-2}

fetch() {
  rm -f "$tarball"
  local n
  for n in 1 2 3; do
    if gh release download "v${VERSION}" --repo rhysd/actionlint --pattern "$asset" --dir "$dir" --clobber; then
      return 0
    fi
    echo "::warning::download attempt $n of 3 failed"
    sleep "$delay"
  done
  echo "::error::could not download $asset from the rhysd/actionlint release v${VERSION}"
  return 1
}

# Fails with a message that names the problem. An HTML error page is the case that has happened.
verify() {
  if ! gzip -t "$tarball" 2>/dev/null; then
    echo "::error::$asset is not a gzip tarball (the response was probably an error page from GitHub). First bytes:"
    head -c 200 "$tarball" | tr -c '[:print:]\n' '?' || true
    echo
    return 1
  fi
  if ! echo "${SHA256}  $tarball" | sha256sum -c - ; then
    echo "::error::$asset does not match the pinned SHA-256"
    return 1
  fi
}

fetch
if ! verify; then
  echo "::warning::$asset failed verification, downloading once more"
  fetch
  verify
fi
tar xzf "$tarball" -C "$dir" actionlint
