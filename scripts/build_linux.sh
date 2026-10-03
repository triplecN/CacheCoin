#!/usr/bin/env bash
# ==============================================================================
# CacheCoin (CCCN) - Linux build script
# Target: Ubuntu 22.04 / 24.04 LTS, Debian 12
#
# Builds cachecoind + cachecoin-cli from Bitcoin Core v31.1 + patches/*.patch +
# RandomX, and installs them to /usr/local/bin.
#
# Portable build: no -march=native, so the binaries also run on CPUs other than
# the build machine's (e.g. copied to a VPS). RandomX still selects JIT/AES/AVX2
# code paths at runtime.
#
# Re-running is safe: the Bitcoin Core tree is reset to the pinned commit and the
# patches are applied again whenever patches/ changed; otherwise the previous
# build is reused and only recompiled.
# ==============================================================================
set -euo pipefail

BITCOIN_TAG="v31.1"
BITCOIN_COMMIT="9be056a8a72b624dae9623b2f7bded92c2a21c91"
# RandomX is consensus-critical: every node must run the same algorithm (RandomX v1).
# Pinned to the exact commit the genesis block was mined and verified with.
RANDOMX_REPO="https://github.com/tevador/RandomX.git"
RANDOMX_COMMIT="7607fb2faed24d5a679e139a9828d194bbc644a4"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="${SCRIPT_DIR}/../patches"
BUILD_DIR="${HOME}/cachecoin-build"
SRC_DIR="${BUILD_DIR}/cachecoin-${BITCOIN_TAG}"   # managed by this script (reset on patch changes)
JOBS="$(nproc)"

echo "================================================================================"
echo " CacheCoin (CCCN) build: Bitcoin Core ${BITCOIN_TAG} + CacheCoin patches + RandomX"
echo "================================================================================"

echo "[1/6] Installing build dependencies"
sudo apt-get update
sudo apt-get install -y \
    build-essential pkg-config bsdmainutils python3 \
    libevent-dev libboost-dev libsqlite3-dev libnatpmp-dev libzmq3-dev \
    cmake git curl

mkdir -p "${BUILD_DIR}"

echo "[2/6] Fetching Bitcoin Core ${BITCOIN_TAG}"
if ! git -C "${SRC_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
    # A partial or failed clone leaves a directory that would fail later with a
    # misleading error; start over instead.
    echo "  -> no valid clone at ${SRC_DIR}; cloning fresh"
    rm -rf "${SRC_DIR}"
    git clone --branch "${BITCOIN_TAG}" --depth 1 https://github.com/bitcoin/bitcoin.git "${SRC_DIR}"
fi
cd "${SRC_DIR}"
if [ "$(git rev-parse "${BITCOIN_TAG}^{commit}")" != "${BITCOIN_COMMIT}" ]; then
    echo "[!] ${BITCOIN_TAG} is not commit ${BITCOIN_COMMIT}; refusing to build on an unexpected base."
    exit 1
fi

echo "[3/6] Applying CacheCoin patches"
PATCHES_ID="$(cat "${PATCH_DIR}"/*.patch | sha256sum | cut -d' ' -f1)"
RECORDED="$(cat .cachecoin-patches 2>/dev/null || true)"
RECORDED_ID="$(printf '%s\n' "${RECORDED}" | awk '{print $1}')"
RECORDED_TREE="$(printf '%s\n' "${RECORDED}" | awk '{print $2}')"
# Attest the already-applied path: the patch fingerprint alone does not prove the
# tree was not modified (staged or in the working copy). write-tree covers the
# index, git diff --quiet covers the working copy.
if [ "${RECORDED_ID}" = "${PATCHES_ID}" ] && [ -n "${RECORDED_TREE}" ] && \
   [ "$(git write-tree)" = "${RECORDED_TREE}" ] && git diff --quiet; then
    echo "  -> already applied (patches and tree unchanged)"
