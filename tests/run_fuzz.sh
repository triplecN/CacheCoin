#!/usr/bin/env bash
# Build and run the CacheCoin PER fuzz targets for a bounded time.
#
# Requires clang with libFuzzer (Ubuntu: sudo apt-get install -y clang).
# The fuzz binary is separate from the shipped build: it links bitcoin_node so
# per.cpp is available and is not part of scripts/build_linux.sh.
#
# Usage: bash tests/run_fuzz.sh [source-dir] [runs-per-target]
#   source-dir  defaults to ~/cachecoin-build/cachecoin-v31.1
#   runs        defaults to 200000 per target
set -euo pipefail

SRC="${1:-${HOME}/cachecoin-build/cachecoin-v31.1}"
RUNS="${2:-200000}"
# The fuzz binary compiles every upstream target with sanitizers, which is heavy:
# a low default job count keeps a small WSL from running out of memory. Override
# with JOBS=<n>, and drop sanitizers with SANITIZERS=fuzzer if linking still OOMs.
JOBS="${JOBS:-2}"
SANITIZERS="${SANITIZERS:-fuzzer,address,undefined}"
BUILD="${SRC}/build-fuzz"

[ -f "${SRC}/src/test/fuzz/per.cpp" ] || {
    echo "[!] ${SRC} has no PER fuzz targets (apply patches/0014 first)"
    exit 1
}
[ -d "${SRC}/src/crypto/randomx" ] || { echo "[!] RandomX checkout not found under ${SRC}"; exit 1; }
command -v clang >/dev/null 2>&1 || { echo "[!] clang is required: sudo apt-get install -y clang"; exit 1; }
command -v clang++ >/dev/null 2>&1 || { echo "[!] clang++ is required: sudo apt-get install -y clang"; exit 1; }

# BUILD_FOR_FUZZING also defines FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION, which
# the harness requires to run a target at all; it disables the other binaries and
# forces BUILD_FUZZ_BINARY=ON. bitcoin_node reaches the link line through
# test_fuzz, so it is not named here.
cmake -B "${BUILD}" -S "${SRC}" \
    -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
    -DBUILD_FOR_FUZZING=ON -DSANITIZERS="${SANITIZERS}" \
    -DCACHECOIN_RANDOMX_ROOT="${SRC}/src/crypto/randomx"
echo "[i] building with -j${JOBS} and SANITIZERS=${SANITIZERS}"
cmake --build "${BUILD}" -j"${JOBS}" --target fuzz

status=0
for target in per_ticket_roundtrip per_ticket_deserialize per_commitment_roundtrip per_parse_commitment per_next_state per_ticket_script; do
    echo "=== fuzzing ${target} (${RUNS} runs) ==="
    # The harness selects the target with the FUZZ environment variable; a
    # positional argument is a corpus path.
    if ! FUZZ="${target}" "${BUILD}/bin/fuzz" -runs="${RUNS}" -max_len=1024; then
        echo "[!] ${target} FAILED"
        status=1
    fi
done
exit "${status}"
