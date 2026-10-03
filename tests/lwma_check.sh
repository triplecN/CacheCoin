#!/usr/bin/env bash
# Build tests/lwma_check.cpp against a patched, built CacheCoin source tree and run it.
# The check uses the mainnet powLimit and block spacing read from that tree.
#
# Usage: bash tests/lwma_check.sh [source-dir]
#   source-dir  defaults to ~/cachecoin-build/cachecoin-v31.1 (created by scripts/build_linux.sh)
set -euo pipefail

SRC="${1:-${HOME}/cachecoin-build/cachecoin-v31.1}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARAMS="${SRC}/src/kernel/chainparams.cpp"

[ -f "${PARAMS}" ] || { echo "[!] ${PARAMS} not found: build the node first"; exit 1; }
[ -f "${SRC}/src/pow.cpp" ] || { echo "[!] ${SRC}/src/pow.cpp not found: build the node first"; exit 1; }

LIBDIR="${SRC}/build/lib"
STD="-std=c++20"
CONFIG_INC="-I${SRC}/build/src"
[ -f "${LIBDIR}/libbitcoin_consensus.a" ] || {
    echo "[!] ${LIBDIR}/libbitcoin_consensus.a not found: build the node first (scripts/build_linux.sh)"
    exit 1
}

for f in "${LIBDIR}/libbitcoin_consensus.a" "${LIBDIR}/libbitcoin_util.a"; do
    [ -f "${f}" ] || { echo "[!] ${f} not found"; exit 1; }
done

# pow.cpp and chain.h reference secp256k1; link whichever form this build produced.
SECP256K1_LIB=""
for cand in "${LIBDIR}/libsecp256k1.a" \
            "${SRC}/build/src/secp256k1/lib/libsecp256k1.a"; do
    [ -f "${cand}" ] && { SECP256K1_LIB="${cand}"; break; }
done

# The first powLimit / nPowTargetSpacing in chainparams.cpp belong to mainnet (CMainParams).
POW_LIMIT="$(grep -m1 'consensus.powLimit' "${PARAMS}" | grep -o '[0-9a-f]\{64\}')"
SPACING="$(grep -m1 'consensus.nPowTargetSpacing' "${PARAMS}" | sed 's/.*=[[:space:]]*\([0-9]*\).*/\1/')"

OUT="$(mktemp -d)"
trap 'rm -rf "${OUT}"' EXIT

INCLUDES=(
    ${CONFIG_INC}
    "-I${SRC}/src"
    "-I${SRC}/src/config"
    "-I${SRC}/src/univalue/include"
    "-I${SRC}/src/secp256k1/include"
    "-I${SRC}/src/leveldb/include"
    "-I${SRC}/src/crc32c/include"
    "-I${SRC}/src/minisketch/include"
)
EXPAND=()
for i in "${INCLUDES[@]}"; do
    case "$i" in
        -I*) d="${i#-I}"; [ -d "$d" ] && EXPAND+=("$i") ;;
        *)   EXPAND+=("$i") ;;
    esac
done

g++ "${STD}" -O1 "${EXPAND[@]}" \
    "${HERE}/lwma_check.cpp" "${SRC}/src/pow.cpp" \
    "${LIBDIR}/libbitcoin_consensus.a" \
    "${LIBDIR}/libbitcoin_common.a" \
    "${LIBDIR}/libbitcoin_crypto.a" \
    "${LIBDIR}/libbitcoin_util.a" \
    "${SECP256K1_LIB}" -lpthread -o "${OUT}/lwma_check"
"${OUT}/lwma_check" "${POW_LIMIT}" "${SPACING}"
