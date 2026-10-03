# Exchange integration guide

What a centralized exchange needs to integrate CCCN natively, and what this
repository does and does not provide. Informational only: exchanges are outside
the project's security scope (`SECURITY.md`), and nothing here is an endorsement,
an SLA or a promise of listing.

A bridge or wrapped asset is **not** part of this and is not needed for a
listing. Exchanges integrate the native coin by running nodes and handling
deposits and withdrawals themselves; see "Bridges" at the end.

## 1. Nodes

Run at least two independent full nodes, ideally from different providers, plus
one more for the wallet:

- Every node is **archival**: `-prune` is refused, because PER payouts verify
  blocks up to a full 28-day epoch back. Full blocks grow the chain by up to
  ~2.9 GB per day. Budget disk accordingly.
- There is **no `assumevalid`** and no snapshot shortcut: every block is fully
  validated from genesis. Initial sync is CPU-bound (RandomX), so plan hours,
  not minutes, on a small VPS.
- **Tor must be running before the node starts.** There are no DNS seeds and no
  fixed seeds. Join the network with one or more `addnode=<onion>:29333` lines
  (the published seed addresses) plus `proxy=127.0.0.1:9050` and
  `onlynet=onion`. See `deploy/README.md`.
- Keep the wallet (`disablewallet=0`) on one node only; watch/validation nodes
  should run `disablewallet=1`. `txindex=1` is needed if you build your own
  indexer.
- Watch the clock: a block more than 10 minutes ahead of the node is rejected
  (`time-too-new`), and a clock that is slow makes the node look stuck. Enable
  NTP. `doc/incident_runbook.md` §5 describes the symptom.

## 2. Addresses and keys

- Native SegWit Bech32 HRP `cccn` (`cccn1q...`). P2PKH Base58 version `28`
  (`C...`), P2SH `88`, WIF `156`.
- The legacy `C...` prefix is shared with an unrelated 2014 altcoin; prefer
  `cccn1q...` and whitelist the `cccn` HRP in deposit scanners. Bitcoin
  addresses are rejected by the node (`tests/mainnet_smoke.py` asserts this).
- Descriptor wallets only. `importprivkey` does not work; import with
  `importdescriptors` (`wpkh(...)` / `pkh(...)`). `scripts/keygen.py` can
  generate keys offline; its Python point multiplication is not constant-time,
  so treat the machine accordingly.

## 3. Confirmations and re-org policy

This is the part that differs most from Bitcoin and must be enforced in code,
not in a runbook:

- The node follows a re-org that undoes up to **5** of its own blocks and
  refuses deeper ones until the competing branch is more than **35** blocks past
  the fork (release at 36). `tests/functional_regtest.py` asserts 5/6 and 35/36.
- Two documented bypasses: `-reindex` disables the barrier, and a restart when
  the tip is older than `-maxtipage` (24 h) makes the node follow the most-work
  chain with no barrier. A node down for more than a day can therefore accept a
  deep re-org on restart; re-verify credits after such an outage.
- The barrier does not stop a majority. A branch 36 past the fork is followed by
  everyone. A ~50/50 split can hold for hours.
- README §1.2 recommends **10 confirmations, and 60+ for large amounts, while the
  network is young**. Treat that as a floor, not a promise.
- Gate crediting on state, not just a count: do not credit while
  `getblockchaininfo.warnings` is non-empty (the re-org barrier warning) or while
  `getchaintips` shows competing branches. Require agreement between your own
  independent nodes on the block hash at each height.
- `tests/wallet_reorg_regtest.py` is the conformance case: a confirmed payment
  is re-orged out, the wallet reports zero confirmations, the transaction
  returns to the mempool, `listsinceblock` lists it unconfirmed, and it confirms
  again on the new branch. A wallet that keeps the old confirmation would let a
  deposit be credited against a transaction that no longer exists.
