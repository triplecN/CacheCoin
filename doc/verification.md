# Verification record

What was verified, with which hashes, and how to reproduce it. Hashes are for
the state below; changing any file under `patches/` changes them, and the binary
hash can differ between build environments until reproducible builds exist.

## Verified state

- This tree is the public snapshot. The development history and the audit
  trail are kept privately; verify the state with the fingerprint, the applied
  tree id and the binary hash below, not by commit hashes.
- Base pins: Bitcoin Core `v31.1` commit
  `9be056a8a72b624dae9623b2f7bded92c2a21c91`; RandomX commit
  `7607fb2faed24d5a679e139a9828d194bbc644a4`
- Patch series: 20 patches. Fingerprint (sha256 of `cat patches/*.patch`):
  `6a89aa144620ea2c019f2678ea80ae8b2de45544bc64d871cd3bb2fefcf1ddda`.
  The patch files were cleaned of development-history wording (mail subjects,
  bodies, two filenames, and comments that patch 0012 removes again); the
  diff content that survives into the tree is untouched, and applying the
  series to a fresh worktree was re-run to confirm it yields exactly the
  verified source tree (`git write-tree` =
  `5d28bf7d71b3badb2b8866a540d0300102b2b841`), so the binary hash below still
  applies.
  (`scripts/build_linux.sh` stores the same value in `.cachecoin-patches` of the
  build tree; compare it before trusting a build.) Apply the series with
  `git apply`, as `scripts/build_linux.sh` and `doc/build-windows.md` do: the
  mail headers use `by:` instead of `From:`, so `git am` is not supported.
- Node binary observed on the maintainer's WSL2 x86-64 build:
  `d96aaa01ad58efd99120cee705971d5dab8f939a5e48d2a6072f52430b64fc70`
  (`cachecoind`, `--version` reports v31.1.0). A fresh build may differ.

The full 13-suite run was at `ce3ea38`. After it, `tests/lwma_check.cpp` gained
the pulse-mining scenario, `tests/swap_scripts_regtest.py` was added,
`patches/0016` fixed the PER payout sigop bound and the pool-drain order,
`patches/0017` reordered header hashing, refused `-coinstatsindex` and fixed
the Shunko and RPC findings, `patches/0018` caches ticket records, refuses
recently embedded tickets at relay, throttles template rebuilds, gives the
mainnet xprv distinct version bytes and adds the ticket-script fuzz target, and
`patches/0019` makes the automatic Shunko target selection skip configured
nodes (`-connect`, `-addnode`, `-seednode`, `addnode` RPC), and `patches/0020`
fixes the runtime `addnode` case while that node is disconnected (0019 relied
on a resolved address that is empty for a down node) and adds the regression
case to `tests/shunko_regtest.py` [6b]. All 15 suites and the six fuzz targets
were re-run on the 20-patch binary, and the series was applied to a fresh
worktree to confirm it produces exactly the verified source tree. Re-run the
list below to reproduce all 15.

### Independent clean-room rebuild

A separate rebuild (documentation-only changes on top of the reviewed state)
started from a pristine Bitcoin Core v31.1 checkout and reproduced the patch
fingerprint and the applied tree id. On the same Ubuntu/WSL2 toolchain it also
produced the binary hash `fc41e132...`; bit-for-bit reproducibility across environments is not
implemented (`doc/release.md`), so this is evidence from one toolchain, not a
guarantee. Later patch states (0019 and 0020) have local verification only and
were not independently rebuilt. All 15 suites passed, all
six fuzz targets ran 200,000 runs each under AddressSanitizer and
UndefinedBehaviorSanitizer with no crashes, and the F-01 mutation test was
repeated from the reviewer's own edit: with the fix disabled by
`if (false && chain_start == nullptr && !in_presync)`, `p2p_dos [8]` failed
after 3.82 s; with the original file restored it passed in 0.00 s. The reviewer
also re-checked the 0018 caches for thread safety, bounded memory and fail-open
behavior, that `PerEmbeddedRecently` is cache-only under `cs_main`, that the GBT
throttle cannot leave a template stale indefinitely (the tip changes bypass it
and `nPerPoolVersionLast` is only updated on rebuild), and that the extended-key
version bytes have no consensus role and leave testnet/regtest/signet
untouched.

