# Release process

How a CacheCoin release is built, signed and verified. The goal is that anyone
can check that a binary matches the source and came from the maintainer's key,
without trusting a website or a chat message. There are no admin keys in the
protocol; a release is software only and never changes consensus.

## Versioning

- Tags look like `v0.1.0`. A tag is a statement about the software, not about
  the chain: the consensus rules are frozen, and changing `patches/` is a hard
  fork (`doc/incident_runbook.md` §8).
- A release is cut from a commit that passes the fifteen suites locally and
  builds in CI (Linux, plus ARM64 where the runner is available).

## What the maintainer does

1. Make sure CI is green on `master`.
2. Tag the commit with a **signed** tag:
   ```bash
   git tag -s v0.1.0 -m "CacheCoin v0.1.0"
   git push origin v0.1.0
   ```
3. The `release` workflow (`.github/workflows/release.yml`) triggers on the tag:
   it builds with `scripts/build_linux.sh`, runs the 15 suites, produces
   `cachecoind`, `cachecoin-cli` and `SHA256SUMS.txt`, and creates a **draft**
   GitHub release with those files.
4. Download the draft assets and verify them independently:
   - compare the patch fingerprint with `doc/verification.md`
     (`.cachecoin-patches` in the build tree),
   - run `sha256sum -c SHA256SUMS.txt`,
   - if possible, rebuild from source and compare behavior (a bit-for-bit
     reproducible build is not implemented).
5. Sign the checksum file **offline** with the release GPG key and attach the
   signature to the draft:
   ```bash
   gpg --armor --detach-sign --local-user <release-key-id> SHA256SUMS.txt
   # upload SHA256SUMS.txt.asc next to the binaries
   ```
6. Publish the release. Announce the tag, the key fingerprint, the patch
   fingerprint and the SHA-256 values.

Windows `.exe` files are **not** attached by default: CI builds them, but the
suites do not test them (`doc/build-windows.md`). If they are attached, say so
plainly in the release notes.

## What a user does

```bash
# 1. download cachecoind, cachecoin-cli, SHA256SUMS.txt and SHA256SUMS.txt.asc
sha256sum -c SHA256SUMS.txt
gpg --verify SHA256SUMS.txt.asc SHA256SUMS.txt
# 2. check the signing key fingerprint against the one in the announcement
# 3. run the binary's own RandomX self-test by starting it once and checking the log
```

## Key hygiene

- Keep the release GPG key offline, back up the revocation certificate, and use
  a passphrase. It is separate from the seed node's
  `onion_v3_private_key` and from any wallet seed; losing the GPG key only
  affects future signatures.
- The key may be pseudonymous (`triplecN`). What matters is that the same
  fingerprint is published in the repository, in the release notes and in the
  announcement, so a change is visible.
- The release key fingerprint is
  `7D85B6F364CC47BA9209BB54F750900C7C911728` (`CacheCoin (CCCN) Releases
  <releases@cachecoin.org>`, expires 2029-10-02). The public key is
  `release-key.asc` in the repository root, and the fingerprint is repeated in
  the release notes. Compare it in both places before trusting a signature; a
  `SHA256SUMS.txt.asc` alone proves only that some key signed the checksum
  file.
- A previous release key, `C29445AE6CB253E9785BDD26DC20C5AA5BD13CFB`, is
  retired. Signatures made with it (the earlier drafts of the 0.1.0 Windows
  package) remain verifiable with its public key, but new releases are signed
  with the key above.

## Current limits

- Reproducible builds are not implemented: the checksum proves the file was not
  corrupted in transit and the signature proves who signed it, but nobody can
  yet rebuild the exact bytes. Do not claim reproducibility.
- Windows binaries are outside the suites.
- No binaries are attached to the repository itself; releases are produced
  from signed tags by the release workflow.
