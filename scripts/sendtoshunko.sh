#!/usr/bin/env bash
# ==============================================================================
# CacheCoin - send a payment through the Shunko Protocol
#
# Usage: bash scripts/sendtoshunko.sh <address> <amount> [wallet-name]
#
# 1. The wallet builds and signs the payment WITHOUT broadcasting it
#    (send ... add_to_wallet=false; the coins are locked so they are not spent twice).
# 2. shunkobroadcast hands it to two other nodes, each over its own one-shot Tor
#    connection. Your node never announces it, so nobody can link it to your node.
# 3. It appears in your wallet once it is mined (about a minute).
#
# Needs a node running with Tor (proxy=127.0.0.1:9050, see deploy/). Use a new
# receiving address for every payment: the ledger itself is public.
# ==============================================================================
set -euo pipefail

ADDR="${1:-}"
AMOUNT="${2:-}"
WALLET="${3:-}"
if [ -z "${ADDR}" ] || [ -z "${AMOUNT}" ]; then
    echo "usage: $0 <address> <amount> [wallet-name]"
    exit 1
fi

CLI=(cachecoin-cli -rpcwait)
[ -n "${WALLET}" ] && CLI+=(-rpcwallet="${WALLET}")

if ! "${CLI[@]}" validateaddress "${ADDR}" | grep -q '"isvalid": true'; then
    echo "[!] Not a valid CacheCoin address: ${ADDR}"
    exit 1
fi

# Strict amount check before building JSON: plain decimal with up to 8 places.
# Prevents injection of extra outputs via AMOUNT (e.g. '1, "evil": 5').
if ! [[ "${AMOUNT}" =~ ^[0-9]+(\.[0-9]{1,8})?$ ]]; then
    echo "[!] Invalid amount '${AMOUNT}': expected a decimal like 1.25 with up to 8 places"
    exit 1
fi
if ! awk -v a="${AMOUNT}" 'BEGIN{exit !(a > 0 && a <= 21020400)}'; then
    echo "[!] Invalid amount '${AMOUNT}': out of range (0, 21020400]"
    exit 1
fi

RESULT="$("${CLI[@]}" -named send outputs="{\"${ADDR}\": ${AMOUNT}}" add_to_wallet=false lock_unspents=true)"
# Robust JSON parse with python3 when available, grep fallback otherwise.
if command -v python3 >/dev/null 2>&1; then
    HEX="$(printf '%s' "${RESULT}" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("hex",""))' || true)"
else
    HEX="$(echo "${RESULT}" | grep -o '"hex": "[0-9a-f]*"' | cut -d'"' -f4)"
fi
if [ -z "${HEX}" ] || ! echo "${RESULT}" | grep -q '"complete": true'; then
    echo "[!] The wallet could not create and sign the payment:"
    echo "${RESULT}"
    exit 1
fi

if ! cachecoin-cli -rpcwait shunkobroadcast "${HEX}"; then
    echo "[!] The hand-over did not complete. The transaction may still have reached a"
    echo "    node, so do NOT build a new payment for the same debt. Retry the same raw"
    echo "    transaction first:  cachecoin-cli shunkobroadcast ${HEX}"
    exit 1
fi
echo "[+] Sent through Shunko. It shows up in your wallet once it is mined."