## Suites and expected closing lines

| Suite | Closing line |
|---|---|
| `tests/functional_regtest.py` | `ALL CHECKS PASSED` |
| `tests/per_regtest.py` | `PER CHECKS PASSED` |
| `tests/shunko_regtest.py` | `ALL CHECKS PASSED` |
| `tests/p2p_dos_regtest.py` | `ALL CHECKS PASSED` |
| `tests/explorer_regtest.py` | `EXPLORER CHECKS PASSED` |
| `tests/mainnet_smoke.py` | `MAINNET SMOKE TEST PASSED (nothing was mined)` |
| `tests/durability_regtest.py` | `DURABILITY CHECKS PASSED` |
| `tests/per_invariants.py` | `PER INVARIANTS PASSED` |
| `tests/per_adversarial_regtest.py` | `PER ADVERSARIAL CHECKS PASSED` |
| `tests/lwma_check.sh` | `LWMA CHECK OK: 0 failure(s)` |
| `tests/emission_check.py` | `EMISSION CHECK PASSED` |
| `tests/wallet_reorg_regtest.py` | `WALLET REORG CHECKS PASSED` |
| `tests/soak_regtest.py` | `SOAK CHECKS PASSED` |
| `tests/swap_scripts_regtest.py` | `SWAP SCRIPT CHECKS PASSED` |
| `tests/watcher_conformance_regtest.py` | `WATCHER CONFORMANCE CHECKS PASSED` |

Fuzzing: six targets (`per_ticket_roundtrip`, `per_ticket_deserialize`,
`per_commitment_roundtrip`, `per_parse_commitment`, `per_next_state`,
`per_ticket_script`). The five original targets ran 200,000 runs each on the
17-patch binary; on the 18-patch binary the new target ran 200,000 runs and the
other five 50,000 runs each, with AddressSanitizer and
UndefinedBehaviorSanitizer, no crashes. The independent re-verification then ran
all six targets 200,000 runs each on the same source state, also without a
crash. On the earlier 19-patch binary all six targets were run again, 50,000 runs each,
without a crash.

Deterministic highlights of that run:

- LWMA: 90% hash-rate drop settles at 9.85x, recovery returns to 1.00x; pulse
  mining (10x/0.1x alternating) keeps the target in 0.59x..6.23x and the swing
  damps (6.42x early, 1.00x late).
- Emission: total supply 21,020,399.863344 CCCN, exactly `MAX_MONEY` minus
  0.136656 CCCN; every regtest subsidy 1..752 matches an independent schedule.
- PER invariants: 169-block chain and a re-org to 179 blocks, every commitment,
  payout and the supply identity re-derived in Python.
- Durability: `kill -9`, `-reindex`, deleted block index, deleted chainstate,
  truncated block file, bit-flipped header, all recovering to the same tip,
  UTXO set and PER state.
- Soak: 1,120 blocks with fees and tickets, then the invariant watcher run on
  the full chain and again after a re-org (checkpoint rewind, no false alarm).
- Swap scripts: hashlock claim/refusal, CLTV height and median-time-past
  boundaries, a 512 s CSV unit maturing after 8 blocks, a re-org removing the
  confirmed output while the mempool view keeps showing it, and both claim and
  refund being valid at the timeout boundary.
- PER hardening (0016): a payout script full of CHECKMULTISIG is rejected when
  the ticket is embedded (`bad payout script`), and a block with a valid ticket
  slice but a wrong committed state is rejected without draining the local
  ticket pool.
