#!/usr/bin/env bash
# CacheCoin release helper: SHA-256 checksums and an optional GPG signature.
#
# Usage: bash scripts/release_sign.sh <dir-with-binaries> [gpg-key-id]
#
# Produces SHA256SUMS.txt (and SHA256SUMS.txt.asc when a key id is given), then
# verifies the checksums it just wrote. GPG signatures let people check that the
# binaries and the checksum file came from the same key; SHA-256 alone only
# proves the download was not corrupted in transit.
set -euo pipefail

DIR="${1:-}"
KEY="${2:-}"
if [ -z "${DIR}" ] || [ ! -d "${DIR}" ]; then
    echo "usage: $0 <dir-with-binaries> [gpg-key-id]"
    exit 1
fi
cd "${DIR}"

FILES=()
for name in cachecoind cachecoin-cli cachecoind.exe cachecoin-cli.exe; do
    [ -f "${name}" ] && FILES+=("${name}")
done
if [ "${#FILES[@]}" -eq 0 ]; then
    echo "[!] no cachecoind/cachecoin-cli binaries found in ${DIR}"
    exit 1
fi

sha256sum "${FILES[@]}" > SHA256SUMS.txt
sha256sum -c SHA256SUMS.txt
echo "[+] SHA256SUMS.txt:"
cat SHA256SUMS.txt

if [ -n "${KEY}" ]; then
    command -v gpg >/dev/null 2>&1 || { echo "[!] gpg not installed"; exit 1; }
    gpg --armor --detach-sign --local-user "${KEY}" SHA256SUMS.txt
    echo "[+] signature: SHA256SUMS.txt.asc"
fi

echo
echo "Publish the binaries together with SHA256SUMS.txt (and .asc) and tell people:"
echo "  sha256sum -c SHA256SUMS.txt"
echo "  gpg --verify SHA256SUMS.txt.asc SHA256SUMS.txt   # when signed"
