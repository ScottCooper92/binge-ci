#!/usr/bin/env bash
#
# Runs the actionlint action's download-and-verify script against a stubbed `gh`, one case per
# outcome it has to tell apart: a good tarball, a checksum mismatch (one re-fetch, then failure), a
# mismatch that the re-fetch fixes, an HTML error page, and a transfer that keeps failing.
# The real download needs the network and a release; a change to the script would otherwise surface
# only in a consumer's live run.
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/.github/actions/actionlint/download-actionlint.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

mkdir "$work/bin" "$work/src"
printf '#!/bin/sh\n' > "$work/src/actionlint"
tar czf "$work/good.tgz" -C "$work/src" actionlint
printf 'tampered' | gzip > "$work/other.tgz"
printf '<!DOCTYPE html><html><body>504 Gateway Time-out</body></html>\n' > "$work/error.html"
sha=$(sha256sum "$work/good.tgz" | cut -d' ' -f1)

# The stub copies the next file named in $FAKE_QUEUE (one per line) into --dir and counts its calls.
# An empty line is a failed transfer.
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
dir='' ; pattern=''
while [ $# -gt 0 ]; do
  case $1 in
    --dir) dir=$2; shift ;;
    --pattern) pattern=$2; shift ;;
  esac
  shift
done
[ -n "${GH_TOKEN:-}" ] || { echo "stub: no token" >&2; exit 3; }
n=$(( $(cat "$FAKE_COUNT" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FAKE_COUNT"
file=$(sed -n "${n}p" "$FAKE_QUEUE")
[ -n "$file" ] || exit 1
cp "$file" "$dir/$pattern"
STUB
chmod +x "$work/bin/gh"

# run NAME EXPECTED_STATUS EXPECTED_CALLS EXPECTED_TEXT FILE...
run() {
  local name=$1 want_rc=$2 want_calls=$3 want_text=$4 out rc calls
  shift 4
  printf '%s\n' "$@" > "$work/queue"
  rm -f "$work/count"
  mkdir -p "$work/out"
  rm -rf "${work:?}/out"/*
  set +e
  out=$(PATH="$work/bin:$PATH" FAKE_QUEUE="$work/queue" FAKE_COUNT="$work/count" \
    VERSION=1.7.12 SHA256="$sha" GH_TOKEN=token RETRY_DELAY=0 "$script" "$work/out" 2>&1)
  rc=$?
  set -e
  calls=$(cat "$work/count" 2>/dev/null || echo 0)
  if [ "$rc" -ne "$want_rc" ] || [ "$calls" -ne "$want_calls" ] || ! grep -qF -- "$want_text" <<<"$out"; then
    echo "FAIL $name: exit $rc (want $want_rc), $calls fetch(es) (want $want_calls), wanted text: $want_text"
    echo "$out" | sed 's/^/     /'
    failures=$((failures + 1))
  else
    echo "ok   $name"
  fi
}

good=$work/good.tgz
run "good tarball passes and is extracted" 0 1 "OK" "$good"
[ -f "$work/out/actionlint" ] || { echo "FAIL good tarball: actionlint was not extracted"; failures=$((failures + 1)); }
run "mismatch is re-fetched once, then fails" 1 2 "does not match the pinned SHA-256" "$work/other.tgz" "$work/other.tgz" "$good"
run "mismatch that the re-fetch fixes passes" 0 2 "downloading once more" "$work/other.tgz" "$good"
run "HTML error page fails with the clear message" 1 2 "is not a gzip tarball" "$work/error.html" "$work/error.html" "$good"
run "HTML page that the re-fetch fixes passes" 0 2 "OK" "$work/error.html" "$good"
run "a transfer that keeps failing stops" 1 3 "could not download" "" "" ""

if [ "$failures" -gt 0 ]; then
  echo "$failures case(s) failed"
  exit 1
fi
