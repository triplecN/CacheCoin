# CacheCoin for Windows: portable package builder

This directory builds the portable Windows package: the CI-built node binaries
(`cachecoind.exe`, `cachecoin-cli.exe`), the PowerShell launcher, the Tor Expert
Bundle, the documentation and the checksums, zipped as
`CacheCoin-Windows-<version>.zip`.

The repository is treated as read-only. All output goes to the `--out`
directory you choose (use one outside the repository).

## Package layout

```
CacheCoin-Windows-<version>/
  Start Node.cmd                # entry point: run the node only (safe default)
  Start Mining.cmd              # entry point: run the node and mine (asks where the coins go)
  Create New Wallet.cmd         # entry point: make a new wallet offline
  Check Status.cmd              # entry point: block, peers, balance
  Verify Download.cmd           # entry point: check the package (hashes, list, signature)
  PROVENANCE.txt                # where every packaged file came from and how to check it
  TOR-PIN.txt                   # the pinned Tor Expert Bundle (version, sha256, signing key)
  launcher\CacheCoin.ps1        # the launcher behind the entry points
  LICENSE                       # MIT, copied from the repository root
  README-Windows.txt            # plain-language guide for the people running the package
  bin\
    cachecoind.exe              # from the windows-build CI job (statically linked)
    cachecoin-cli.exe           # from the windows-build CI job (statically linked)
  launcher\
    CacheCoin.ps1               # launcher written for this package
  tools\
    CacheCoin-NewWallet.ps1     # script behind Create New Wallet.cmd
    CacheCoin-Package.ps1       # version.json integrity check shared by the tools
    CacheCoin-Status.ps1        # script behind Check Status.cmd
    CacheCoin-Verify.ps1        # script behind Verify Download.cmd
  docs\
    README.md                   # repository README
    SECURITY.md                 # repository security policy
    ...                         # every file from windows\docs\ (START_HERE.txt, ...)
  tor\
    tor.exe                     # Tor Expert Bundle
    data\geoip, geoip6          # bundle data files
    docs\tor.txt                # Tor license and component licenses
    pluggable_transports\       # as shipped in the bundle
    ...
  CacheCoin App.cmd             # only with --gui-dir: opens the window
  CacheCoin.exe                 # only with --gui-dir: the window binary
  version.json                  # pins, patch fingerprint, per-file sha256
  SHA256SUMS.windows.txt        # sha256 of every file above
```

The detached signature `SHA256SUMS.windows.txt.asc` is created offline and published next to the
zip; it is not part of the package.

