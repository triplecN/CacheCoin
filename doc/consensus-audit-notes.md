# Consensus patch audit notes (accepted findings)

An adversarial audit of the 20-patch series (Byzantine assumptions: hostile peers,
timestamps, blocks, mempool, majority hash power, crashes, restarts, reindex, clock
jumps) found **no path to inflation, permanent chain split, balance theft, or permanent
wedging without majority hash power**. The findings below survive and are accepted as-is,
because fixing them changes consensus rules, and that cannot be done on a live chain
without a deliberate, coordinated fork.

- **Ticket selection order (B1).** The PER pool serves tickets in ascending id order with
  a 64-per-block cap, and a ticket's proof target is 16x easier than the block target. A
  funded miner can grind low ids and dominate the slots, capturing reservoir revenue from
  honest ticket miners. It is economic capture, not inflation: payouts are still
  `pool / tickets` and the pool only ever holds collected fees.
- **RandomX verification under cs_main (B7).** Up to 64 unique tickets are verified inside
  `ConnectBlock` while `cs_main` is held (~1.28 s for a full block at low difficulty),
  roughly a 64:1 cost amplifier for an attacker. A denial-of-service vector, not a
  consensus break. A verdict-preserving pre-verify cache could mitigate it in a future
  release; that would change the patch fingerprint, not the consensus rules.
- **Timestamp-density difficulty movement (A1b).** Dense but legal timestamps can move the
  next target by a few percent per block; the earlier "10x per block" claim was refuted.
  Griefing at most; the network re-converges and a cheaper chain loses the work
  comparison.
- **The reorg barrier is height-based (C1).** After a candidate leads the fork by more
  than 35 blocks (i.e. 36) the barrier releases, so a majority attacker can still
  deep-reorg. This is the deliberate design from patch 0010: the barrier makes deep reorgs
  require a supermajority lead, it does not make them impossible.
- **Proof of work is not re-verified when blocks are read from local disk (A4/C6).**
  `LoadBlockIndexGuts`/`ReadBlock` only range-check nBits and `ConnectBlock` uses
  `fCheckPOW=false`; a corrupt or manipulated local datadir could connect an invalid
  block. There is no remote path, and `-reindex` revalidates. This matches upstream's
  trust model for local storage.
- **PER pool flood at very low difficulty (B2).** The pool is capped (10,000), the
  per-peer token bucket refills at 4/s, and stale tickets are swept; sybils can still
  crowd the lottery while the ticket price is low. Relay-policy mitigations (per-netgroup
  quotas, no reconnect reset) are possible without consensus changes.

**No change to `patches/` is planned for these findings.** Any future fix that touches
consensus must ship as a deliberate, audited fork with a new patch fingerprint and a new
verification record.
