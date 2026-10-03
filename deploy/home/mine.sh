#!/usr/bin/env bash
# ==============================================================================
# CacheCoin home miner: repeatedly asks the local cachecoind to mine one block to
# your payout address (RandomX, CPU).
#
# Usage:  bash deploy/home/mine.sh <payout-address> [parallel-miners]
#   payout-address   your own cccn1... address (never let a tool invent one)
#   parallel-miners  RPC mining loops to run at once (default 1); keep it below
#                    rpcthreads (8 in deploy/home/cachecoin.conf)
#
# Safety checks before mining:
#   - node is on mainnet and the address is valid
#   - node has at least one peer (your VPS), so mined blocks are actually relayed
# Each call tries a limited number of nonces and then takes a fresh template, so a
# miner never keeps working on a tip that another block has already replaced.
# ==============================================================================
set -euo pipefail

ADDR="${1:-}"
PARALLEL="${2:-1}"
if ! [[ "${PARALLEL}" =~ ^[1-9][0-9]*$ ]] || [ "${PARALLEL}" -gt 8 ]; then
    echo "usage: $0 <payout-address> [parallel-miners 1-8]"
    exit 1
fi
TRIES_PER_CALL=500   # ~10-15 s of light-mode RandomX on one core

if [ -z "${ADDR}" ]; then
    echo "usage: $0 <payout-address> [parallel-miners]"
    exit 1
fi

CLI=(cachecoin-cli -rpcwait)

if ! "${CLI[@]}" getblockchaininfo | grep -q '"chain": "main"'; then
    echo "[!] The local node is not running on mainnet."
    exit 1
fi
if ! "${CLI[@]}" validateaddress "${ADDR}" | grep -q '"isvalid": true'; then
    echo "[!] Not a valid CacheCoin address: ${ADDR}"
    exit 1
fi
# getconnectioncount that fails safe: prints a number, or returns 1 on RPC
# failure / non-numeric output (never let garbage compare as "connected").
peer_count() {
    local n
    n="$("${CLI[@]}" getconnectioncount 2>/dev/null)" || return 1
    [[ "${n}" =~ ^[0-9]+$ ]] || return 1
    echo "${n}"
}
if ! n=$(peer_count) || [ "${n}" -lt 1 ]; then
    echo "[!] No peers. The node is not connected to your VPS yet (check Tor and the"
    echo "    connect= line in ~/.cachecoin/cachecoin.conf). Refusing to mine blocks"
    echo "    that nobody else would receive."
    exit 1
fi

echo "Mining to ${ADDR} with ${PARALLEL} loop(s). Press Ctrl+C to stop."
# Stop tracked loops on Ctrl+C (kill 0 would also kill our own shell setup).
PIDS=()
cleanup() {
    trap - INT TERM
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
    wait
}
trap cleanup INT TERM

mine_loop() {
    local id="$1"
    while true; do
        # Pause while the node has no peer (VPS or Tor down): blocks mined alone would
        # only start a private branch that the rest of the network has to reconcile.
        if ! n=$(peer_count) || [ "${n}" -lt 1 ]; then
            sleep 15
            continue
        fi
        # Clock guard: if the best block's timestamp is in the future (local clock
        # behind), every mined block is rejected as time-too-new and the work is
        # wasted. One-sided check, five-minute tolerance, never blocks a synced node.
        best="$("${CLI[@]}" getbestblockhash 2>/dev/null)" || { sleep 5; continue; }
        tip_time="$("${CLI[@]}" getblockheader "${best}" 2>/dev/null | sed -n 's/.*"time": \([0-9][0-9]*\).*/\1/p')"
        now_epoch="$(date +%s)"
        if [ -n "${tip_time}" ] && [ "$((tip_time - now_epoch))" -gt 300 ]; then
            echo "[!] The chain tip is more than 5 minutes ahead of this machine's clock;" >&2
            echo "    new blocks would be rejected as time-too-new. Fix the clock (NTP) and retry." >&2
            sleep 30
            continue
        fi
        # generatetoaddress prints [] when no block was found and exits non-zero
        # on RPC failure: only non-empty success output counts as a block.
        if found="$("${CLI[@]}" generatetoaddress 1 "${ADDR}" "${TRIES_PER_CALL}" 2>/dev/null)"; then
            if [ "$(echo "${found}" | tr -d '[:space:][]')" != "" ]; then
                height="$("${CLI[@]}" getblockcount 2>/dev/null || echo "?")"
                echo "$(date -u +%H:%M:%S) [loop ${id}] block ${height} found: $(echo "${found}" | tr -d '[:space:][]"')"
            fi
        else
            sleep 5   # node restarting or busy: try again, never give up the loop
        fi
    done
}

for i in $(seq 1 "${PARALLEL}"); do
    mine_loop "${i}" & PIDS+=($!)
    sleep 1   # spread the calls out; every call starts at a random nonce, so loops never repeat each other's work
done
wait