The structure mirrors `windows\` in the repository: the entry-point `.cmd`
files sit at the package root and `CacheCoin.ps1` stays in `launcher\`, so
their relative paths are the same in both places.

## Prerequisites

- Linux, WSL2 or MSYS2 (MINGW64) with bash and coreutils (`sha256sum`, `find`,
  `date`).
- One zip backend: `zip`, `python3`/`python`, or `powershell.exe` (MSYS2
  fallback). The script picks one automatically.
- A repository checkout: `patches/`, `LICENSE`, `README.md` and `SECURITY.md`
  are read from it.
- `windows\launcher\CacheCoin.ps1` and the entry-point
  `.cmd` files (`Start Node.cmd`, `Start Mining.cmd`, `Create New Wallet.cmd`,
  `Check Status.cmd`, `Verify Download.cmd`), `windows\tools\`, `windows\docs\` and
  `windows\README-Windows.txt`
  (default `--launcher-dir` / `--docs-dir`).

## Step 1: get the node binaries from CI

1. Open the GitHub Actions run for the commit or signed tag you trust and select
   the `windows-build` job of `.github/workflows/build.yml`.
2. Confirm the job succeeded. The artifact is only uploaded after the build,
   the static-runtime assertion and the clean-environment wallet test all
   pass; a failed Windows job fails the whole run.
3. Download the artifact `cachecoin-windows` (requires a GitHub login; artifacts
   expire after 90 days). It contains a `bin\` directory with `cachecoind.exe`,
   `cachecoin-cli.exe` and `SHA256SUMS.txt`. The executables are statically
   linked: the folder holds no DLLs.
4. Unpack it. The `bin` directory is `--bin-dir`; the packaging script copies
   the executables. The artifact checksums protect the download in transit
   only; compare `SHA256SUMS.txt` if you want, but the package's own checksums
   are what you publish.

Building the `.exe` files yourself is possible, but outside the automated
suites; see `doc/build-windows.md`.

## Step 2: get the Tor Expert Bundle

1. Download the pinned Windows x86_64 Tor Expert Bundle. The exact archive,
   sha256 and signing key are in `windows\TOR-PIN.txt` (Expert Bundle 15.0.24,
   tor 0.4.9.13).
2. Verify the archive's sha256 and its GPG signature with the key in
   `TOR-PIN.txt`, then unpack it.
3. Unpack it. Pass the extracted bundle root as `--tor-dir`; the script also
   accepts a directory that contains `tor.exe` directly. In the bundle layout
   it copies `tor/` to the package's `tor/`, and `data/` and `docs/` (including
   the Tor license, `docs/tor.txt`) into `tor/data` and `tor/docs`.

After unpacking, check the bundle against the pin:

```bash
bash windows/verify_tor_bundle.sh --tor-dir /path/to/tor-expert-bundle
```

`version.json` identifies the bundle by the sha256 of every Tor file; there is
no separate version string in the schema.

## Step 3: prepare launcher and docs

Make sure the launcher (`windows\launcher\CacheCoin.ps1` plus the
`windows\Start Node.cmd` / `windows\Start Mining.cmd` / `windows\Check Status.cmd` / `windows\Create New Wallet.cmd` / `windows\Verify Download.cmd` entry points) and `windows\docs\` exist in the checkout. Both
directories can be overridden:

```bash
--launcher-dir /path/to/windows --docs-dir /path/to/windows/docs
```

Relative paths are resolved from the current directory; the defaults are the
directory containing `build_package.sh` (the launcher) and its `docs`
subdirectory.

## Step 4: build the package

From the repository root:

```bash
bash windows/build_package.sh \
    --bin-dir /path/to/cachecoin-windows \
    --tor-dir /path/to/tor-expert-bundle \
    --gui-dir /path/to/gui-build \
    --version 0.1.0 \
    --out /path/to/output
