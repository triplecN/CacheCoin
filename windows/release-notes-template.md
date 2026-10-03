# CacheCoin (CCCN) <version> for Windows

Draft/published: <date>. This package is unsigned at the executable level and
outside the repository's automated test suites. Read the whole note before
running it.

## Files

- `CacheCoin-Windows-<version>.zip`
  sha256: `<zip-sha256>`
- `SHA256SUMS.windows.txt` (sha256 of every file in the package)
- `SHA256SUMS.windows.txt.asc` (detached GPG signature, added offline)

## Provenance

- Base pins: Bitcoin Core `v31.1`, commit
  `9be056a8a72b624dae9623b2f7bded92c2a21c91`; RandomX commit
  `7607fb2faed24d5a679e139a9828d194bbc644a4`.
- Patch fingerprint: `<patch-fingerprint>` (`cat patches/*.patch | sha256sum`).
  Compare it with `doc/verification.md` in the release tag.
- `version.json` inside the package lists the version, the pins, the patch
  fingerprint and the sha256 of every file.
- Tor Expert Bundle: version `<tor-version>`; its files are hashed in
  `version.json` (`tor/tor.exe` and the rest).

## Verify before running

```bash
sha256sum -c SHA256SUMS.windows.txt
gpg --verify SHA256SUMS.windows.txt.asc SHA256SUMS.windows.txt
```

Check the signing key fingerprint against the one published in the release
announcement and in `doc/release.md`. On Windows:

```powershell
Get-FileHash CacheCoin-Windows-<version>.zip -Algorithm SHA256
```

## What this is

A portable Windows package of `cachecoind.exe` and `cachecoin-cli.exe` from the
tagged tree, with the PowerShell launcher, the documentation and the Tor Expert
Bundle. The node is Tor-only; the launcher uses Tor on 9050/9150 and starts the
bundled Tor if none is running. The data directory is `%APPDATA%\CacheCoin`, not
`~/.cachecoin`.

## Honest limits

- **Not reproducible.** The build is not reproducible. The sha256 values prove
  only that the files arrived unchanged in transit; the GPG signature proves the
  checksum file came from the CacheCoin release key
  (`<release-key-fingerprint>`). Neither proves the bytes can be rebuilt from
  source, because nobody can yet.
- **SmartScreen.** The binaries are unsigned. Windows will show "Windows
  protected your PC" on first launch; choose More info, then Run anyway, after
  checking the sha256.
- **Outside the suites.** The Windows `.exe` files are not covered by the
  repository's automated test suites (`doc/build-windows.md`). The CI smoke
  test starts the node in regtest, verifies the genesis and mines one block.
- **No daemon mode.** `cachecoind -daemon` does not exist on Windows (MinGW has
  no `fork()`); run it in a window or under Task Scheduler. `cachecoin-cli
  -rpcwait` still works.
- **Mining is a lottery.** Expect weeks without a block; it may never pay.
  The PER ticket system shares fees only when fees exist. Mining costs
  electricity whether or not it pays.
- **No financial advice.** This is open-source software provided as is under
  the MIT license; nothing here is financial advice, an offer or a promise of
  return.

## Links

- `START_HERE.md` (in `docs\`) for first steps.
- `doc/build-windows.md` and `doc/release.md` in the repository for build and
  release details.
