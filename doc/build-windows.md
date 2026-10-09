# Building CacheCoin on native Windows

Most people on Windows should use the native package from Releases
([`README-Windows.txt`](../windows/README-Windows.txt)) instead of this page. To build the
binaries yourself, [WSL2 Ubuntu](https://learn.microsoft.com/windows/wsl/install) runs
`scripts/build_linux.sh` unchanged. Read `START_HERE.md` first.

This page exists because `.github/workflows/build.yml` builds the Windows binaries in CI and
someone has to be able to repeat it by hand. It reproduces that job. Validate it end to end on
your machine; the resulting `.exe` stays outside the Linux regression suites (CI smoke-tests it in regtest).

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
# The subshell keeps a failed "exit 1" from closing the whole interactive terminal.
if ! ( for p in "$HOME/Cachecoin/patches/"*.patch; do
         echo "-> $(basename "$p")"
         git apply --index "$p" || { echo "FAILED: $(basename "$p")"; exit 1; }
       done ); then
  echo "The patch series did not apply cleanly. Fix this before building; do not continue."
else
  echo "Patch series applied."
fi
```

The order matters, and so does the filename glob. `patches/0001-...` has to land before
`patches/0020-...`, and the series has to be applied as a whole: later patches edit code
that earlier ones add, and `patches/0012` removes development comments the earlier patches
carried. Apply them in filename order, 0001 through 0020; never apply them individually
with a GUI patch tool. The loop above stops on the first failure: a half-applied series
still compiles, and its `--version` output looks identical to an unpatched build.
(On Windows, make sure Git checked the sources out with LF; see the `core.autocrlf` line in
`.github/workflows/build.yml`, or `git apply --index` can fail with "does not match index".)

## 4. Build RandomX, then the node

RandomX is consumed as a prebuilt `librandomx.a` so that its own CMakeLists does not
install a library or build extra executables into the CacheCoin output.

```bash
mkdir -p /c/b/src/crypto/randomx/build
cd /c/b/src/crypto/randomx/build
cmake -DARCH=default -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 ..
cmake --build . -j4
if ./randomx-tests > randomx-tests.log; then
  tail -1 randomx-tests.log
else
  tail -20 randomx-tests.log
  echo "RandomX self-test FAILED. Do not build the node from this tree; fix RandomX first."
fi
cd /c/b
# Link SQLite statically: hide the import library so CMake resolves
# /mingw64/lib/libsqlite3.a instead of libsqlite3.dll.a. Without this the
# package would have to carry libsqlite3-0.dll.
if [ -f /mingw64/lib/libsqlite3.dll.a ]; then
  mv /mingw64/lib/libsqlite3.dll.a /mingw64/lib/libsqlite3.dll.a.hidden
fi
# Sanitize the build: no absolute build paths in strings, no DWARF, no PE
# timestamp. Replace <you> with your Windows user name (the flags for the
# other paths are harmless when they do not match).
MAPS="-ffile-prefix-map=C:/Users/<you>/msys64/mingw64/include= -ffile-prefix-map=/c/Users/<you>/msys64/mingw64/include= -ffile-prefix-map=C:/Users/<you>/msys64= -ffile-prefix-map=/c/Users/<you>/msys64= -ffile-prefix-map=C:/b=/b -ffile-prefix-map=/c/b=/b -fmacro-prefix-map=C:/Users/<you>/msys64/mingw64/include= -fmacro-prefix-map=/c/Users/<you>/msys64/mingw64/include= -fmacro-prefix-map=C:/Users/<you>/msys64= -fmacro-prefix-map=/c/Users/<you>/msys64= -fmacro-prefix-map=C:/b=/b -fmacro-prefix-map=/c/b=/b"
cmake -B build -DCACHECOIN_RANDOMX_ROOT=/c/b/src/crypto/randomx \
    -DBUILD_TESTS=OFF -DBUILD_BENCH=OFF -DBUILD_FUZZ_BINARY=OFF -DBUILD_GUI=OFF \
    -DBUILD_KERNEL_LIB=OFF -DENABLE_WALLET=ON -DENABLE_IPC=OFF \
    -DWITH_ZMQ=OFF -DWITH_USDT=OFF -DBUILD_BITCOIN_BIN=OFF \
    -DCMAKE_CXX_FLAGS="$MAPS" -DCMAKE_C_FLAGS="$MAPS" \
    -DCMAKE_EXE_LINKER_FLAGS="-Wl,-s -Wl,--no-insert-timestamp"
cmake --build build -j4 --target bitcoind bitcoin-cli
```

The `randomx-tests` block above reports the failure and leaves the session open (an
`exit 1` would close the whole MSYS2 terminal). If it printed FAILED, do not continue.
The CMake step itself only checks that the RandomX files exist; the node runs
`RandomXSelfTest()` at startup and refuses to run if this machine computes a different
proof-of-work than the network expects. After the build, a quick patch check: `./build/bin/bitcoind.exe --help`
should mention `cachecoin.conf` (an unpatched build says `bitcoin.conf`).

## 5. Collect the binaries

```bash
mkdir -p /c/CacheCoin-bin
cp /c/b/build/bin/bitcoind.exe   /c/CacheCoin-bin/cachecoind.exe
cp /c/b/build/bin/bitcoin-cli.exe /c/CacheCoin-bin/cachecoin-cli.exe
cd /c/CacheCoin-bin
./cachecoind.exe --version
./cachecoin-cli.exe --version
sha256sum -- *.exe > SHA256SUMS.txt
```

The linker flags above already strip the executables (`-Wl,-s`) and omit the PE
timestamp (`-Wl,--no-insert-timestamp`), so there is no separate `strip` step:
the PE header time is 1970-01-01 and no build path appears in the strings.

The build links SQLite, Boost, libevent and the MinGW runtime statically, so the
folder must contain the two executables and nothing else. Prove it: no imported
DLL may exist in `/mingw64/bin`.

```bash
for exe in /c/CacheCoin-bin/cachecoind.exe /c/CacheCoin-bin/cachecoin-cli.exe; do
  imports="$(objdump -p "$exe" | awk '/DLL Name:/ {print $3}' | sort -u)" || { echo "objdump failed on $exe"; exit 1; }
  for dll in $imports; do
    if [ -f "/mingw64/bin/$dll" ]; then echo "non-system import: $dll"; exit 1; fi
  done
done
echo "no non-system imports"
```

Then run the folder the way a user will: with the MSYS2 path removed.

```bash
cd /c/CacheCoin-bin
D="$(mktemp -d)"; DW="$(cygpath -w "$D")"; CP="/c/Windows/System32:/c/Windows"
PATH="$CP" ./cachecoind.exe -regtest -datadir="$DW" -rpcuser=u -rpcpassword=p \
    -rpcport=39932 -port=39933 -listen=0 -printtoconsole=0 &
BPID=$!
cli() { PATH="$CP" ./cachecoin-cli.exe -regtest -datadir="$DW" -rpcuser=u -rpcpassword=p -rpcport=39932 "$@"; }
for i in $(seq 1 60); do cli getblockchaininfo >/dev/null 2>&1 && break; sleep 2; done
cli createwallet w
ADDR="$(cli -rpcwallet=w getnewaddress "" bech32)"
cli -rpcwallet=w generatetoaddress 1 "$ADDR"
test "$(cli getblockcount)" = "1" && echo "clean-environment wallet test OK"
cli stop; wait $BPID || true; rm -rf "$D"
```

## Branding the executables (optional)

A hand-built artifact still carries the upstream Bitcoin Core VERSIONINFO strings and no icon,
so Task Manager shows "bitcoind (...)". Run the resource-only branding step after the build:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\brand_windows_exe.ps1 `
    -Exe <folder>\cachecoind.exe -Icon assets\logo.ico `
    -FileDescription "CacheCoin node (cachecoind)" -OriginalFilename "cachecoind.exe"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\brand_windows_exe.ps1 `
    -Exe <folder>\cachecoin-cli.exe -Icon assets\logo.ico `
    -FileDescription "CacheCoin RPC client (cachecoin-cli)" -OriginalFilename "cachecoin-cli.exe"
```

It rewrites only resources (no code, no consensus bytes) and must be followed by regenerating the
package checksums and signature. The `--version` console banner still prints the upstream project
strings; that text is compiled in, not a resource. CI applies this step to every Windows build
before generating the package checksums (`.github/workflows/build.yml`).

## Reproducibility status

Bit-for-bit reproducibility is not implemented for `cachecoind` / `cachecoin-cli`: the same
source and toolchain can produce different bytes (timestamps, paths, toolchain versions). The
anchors that do not depend on the build are the patch fingerprint
(`cat patches/*.patch | sha256sum`) and the applied tree id. Compare those when you rebuild;
use the binary hash only to check a download in transit.

The Windows GUI is deterministic: `build_det.ps1` (Windows) and `build.sh` (Linux/macOS) both
compile with Roslyn `-deterministic`; two consecutive runs of `build_det.ps1` produced a
byte-identical `CacheCoin.exe` for the packaged build.

Every file in a released package is identified in `windows/PROVENANCE.txt`, and
`Verify Download.cmd` checks a package in one step. CI builds the official binaries in
`.github/workflows/build.yml`; a manual build should use the same flags as this page.

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
- **The build is fully static.** `objdump -p` on the built executables lists
  only Windows system DLLs; SQLite, Boost, libevent and the MinGW runtime are
  linked in. The folder contains the two executables and nothing else. If a
  rebuild ever imports a DLL that exists in `/mingw64/bin`, stop: the package
  would have to ship and list that file (section 5 shows the assert).
- **The binaries are unsigned.** Windows SmartScreen will show "Windows protected your PC" on
  first launch, and you have to choose More info, then Run anyway. That warning is expected for
  any unsigned build. Verify the SHA-256 against `SHA256SUMS.txt` before you do.
- **These binaries are outside the automated suites.** The Linux and WSL2
  suites are the project's automated coverage; build and verify these locally.
- **Tor must be running**, on port 9050 or 9150. See `START_HERE.md`; the port mismatch is the
  single most common reason a Windows node sits at zero peers.
- **Do not publish binaries you built yourself without checking them.** Build paths such as
  `/home/<user>/...` or `C:\...\msys64\home\<user>\...` get compiled into the executable.
