#!/bin/bash
# Verify a Tor bundle copy against the pinned Tor Expert Bundle.
# Usage: bash windows/verify_tor_bundle.sh --tor-dir <dir> [--tarball <file>]
# Reads url and sha256 from windows/TOR-PIN.txt next to this script.
#
# <dir> may be either the package's tor/ directory (tor.exe, data/,
# docs/, pluggable_transports/ at its top level) or an extracted Expert
# Bundle root (tor/, data/, docs/ at its top level).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
PIN="$HERE/TOR-PIN.txt"
TOR_DIR=""; TARBALL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tor-dir) TOR_DIR="$2"; shift 2 ;;
    --tarball) TARBALL="$2"; shift 2 ;;
    *) echo "unknown option: $1"; exit 2 ;;
  esac
done
[ -n "$TOR_DIR" ] || { echo "usage: $0 --tor-dir <dir> [--tarball <file>]"; exit 2; }
TOR_DIR="${TOR_DIR%/}"
[ -n "$TOR_DIR" ] || TOR_DIR="/"
[ -d "$TOR_DIR" ] || { echo "no such tor dir: $TOR_DIR"; exit 2; }
[ -f "$PIN" ] || { echo "missing TOR-PIN.txt next to this script"; exit 2; }
URL="$(grep -m1 '^url:' "$PIN" | awk '{print $2}')"
WANT="$(grep -m1 '^sha256:' "$PIN" | awk '{print $2}')"
[ -n "$URL" ] && [ -n "$WANT" ] || { echo "TOR-PIN.txt has no url or sha256 line"; exit 2; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
if [ -z "$TARBALL" ]; then
  TARBALL="$WORK/tor-expert.tar.gz"
  echo "downloading $URL"
  curl -fsSL --max-time 900 "$URL" -o "$TARBALL"
fi
GOT="$(sha256sum "$TARBALL" | cut -d' ' -f1)"
if [ "$GOT" != "$WANT" ]; then echo "ARCHIVE-SHA256-MISMATCH got=$GOT want=$WANT"; exit 1; fi
echo "archive sha256 OK ($GOT)"
tar -xzf "$TARBALL" -C "$WORK"
[ -f "$WORK/tor/tor.exe" ] || { echo "unexpected archive layout: no tor/tor.exe"; exit 1; }
resolve() {
  local rel="$1" c
  for c in "$WORK/$rel" "$WORK/tor/$rel"; do
    if [ -f "$c" ]; then echo "$c"; return 0; fi
  done
  return 1
}
bad=0; miss=0; total=0
while IFS= read -r f; do
  rel="${f#$TOR_DIR/}"; total=$((total+1))
  c="$(resolve "$rel")" || { echo "NOT-IN-BUNDLE: $rel"; miss=$((miss+1)); continue; }
  a=$(sha256sum "$f" | cut -d' ' -f1); b=$(sha256sum "$c" | cut -d' ' -f1)
  if [ "$a" != "$b" ]; then echo "MISMATCH: $rel"; bad=$((bad+1)); fi
done < <(find "$TOR_DIR" -type f | sort)
expected="$(find "$WORK" -type f ! -name 'tor-expert.tar.gz' | wc -l | tr -d ' ')"
echo "package_files=$total bundle_files=$expected mismatches=$bad not_in_bundle=$miss"
if [ "$total" = "0" ]; then echo "TOR-BUNDLE-VERIFY-FAIL (empty tor dir)"; exit 1; fi
if [ "$bad" != "0" ] || [ "$miss" != "0" ] || [ "$total" != "$expected" ]; then
  echo "TOR-BUNDLE-VERIFY-FAIL"
  exit 1
fi
echo "TOR-BUNDLE-VERIFY-OK"
