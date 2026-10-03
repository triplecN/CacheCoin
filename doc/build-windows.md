# Building CacheCoin on native Windows

Most people should not use this page. If you are on Windows, the supported path is
[WSL2 Ubuntu](https://learn.microsoft.com/windows/wsl/install), and `scripts/build_linux.sh`
works there unchanged. Read `START_HERE.md` first.

This page exists because `.github/workflows/build.yml` builds the Windows binaries in CI and
someone has to be able to repeat it by hand. It reproduces that job. Validate it end to end on
your machine; the resulting `.exe` is outside this repository's test suites.

## What you need

- Windows 10 or 11, 64-bit
- Git for Windows
- [MSYS2](https://www.msys2.org/) with the MINGW64 toolchain
- About 20 GB of free disk and 30-60 minutes

## 1. Install MSYS2 and the toolchain

Install MSYS2, open **MSYS2 MINGW64** from the Start menu, then:

```bash
  pacman -S --needed git make mingw-w64-x86_64-toolchain \
  mingw-w64-x86_64-cmake mingw-w64-x86_64-boost mingw-w64-x86_64-libevent \
  mingw-w64-x86_64-sqlite3 mingw-w64-x86_64-zeromq python
```

## 2. Clone the pinned sources

```bash
mkdir -p /c && cd /c
git clone --branch v31.1 --depth 1 https://github.com/bitcoin/bitcoin.git /c/b
cd /c/b
test "$(git rev-parse 'v31.1^{commit}')" = "9be056a8a72b624dae9623b2f7bded92c2a21c91"
git clone https://github.com/tevador/RandomX.git src/crypto/randomx
git -C src/crypto/randomx checkout --quiet 7607fb2faed24d5a679e139a9828d194bbc644a4
test "$(git -C src/crypto/randomx rev-parse HEAD)" = "7607fb2faed24d5a679e139a9828d194bbc644a4"
```

The two `test`/`checkout` lines are not optional. They pin Bitcoin Core and RandomX to the exact
commits this project is pinned to. If either has moved, stop: you are no longer building
the same software, and the patches will not apply.

## 3. Apply the patches in order

```bash
cd /c/b
# This assumes the repository is checked out at ~/Cachecoin; adjust the path otherwise.
for p in "$HOME/Cachecoin/patches/"*.patch; do
  echo "-> $(basename "$p")"
  git apply --index "$p"
done
```

The order matters, and so does the filename glob. `patches/0001-...` has to land before
`patches/0020-...`, and the series has to be applied as a whole: later patches edit code
that earlier ones add, and `patches/0012` removes development comments the earlier patches
carried. Apply them in filename order, 0001 through 0020; never apply them individually
with a GUI patch tool.
(On Windows, make sure Git checked the sources out with LF; see the `core.autocrlf` line in
`.github/workflows/build.yml`, or `git apply --index` can fail with "does not match index".)

## 4. Build RandomX, then the node

RandomX is consumed as a prebuilt `librandomx.a` so that its own CMakeLists does not
install a library or build extra executables into the CacheCoin output.

```bash
mkdir -p /c/b/src/crypto/randomx/build
cd /c/b/src/crypto/randomx/build
cmake -DARCH=default -DCMAKE_BUILD_TYPE=Release ..
cmake --build . -j4
./randomx-tests > randomx-tests.log && tail -1 randomx-tests.log
cd /c/b
cmake -B build -DCACHECOIN_RANDOMX_ROOT=/c/b/src/crypto/randomx \
    -DBUILD_TESTS=OFF -DBUILD_BENCH=OFF -DBUILD_FUZZ_BINARY=OFF -DBUILD_GUI=OFF \
    -DBUILD_KERNEL_LIB=OFF -DENABLE_WALLET=ON -DENABLE_IPC=OFF \
    -DWITH_ZMQ=OFF -DWITH_USDT=OFF -DBUILD_BITCOIN_BIN=OFF
cmake --build build -j4 --target bitcoind bitcoin-cli
```

The build will fail if the RandomX self-test fails. That is intentional: it means this machine
computes a different proof-of-work than the network expects, and the node must not start.

## 5. Collect the binaries

```bash
mkdir -p /c/CacheCoin-bin
cp /c/b/build/bin/bitcoind.exe   /c/CacheCoin-bin/cachecoind.exe
cp /c/b/build/bin/bitcoin-cli.exe /c/CacheCoin-bin/cachecoin-cli.exe
# Drop debug information: the MSYS2 Release build keeps DWARF by default and
# the executables are otherwise hundreds of megabytes.
strip --strip-all /c/CacheCoin-bin/cachecoind.exe /c/CacheCoin-bin/cachecoin-cli.exe
# The MSYS2 build is dynamically linked. Copy the MinGW runtime and library
# DLLs next to the executables so the folder runs on a machine without MSYS2;
# Windows searches the application directory first. Only names that exist in
# /mingw64/bin are copied, so system DLLs are never shipped.
for exe in /c/CacheCoin-bin/cachecoind.exe /c/CacheCoin-bin/cachecoin-cli.exe; do
  objdump -p "$exe" | awk '/DLL Name:/ {print $3}' | sort -u | while read -r dll; do
    if [ -f "/mingw64/bin/$dll" ]; then cp "/mingw64/bin/$dll" /c/CacheCoin-bin/; fi
  done
done
cd /c/CacheCoin-bin
./cachecoind.exe --version
sha256sum -- *.exe *.dll > SHA256SUMS.txt
```

## Known limitations

- **There is no daemon mode.** `cachecoind -daemon` and `-daemonwait` do not exist on this
  platform; MinGW has no `fork()`. The node runs in the foreground. To leave it running you need
  a separate window, or Task Scheduler. The `-rpcwait` flag on `cachecoin-cli` still works.
- **The data directory is not `~/.cachecoin`.** The node uses
  `%APPDATA%\CacheCoin` (that is `C:\Users\<you>\AppData\Roaming\CacheCoin`). This is set by
  `patches/0001` (`GetDefaultDataDir`) so CacheCoin never shares state with a Bitcoin Core
  installation on the same machine. Put `cachecoin.conf` there, not in your home directory.
- **The explorer and `check_supply.py` find the RPC cookie automatically on Windows.**
  Both use `%APPDATA%\CacheCoin\.cookie` when `sys.platform == "win32"` (the Linux path
  is `~/.cachecoin/.cookie`). `CACHECOIN_RPC_COOKIE` still overrides it if the data
  directory is somewhere else.
- **The binaries are dynamically linked.** They load the MinGW runtime and
  library DLLs (`libgcc_s_seh-1.dll`, `libstdc++-6.dll`, `libwinpthread-1.dll`,
  `libevent-*.dll`, `libsqlite3-0.dll`, ...). Keep those DLLs next to the
  executables; Windows searches the application directory first. The CI job
  collects them with `objdump`; a hand-built folder needs the same step (section 5).
- **The binaries are unsigned.** Windows SmartScreen will show "Windows protected your PC" on
  first launch, and you have to choose More info, then Run anyway. That warning is expected for
  any unsigned build. Verify the SHA-256 against `SHA256SUMS.txt` before you do.
- **These binaries are outside the automated suites.** The Linux and WSL2
  suites are the project's automated coverage; build and verify these locally.
- **Tor must be running**, on port 9050 or 9150. See `START_HERE.md`; the port mismatch is the
  single most common reason a Windows node sits at zero peers.
- **Do not publish binaries you built yourself without checking them.** Build paths such as
  `/home/<user>/...` or `C:\...\msys64\home\<user>\...` get compiled into the executable.
