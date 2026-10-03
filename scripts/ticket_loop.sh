#!/usr/bin/env bash
# ==============================================================================
# CacheCoin (CCCN) - mine entropy tickets (PER) in a loop against a local node
#
# Every attempt is a real RandomX search at 1/16 of the block target. There is no
# guaranteed payout: the per-ticket rate is pool/tickets for the epoch, and fees
# may be zero. Read doc/economics.md before pointing this at an address that
# matters, and back up the key for the address first.
#
# Usage: bash scripts/ticket_loop.sh <cccn1-address> [sleep-seconds] [--once]
#   sleep defaults to 5 seconds between attempts
#   --once makes a single attempt and exits (useful for testing)
#
# The script uses cachecoin-cli from PATH. Point it at another node with
# CACHECOIN_CLI_ARGS, for example:
#   CACHECOIN_CLI_ARGS="-regtest -datadir=/tmp/n -rpcport=39201" \
#     bash scripts/ticket_loop.sh <address> 0 --once
# ==============================================================================
set -euo pipefail

ADDR="${1:-}"
SLEEP="${2:-5}"
ONCE=0
[ "${3:-}" = "--once" ] && ONCE=1
CLI_ARGS=${CACHECOIN_CLI_ARGS:-}   # word-split on purpose: extra cli flags

if [ -z "${ADDR}" ]; then
    echo "usage: $0 <cccn1-address> [sleep-seconds] [--once]"
    exit 2
fi
command -v cachecoin-cli >/dev/null 2>&1 || {
    echo "[!] cachecoin-cli not found in PATH"
    exit 1
}

# Refuse to mine to an address the node does not consider valid. A ticket is a
# bearer claim on the payout script: a payout to a key you do not hold is lost.
valid=$(cachecoin-cli ${CLI_ARGS} validateaddress "${ADDR}" 2>/dev/null || true)
case "${valid}" in
    *'"isvalid": true'*) ;;
    *) echo "[!] ${ADDR} is not a valid address for this node"; exit 1 ;;
esac

# A bounded maxtries keeps the server-side search from outliving the client: the
# RPC default is 1,000,000 tries (hours), and the client would time out at 900 s
# while the search keeps running and holds an RPC thread. 20000 tries takes
# roughly 5-10 minutes with the JIT and about 45 minutes in interpreter mode;
# -rpcclienttimeout=0 waits for it.
echo "[i] mining tickets to ${ADDR}; Ctrl-C to stop"
while :; do
    out=$(cachecoin-cli -rpcclienttimeout=0 ${CLI_ARGS} generateperticket "${ADDR}" 20000 2>&1) || {
        echo "[!] generateperticket failed: ${out}"
        sleep "${SLEEP}"
        continue
    }
    case "${out}" in
        *'"found": true'*)
            echo "[+] $(date -u +%Y-%m-%dT%H:%M:%SZ) ticket found: ${out}" ;;
    esac
    [ "${ONCE}" = "1" ] && break
    sleep "${SLEEP}"
done