- On a re-org, transactions from the abandoned branch normally return to the
  mempool on their own. Check `gettransaction` (confirmations 0) and
  `getrawmempool` before re-sending; re-sending without checking pays twice.

## 4. Deposits and withdrawals

- Track the canonical chain by height: poll `getbestblockhash`, `getblockhash
  <height>`, `getchaintips` and `warnings`. There is no webhook, no ZMQ setup
  and no metrics exporter; build the watcher yourself or adapt
  `scripts/watch_invariants.py`.
- Wallet-side, `listsinceblock <fork_hash>` is the hook for re-org-aware
  deposit scanning (see the conformance case above).
- Withdrawals use the inherited Bitcoin Core wallet and policy. Fee-estimator
  horizons are in blocks on a 60-second chain: `estimatesmartfee 6` means about
  6 minutes. Shipped configs set `fallbackfee=0.0001` because the estimator has
  little data on a young chain.
- RBF and CPFP behavior is inherited from Bitcoin Core v31.1 and is **not
  tested by this repository**. Treat unconfirmed transactions as replaceable and
  verify the behavior you rely on on regtest.
- Coinbase maturity is **100 blocks**. PER payouts are coinbase outputs too, so
  they mature the same way. PER payouts can be below 1000 sat: set an economic
  dust threshold when sweeping.
- PER does not change the UTXO model or your accounting. Half of every fee goes
  to the reservoir and is paid to ticket miners one epoch (28 days) later; it is
  not burned and not paid to the block's miner. `getblockstats.subsidy` is only
  the subsidy; the coinbase may also contain reservoir payouts.

## 5. Do not enable Shunko on an exchange node

Shunko requires `walletbroadcast=0`, which suppresses your own broadcasts and
would break withdrawal announcement. It is opt-in and irrelevant to exchange
operations. Leave `walletbroadcast` at its default and do not run
`shunkobroadcast`.

## 6. Monitoring

At minimum, alert on: `getchaintips` (branches), the `warnings` field, free
disk, peer count, block height advancing, clock offset, and the RandomX startup
self-test line in the log. Run `scripts/watch_invariants.py` next to every node
that matters: it re-derives the PER accounting and the supply identity and exits
2 on a mismatch. `doc/incident_runbook.md` is the response guide.

## 7. Testing and verification

- CacheCoin has one public chain (mainnet); `-testnet`, `-testnet4` and
  `-signet` are disabled by design. Rehearse integration against `-regtest`
  or a private build before touching the public chain.
- `doc/verification.md` records the verified commit, the patch fingerprint and
  the observed binary hash, and lists the 15 suites with the commands to
  reproduce them. Compare the patch fingerprint before trusting a build.
- Do not run binaries from an untrusted source. Releases are built by CI and the
  checksum file is signed offline (`doc/release.md`); a bit-for-bit
  reproducible build is not implemented.

## 8. Known gaps for exchanges

- Binaries are published from signed releases (`doc/release.md`), not attached
  to the repository; ARM64 and Windows builds are outside the Linux/WSL2 suites.
- Mainnet and `-regtest` only; no assumevalid, no pruning, no hosted explorer
  (the bundled one is a local Python app), no metrics/alerting service, no
  private vulnerability channel and no SLA.
- Transaction and signature validation, chainstate corruption and power loss
  mid-flush are not tested here (`SECURITY.md`).

## Bridges

A bridge, wrapped asset or peg/validator layer is not part of CacheCoin and is
not needed for a listing. It cannot be made trustless on this codebase: CCCN has
no light client for another chain, RandomX cannot be verified in Bitcoin Script
or the EVM, and there is no slashing or token layer, so a peg is custodial by
construction. Peer-to-peer atomic swaps with BTC are possible in principle
because CCCN inherits Bitcoin Script, but any swap tooling is third-party: the
repository tests the hashlock/CLTV/CSV templates without signatures
(`tests/swap_scripts_regtest.py`), not signature validation or any swap client.
See `SECURITY.md` ("Out of scope").
