#!/usr/bin/env bash
# ==============================================================================
# CacheCoin (CCCN) - start a local MAINNET node in the background
#
# Uses ~/.cachecoin (config copied from config/cachecoin.conf on first run), waits
# until RPC answers and prints the chain status. Stop it with: cachecoin-cli stop
# For a throw-away test chain use: cachecoind -regtest (see tests/).
# ==============================================================================

set -euo pipefail

DATA_DIR="${HOME}/.cachecoin"
umask 077
# The shipped config is Tor-only: without a local Tor proxy the node starts
# isolated with no peers. Fail fast with a clear message instead.
if [ ! -S /run/tor/socks 2>/dev/null ] && ! (echo > /dev/tcp/127.0.0.1/9050) 2>/dev/null; then
    echo "[!] No Tor proxy on 127.0.0.1:9050. Start Tor first (this config is Tor-only)."
    exit 1
fi
install -d -m 0700 "${DATA_DIR}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/cachecoin.conf"

if [ ! -f "${DATA_DIR}/cachecoin.conf" ]; then
    echo "[*] Copying initial configuration to ${DATA_DIR}/cachecoin.conf"
    install -m 0600 "${CONFIG_FILE}" "${DATA_DIR}/cachecoin.conf"
fi

echo "[*] Starting cachecoind in the background..."
cachecoind -datadir="${DATA_DIR}" -conf="${DATA_DIR}/cachecoin.conf" -daemonwait

echo "[+] Node Status:"
cachecoin-cli -datadir="${DATA_DIR}" -rpcwait getblockchaininfo