else
    # Back to pristine Bitcoin Core (keeps the RandomX checkout), then apply the series in order.
    rm -f .cachecoin-patches
    git reset --quiet --hard "${BITCOIN_COMMIT}"
    git clean --quiet -fdx -e src/crypto/randomx
    for patch in "${PATCH_DIR}"/*.patch; do
        echo "  -> $(basename "${patch}")"
        git apply --index "${patch}"
    done
    # A patch that leaves a conflict marker in the tree compiles into nonsense (or
    # worse, silently keeps the "ours" side of a merge). The series is not hash-pinned,
    # so gate the result, not the intent.
    if grep -rIn --exclude-dir=.git --exclude-dir=build --exclude-dir=randomx -e '^<<<<<<< ' -e '^>>>>>>> ' .; then
        echo "[!] conflict markers found in the patched tree; refusing to build."
        exit 1
    fi
    echo "${PATCHES_ID} $(git write-tree)" > .cachecoin-patches
fi

echo "[4/6] Building RandomX ${RANDOMX_COMMIT:0:7}"
if [ ! -d src/crypto/randomx/.git ]; then
    git clone "${RANDOMX_REPO}" src/crypto/randomx
fi
git -C src/crypto/randomx checkout --quiet "${RANDOMX_COMMIT}"
if [ "$(git -C src/crypto/randomx rev-parse HEAD)" != "${RANDOMX_COMMIT}" ]; then
    echo "[!] RandomX is not at the pinned commit; refusing to build a different PoW."
    exit 1
fi
# checkout preserves a dirty worktree: a local edit to RandomX would be compiled
# into the consensus PoW while the commit check above still passes.
if ! git -C src/crypto/randomx diff --quiet; then
    echo "[!] RandomX worktree has local modifications; refusing to build a modified proof of work."
    git -C src/crypto/randomx status --short
    exit 1
fi
mkdir -p src/crypto/randomx/build
( cd src/crypto/randomx/build && cmake -DARCH=default -DCMAKE_BUILD_TYPE=Release .. && make -j"${JOBS}" )
( cd src/crypto/randomx/build && ./randomx-tests ) | tail -1

echo "[5/6] Configuring and compiling (${JOBS} jobs)"
CMAKE_ARGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DCACHECOIN_RANDOMX_ROOT="${SRC_DIR}/src/crypto/randomx"
    -DBUILD_TESTS=OFF
    -DBUILD_BENCH=OFF
    -DBUILD_FUZZ_BINARY=OFF
    -DBUILD_GUI=OFF
    -DBUILD_KERNEL_LIB=OFF
    -DBUILD_BITCOIN_BIN=OFF
    -DENABLE_WALLET=ON
    -DENABLE_IPC=OFF
    -DWITH_ZMQ=OFF
    -DWITH_USDT=OFF
)
# Reconfigure when the flags change, not only when the cache is missing: an old
# cache with different options would silently build the wrong configuration.
CONFIGURE_ID="$(printf '%s\n' "${CMAKE_ARGS[@]}" | sha256sum | cut -d' ' -f1)"
if [ ! -f build/CMakeCache.txt ] || [ "$(cat build/.cachecoin-configure 2>/dev/null || true)" != "${CONFIGURE_ID}" ]; then
    cmake -B build -S . "${CMAKE_ARGS[@]}"
    echo "${CONFIGURE_ID}" > build/.cachecoin-configure
fi
cmake --build build -j"${JOBS}" --target bitcoind bitcoin-cli

echo "[6/6] Installing to /usr/local/bin"
sudo install -m 0755 build/bin/bitcoind /usr/local/bin/cachecoind
sudo install -m 0755 build/bin/bitcoin-cli /usr/local/bin/cachecoin-cli

echo "================================================================================"
echo "[+] Build finished:"
echo "      /usr/local/bin/cachecoind     (daemon)"
echo "      /usr/local/bin/cachecoin-cli  (RPC client)"
echo "    Data directory: ~/.cachecoin   Config file: ~/.cachecoin/cachecoin.conf"
echo "    Every start runs a RandomX self-test on the genesis block (see debug.log)."
echo "================================================================================"