- PER hardening (0018): a ticket embedded within the last window is refused at
  relay from the in-memory cache before it can spend a rate-limit token or a
  RandomX hash. The `p2p_dos [8]` regression test that backs the 0017
  header-hashing fix is mutation-verified: with the fix disabled the same batch
  fails (maintainer run 3.97 s; independent run 3.82 s), with it it passes in
  0.00 s. An earlier version of that
  test sent 80-byte header records, which the node rejected before hashing, so
  it passed vacuously; the fixed test sends the per-header tx count (81 bytes
  per record).
- Shunko (0019): the automatic path of `shunkobroadcast` never picks a
  configured node (`-connect`, `-addnode`, `-seednode`, `addnode` RPC), down or
  up, while explicit targets are unchanged; `shunko_regtest` passes. The
  behavior has a regression test (`tests/shunko_regtest.py` [6b]: the test
  node's only addrman entry is its down configured onion, so auto-selection can
  only end in "No known nodes" if the exclusion is active), mutation-verified:
  with the `!is_configured` filter removed, [6b] fails and the error changes to
  the mempool-validation error; with it, [6b] passes. Reproduced independently:
  the reviewer removed the filter, saw [6b] fail with the mempool-validation
  error, restored the file, and confirmed the binary hash and a full suite pass. The explorer `/api/info`
  now derives the fee totals in one scan of `blocks` instead of two.

## How to reproduce

```bash
bash scripts/build_linux.sh
B=~/cachecoin-build/cachecoin-v31.1
python3 tests/functional_regtest.py "$B/build/bin/bitcoind"
python3 tests/per_regtest.py "$B/build/bin/bitcoind"
python3 tests/shunko_regtest.py "$B/build/bin/bitcoind"
python3 tests/p2p_dos_regtest.py "$B/build/bin/bitcoind"
python3 tests/explorer_regtest.py "$B/build/bin/bitcoind"
python3 tests/mainnet_smoke.py "$B/build/bin/bitcoind"
python3 tests/durability_regtest.py "$B/build/bin/bitcoind"
python3 tests/per_invariants.py "$B/build/bin/bitcoind"
python3 tests/per_adversarial_regtest.py "$B/build/bin/bitcoind"
python3 tests/emission_check.py "$B/build/bin/bitcoind" "$B"
python3 tests/wallet_reorg_regtest.py "$B/build/bin/bitcoind"
python3 tests/soak_regtest.py "$B/build/bin/bitcoind"
python3 tests/swap_scripts_regtest.py "$B/build/bin/bitcoind"
python3 tests/watcher_conformance_regtest.py "$B/build/bin/bitcoind"
bash tests/lwma_check.sh "$B"
bash tests/run_fuzz.sh "$B" 200000
```

## Verification boundaries

- ARM64: the workflow exists; this record is x86-64. Windows `.exe` files are
  built by CI and are outside these suites.
- External audit, a second proof-of-work implementation, reproducible builds
  and a separate public test chain are outside this record.
- Transaction and signature validation, chainstate corruption and power loss
  mid-flush are inherited or untested here; `SECURITY.md` lists the rest.
- `bitcoin-util` is not built by the supported script (`BUILD_UTIL` is off) and
  its `grind` helper still searches SHA256d, so it cannot produce a valid CCCN
  block. Mine with `generatetoaddress` or another RandomX miner.
- The fuzz targets are unit-level: serialization, parsing and the state
  transition formula. They do not reach `CheckPerTicketsAndPayouts` or
  `ConnectBlock`; that integration is covered by the regtest suites
  (`tests/per_adversarial_regtest.py`, `tests/per_regtest.py`,
  `tests/per_invariants.py`), which is also where upstream Bitcoin Core draws
  the line (its block fuzzer stops at `CheckBlock`).
- Adversarial audits of the patch series found no inflation, permanent split,
  balance-theft or permanent-wedging path; the findings that survive are
  accepted as-is because fixing them changes consensus rules. See
  `doc/consensus-audit-notes.md` for the list and the reasoning.
