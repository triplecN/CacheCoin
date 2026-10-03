# CacheCoin incident runbook

Written for whoever runs a node; this is the operations reference. Keep a copy
next to your backups.

## 0. Before anything goes wrong

- **Back up, offline:** the payout wallet seed/descriptor, `onion_v3_private_key`
  (keeps the same .onion address), and any GPG release key. Losing the onion key
  only changes your address; losing a wallet seed loses coins.
- **Run the invariant watcher** next to every node that matters:

  ```bash
  # once a minute, alarms land in the journal and the unit fails
  systemd-run --user --unit=cachecoin-watch --on-active=0 \
    python3 scripts/watch_invariants.py --loop 60 --txout
  ```

  It re-derives the PER accounting and the supply identity from the chain and
  exits 2 on any mismatch. An alarm means: stop spending, compare with a second
  independent node, and do not trust the explorer.
- **Watch three node facts**: `getchaintips` (branches), the `warnings` field of
  `getblockchaininfo` (the re-org barrier warning), and free disk. Every node
  stays archival because `-prune` is refused.

## 1. The chain looks split / nodes disagree

1. `cachecoin-cli getchaintips` on both sides. Two branches at the same height
   means a partition; the fork height is where they diverge.
2. `getblockchaininfo` shows a re-org barrier warning while the other branch has
   more work. Nothing is broken: the node keeps its chain until the other branch
   is more than 35 blocks past the fork (36).
3. To end it immediately on the side you want to leave, on a node on the losing
   branch:
   `cachecoin-cli invalidateblock <first block after the fork on that branch>`.
   The node rewinds and follows the other branch.
4. **Before re-sending any payment**, check `gettransaction <txid>` and
   `getrawmempool`: transactions from the abandoned branch normally return to the
   mempool by themselves. Re-sending without checking pays twice.
5. Delete `explorer/explorer.db` on explorer nodes after a split; it refuses to
   walk back more than 512 blocks.

## 2. Inflation alarm (watcher exit 2)

1. Do not spend. Do not "fix" a chain by hand.
2. Reproduce on a second, independent node with the watcher. If both alarm on the
   same height, the chain itself is inconsistent and the only correct response is
   a community decision; a bug that creates coins cannot be undone by patching a
   running node.
3. Keep the alarm output, the block hashes and the `getblock` JSON. That is the
   evidence an auditor needs.
4. If only one node alarms, that node's block data is damaged: see section 4.

## 3. Deep re-org / majority miner

- The barrier only delays a majority. A branch that is 36 blocks past the fork is
  followed by every node; the attacker pays those 36 blocks of their own mining.
- A ~50/50 split heals when one side reaches 36 past the fork: at an even split
  each side mines at half rate, so that is about 72 minutes on average, with a
  longer tail when the split is uneven. It also heals with the
  `invalidateblock` override above.
- Do not restart or `-reindex` during a split to "refresh" a node: a restart
  older than `-maxtipage` (24 h) forgets refusals and can move the node to the
  other branch.

## 4. Data corruption

- **Symptom:** block reads fail, `bad-crc`/hash mismatch in the log, the watcher
  alarms on one node only.
- `cachecoind -reindex` rebuilds the block index from the block files. It is
  safe and does not change consensus; it is slow.
- If a block file itself is damaged, restore it from a backup, or accept the
  chain up to the last intact block and re-sync the rest from peers.
- A failed read of PER history makes a real connect retryable, not silently
  accepted (patch 0013); a node that stalls on it needs the disk fixed, not a
  restart loop.

## 5. Clock

- Consensus allows a block at most 10 minutes ahead of the node's clock, and a
  block must be after the median of the last 11. The start-up check is looser
  (2 hours), so a node whose clock is 11-120 minutes slow starts "healthy" and
  then rejects every new block.
- **Symptom:** every incoming block is `time-too-new` (or, on a miner, every
  block you mine is refused locally); the node never advances.
  `deploy/home/mine.sh` refuses to mine when the tip is over 5 minutes ahead of
  the local clock, so a miner stops instead of wasting work.
- Fix the clock (NTP; under WSL `sudo hwclock -s` or `wsl --shutdown`), then
  restart the node.

## 6. No peers / Tor

- Tor must be running before the node starts; the shipped config points at
  `127.0.0.1:9050` (Tor Browser uses 9150).
- There are no DNS seeds. A fresh node finds nobody until you add
  `addnode=<host>:29333`. Publish and keep at least one long-lived onion seed
  reachable, and add more than one if you can: one seed is a single point of
  failure for the whole network.
- Shunko refuses to send without a proxy and a hidden-service target; that is
  intentional, not a bug.

## 7. Disk

- `-prune` is refused: PER payouts verify blocks up to a full epoch (40,320
  blocks) back, so every node is archival.
- Full blocks grow the chain by up to ~2.9 GB/day. Move the datadir to a bigger
  disk (stop the node, copy `~/.cachecoin`, restart with `-datadir`), or accept
  that a full disk stops the node.

## 8. Releases and consensus changes

- Build from `scripts/build_linux.sh` (it pins Bitcoin Core and RandomX), then
  sign: `bash scripts/release_sign.sh <dir> [gpg-key]`.
- **Any change under `patches/` changes block validation.** After block 1 that is
  a hard fork: nodes on the old rules reject the new blocks, and coins on the
  losing side are lost, not repriced. There are no version bits to activate a
  change; coordination is social.
- **Upgrade integrity.** Any future hard fork keeps the ledger intact: every
  block, coinbase and UTXO from genesis stays valid, there are no token swaps,
  migration contracts or balance resets, and the software keeps the RandomX
  light verification for blocks mined before the activation height. No founder,
  team or foundation holds admin keys; an upgrade activates only if independent
  node operators choose to run it.
- A new maintainer should re-run `scripts/build_linux.sh` and the fifteen suites
  before publishing anything.

## 9. Disclosure

- There is no private channel. Reports go to public issues; the request to hold
  a working exploit for 90 days is voluntary and cannot be enforced. If you run a
  fork and can offer a private channel, put it in `SECURITY.md` before launch.

## 10. Chain stalled: `getblocktemplate` refuses

- **Symptom:** no new block for more than a day, and `getblocktemplate` fails
  with "is in initial sync and waiting for blocks..." while
  `getblockchaininfo` shows `"initialblockdownload": true`.
- A node is in initial block download until its tip is newer than 24 hours.
  The genesis timestamp is fixed, so before block 1 every node is in IBD, and
  any node restarted after a >24 h stall re-arms IBD and refuses templates
  until a fresh block exists. Nodes that stayed running are not affected: the
  flag latches off once and never re-arms inside the same process.
- **Recovery:** produce one block with `generatetoaddress` (the shipped
  `deploy/home/mine.sh` path) or `generateblock`; the fresh tip
  clears IBD for every node that receives it. A miner set that only uses
  `getblocktemplate` has no template to mine during the stall, so keep one node
  that can mine locally, or set `-maxtipage=<seconds>` (hidden debug option,
  e.g. `-maxtipage=31536000`) so a restarted node leaves IBD immediately.
- Bootstrap follows the same rule: mine the first block locally (see
  `doc/mining.md`), then external tooling works.

## 11. Handover checklist

- [ ] Wallet seed/descriptor and onion key backed up offline.
- [ ] At least two independent seed nodes reachable; addresses published.
- [ ] Watcher running and alerting somewhere a human sees.
- [ ] Release signing key backed up; `SHA256SUMS.txt` published with binaries.
- [ ] This runbook copied somewhere outside the repository.
- [ ] A second person knows how to build, test and run a node.