```

A leading `v` is accepted (`--version v0.1.0` becomes `0.1.0`). The script:

- fails if `cachecoind.exe`, `cachecoin-cli.exe`, `tor.exe`, the Tor license,
  the launcher files or the docs directory are missing; with `--gui-dir` it also
  requires `CacheCoin.exe` there;
- with `--gui-dir`, copies `CacheCoin.exe` and generates `CacheCoin App.cmd`;
  without it the package has no window;
- copies the launcher, docs, `LICENSE`, `README.md` and `SECURITY.md` (the last
  two into `docs\`, overwriting same-named files already in `--docs-dir`);
- computes the patch fingerprint as `cat patches/*.patch | sha256sum`;
- hashes every file into `version.json` and `SHA256SUMS.windows.txt`;
- verifies `SHA256SUMS.windows.txt` against the package before zipping;
- creates `CacheCoin-Windows-<version>.zip` and prints its sha256.

## Step 5: verify the result

```bash
cd /path/to/output
unzip CacheCoin-Windows-0.1.0.zip
cd CacheCoin-Windows-0.1.0
sha256sum -c SHA256SUMS.windows.txt
```

Check that `version.json` reports the expected `patch_fingerprint` (compare
with `doc/verification.md`), the two base pins, and that `files` lists every
file in the package (`sha256sum -c` already covers the same list; this only
cross-checks the count). The package also carries `Verify Download.cmd`
(tools\CacheCoin-Verify.ps1) for end users; `PROVENANCE.txt` and `TOR-PIN.txt`
record where every file came from, and

```bash
bash windows/verify_tor_bundle.sh --tor-dir <package>\tor
```

re-checks the Tor pin (downloading the pinned archive when no `--tarball` is
given). On Windows, hash the zip with:

```powershell
Get-FileHash CacheCoin-Windows-0.1.0.zip -Algorithm SHA256
```

## Step 6: sign offline and attach to the release

Signing never happens in CI and never on the build machine if it has network
access. Move the checksum file to the offline machine that holds the release
GPG key, sign it there, and keep only the `.asc` on the build machine.

The package checksum file is `SHA256SUMS.windows.txt`.
`scripts/release_sign.sh` writes `SHA256SUMS.txt` for the flat Linux binaries
and is not a general-purpose signer; for the Windows package run the same gpg
step it wraps:

```bash
gpg --armor --detach-sign --local-user <release-key-id> SHA256SUMS.windows.txt
```

That produces `SHA256SUMS.windows.txt.asc`. Key hygiene (offline key, backup
revocation certificate, passphrase) is described in `doc/release.md`.

Attach the unsigned zip and the checksum files to the draft release:

```bash
gh release upload <tag> \
    CacheCoin-Windows-<version>.zip \
    CacheCoin-Windows-<version>/SHA256SUMS.windows.txt \
    SHA256SUMS.windows.txt.asc \
    --clobber
```

Publish using `windows/release-notes-template.md`. `.github/workflows/release.yml`
does not attach Windows files by default; `windows/release_workflow_changes.md`
describes the proposed change and how to keep that default honest.

## What is deliberately not bundled

- **Wallet and keys.** There is no `wallet.dat`, no seed, no key material. A
  wallet is created on first use under `%APPDATA%\CacheCoin`, and losing it is
  losing the coins.
- **Chain data.** No `blocks\` and no `chainstate\`; the node syncs from the
  network and validates everything itself. The package stays small.
- **Clearnet configuration.** The node is Tor-only by default. The repository's
  `config/cachecoin-clearnet.conf` is intentionally not shipped; running over
  clearnet is a deliberate manual choice (`START_HERE.md`).
- **GUI.** The node build is `-DBUILD_GUI=OFF`: `cachecoind` plus
  `cachecoin-cli` only. The separate Windows window (`CacheCoin.exe`) is built
  from the GUI sources and, when `build_package.sh` is given `--gui-dir`, is
  copied into the package and covered by `version.json` and the checksums.
- **Miners.** No XMRig or any other external miner. The node's built-in
  `generatetoaddress` is light mode only; faster miners have their own licenses
  and are not distributed here.
- **Tor Browser.** Only the Expert Bundle daemon is included. The launcher
  probes 9050 first and 9150 second, so either a system Tor or a Tor Browser
  session can be used; when it starts the bundled Tor it uses 9050.
- **Linux binaries and the GPG key.** The `.exe` files are unsigned; expect the
  SmartScreen "Windows protected your PC" prompt and verify the sha256 before
  choosing More info, then Run anyway.

## Honesty notes

The build is not reproducible: the sha256 values prove that a download arrived
unchanged, and the GPG signature proves who signed the checksum file, but no
one can yet rebuild the exact bytes. Do not claim otherwise. The Windows
binaries are outside this repository's automated test suites
(`doc/build-windows.md`); the CI smoke test starts the node in regtest, mines
one block and checks the genesis, nothing more.

The two node executables carry CacheCoin resource branding (VERSIONINFO strings
and icon) applied after the build by `scripts/brand_windows_exe.ps1`, so Task
Manager and Explorer show CacheCoin instead of the upstream Bitcoin Core names.
That is resource-only — no code and no consensus bytes are touched — and the CI
smoke test runs the branded binaries. `cachecoind --version` still prints the
upstream banner text because that is compiled in, not a resource.
