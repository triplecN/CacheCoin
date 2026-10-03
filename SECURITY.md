# Security policy

## Supported versions

CacheCoin was started by triplecN. Only the current `main` tree and the most recent release are supported: there is no long-term support branch, no backport policy and no maintenance window, and each release is a snapshot provided as-is. Forks set their own policy. After block 1, any change under `patches/` is a hard fork with no version-bits activation (coordination is social; `doc/incident_runbook.md` section 8). The public chain is mainnet; local development and rehearsal use `-regtest` or a private chain (`-testnet`, `-testnet4` and `-signet` are refused by design, README section 2, asserted by `tests/functional_regtest.py` [14]). Verify a build by comparing the `patches/*.patch` fingerprint and the applied tree id recorded in `doc/verification.md`.

What is covered by the test suite is the tree reproduced by `scripts/build_linux.sh` and the fifteen suites listed in README section 6; `doc/verification.md` records the patch fingerprint, the applied tree id, the observed binary hash and the expected closing line for each suite. The re-org boundary is pinned there too: a split heals exactly at 36 blocks past the fork, with 35 still refused, which `tests/functional_regtest.py` asserts.

## Threat model

The asset is the ledger: no inflation beyond the emission schedule, and no double-spend beyond the proof-of-work re-orgs every chain of this kind inherits. The node assumes that RandomX v1 with one fixed key is the only proof of work; that a majority of hash rate can re-org the chain (the barrier delays it, it does not stop it); that Tor hides the network origin only; and that each operator secures their own keys, clock and disks. It does not defend against a majority miner, a compromised build machine or endpoint, third-party wallets, exchanges, bridges or hosted services, and it cannot verify another chain's state (README section 11, "Out of scope" below). Accepted risks are listed below; untested areas are listed in this section and in `doc/verification.md`.

## What the test suite covers, and what it does not

The suite is roughly 3,000 lines in `tests/` and covers 15 suites. It has about 250 named assertions, mines several thousand blocks under real RandomX across 24 node processes, forges 20 blocks with the test's own prover, and sends several hundred hand-assembled P2P messages. Roughly two dozen checks are adversarial and expect a failure. `tests/per_invariants.py` re-derives the whole PER accounting and the supply identity in Python, independently of the node, over a chain that includes a re-org past an epoch boundary. `tests/per_adversarial_regtest.py` submits hand-built blocks that break each PER rule and checks the rejection reason, including a sigop-bomb payout script and a wrong-state block that must not drain the local ticket pool. `tests/emission_check.py` compares the node's own subsidy at 752 heights with an independent schedule and checks the whole mainnet emission against `MAX_MONEY` (the 0.136656 CCCN headroom). `tests/wallet_reorg_regtest.py` re-orgs a confirmed payment out and checks the wallet reports it unconfirmed and lists it in `listsinceblock`. `tests/soak_regtest.py` soaks a 1,000-block chain with fees and tickets and runs `scripts/watch_invariants.py` twice, including a re-org rewind. `patches/0014-0015` and `0018` add six libFuzzer targets for the ticket serialization (including raw deserialization of untrusted bytes and the ticket-script parser), the commitment parser and the reservoir state transition; `tests/run_fuzz.sh` builds and runs them.

The re-org barrier is tested at its boundary. Depth 5 is followed and depth 6 is refused, a split heals at 36 blocks past the fork but not at 35, and a refusal survives a restart. The per-block fee split is checked in the node (`tests/functional_regtest.py`, `tests/per_regtest.py`) and the whole PER accounting is re-derived independently in Python by `tests/per_invariants.py`; the explorer reports gross cumulative fee/2, not the live reservoir. Coinbase maturity is asserted against consensus, not just against wallet policy. `tests/lwma_check.sh` also simulates a 90% hash-rate drop and recovery on synthetic chains: the difficulty must never move the wrong way, settles at the 10x easier target the hash rate needs, and returns to where it started. A pulse-mining scenario (hash rate alternating 10x and 1/10x every 15 blocks for 40 cycles) keeps the target between 0.59x and 6.23x of the base target, and the swing damps instead of growing: no harmonic resonance.

What the suite does **not** cover:

- **Transaction and signature validation.** No test adversarially exercises signature validation. Wallet-signed spends are built and accepted in several suites (`tests/functional_regtest.py` [7], `tests/wallet_reorg_regtest.py`), so the ECDSA/DER happy path runs, but ECDSA/Schnorr edge cases, DER malleability and non-standard encodings are not tested here. `tests/swap_scripts_regtest.py` drives the inherited script interpreter through the hashlock, CLTV and CSV templates an atomic swap would use, with signature-free scripts; the only adversarial transaction test is a Shunko double-spend refusal.
- **Power-loss and data corruption.** `tests/durability_regtest.py` covers `kill -9`, `-reindex`, a deleted block index, a deleted chainstate directory (rebuilt from the block files without `-reindex`), a truncated block file and a bit-flipped block header; after each recovery the tip, the UTXO set and the PER state must be identical, and damaged data is never served as valid. There is still no test that corrupts the chainstate database or cuts power in the middle of a flush.
- **The mainnet halving schedule and the `MAX_MONEY` margin.** `tests/emission_check.py` checks the node's subsidy at 752 regtest heights against an independent schedule, reads the mainnet constants from the patched tree, and asserts that the whole emission totals exactly `MAX_MONEY` minus 0.136656 CCCN. `scripts/check_supply.py --check` asserts the schedule and the cap margin without a node, and the mainnet schedule is checked against the patched constants rather than a live mainnet chain.
- **Shunko over Tor.** Target selection is tested end to end through a local SOCKS5 forwarder: fake onion names map to regtest nodes, so connected-peer exclusion and target rotation are exercised over the node's own onion path. That is not Tor. There is no onion service and no anonymity network, and nothing checks whether the sender's address is hidden from an observer.
- **Fuzzing.** `patches/0014-0015` and `0018` add six libFuzzer targets for the PER ticket
  serialization and id, raw ticket deserialization of untrusted bytes, the ticket-script parser
  (arbitrary script bytes must not crash it, and anything it accepts must re-encode to a script
  that parses back to the same id and payout), the commitment parser, the payout-script bound and
  the reservoir state transition. They are built and run manually with clang (`tests/run_fuzz.sh`), not by CI and not by `scripts/build_linux.sh`; a bounded run is not a proof of absence. Bitcoin Core's own fuzz targets are not built or run here.
- **An independent proof-of-work implementation.** The RandomX library is upstream tevador/RandomX at a pinned commit, unpatched, and `scripts/build_linux.sh` runs upstream's own assert-backed test vectors as a build gate. The genesis digest in
`patches/0002` and `scripts/reproduce_genesis.py`, however, is a recorded known answer. The script that first derived it (`genesis_miner.py`) is not in this repository, and the runtime check compares the node against that same constant. No test recomputes the genesis proof of work with a second implementation.
- **The `time-too-new` boundary.** It is tested at 5 and 11 minutes. The actual 10-minute boundary is not pinned.
- **Other platforms.** All node suites run on Linux/WSL2 only (they rely on fixed `/tmp` paths, `preexec_fn` and `prctl`). The Windows binaries built by CI are outside these suites; `doc/build-windows.md` builds them by hand.
- **Continuous integration.** This record is from local runs: reproduce the suites with `scripts/build_linux.sh` and README section 6. The CI workflows build Linux, Windows and ARM64 from the same tree.
- **Upstream's own C++ test suite.** Bitcoin Core's ~100 functional tests and its fuzzing targets are not run here. `BUILD_TESTS=OFF` in the CacheCoin build, so the test sources are not even compiled. CacheCoin's suite covers its own consensus rules; it does not re-verify the inherited Bitcoin Core code.
- **The Bitcoin Core base.** CacheCoin is built directly on Bitcoin Core v31.1 and the
  series was reviewed hunk by hunk; that is a review, not a rewrite from scratch. The
  coinbase follows v31.1 (`nLockTime = height - 1`, `nSequence = MAX_SEQUENCE_NONFINAL`),
  so the block byte format is fixed from the first block. Before block 1 the format is
  free to change; after it, it cannot.

- **PER reservoir payout timing.** A ticket is paid in the coinbase of the block one epoch after the block that embedded it, so an epoch's tickets are paid out across the whole redemption epoch rather than all at once. The rate is fixed when the epoch closes. That is not an accounting problem, and the balance is tracked exactly; see "The reservoir pays out every ticket of the epoch" below. What is unaudited is the economics, not the bookkeeping.

## Verification and audit status

No external audit has been performed. `doc/verification.md` records the verified state: the patch fingerprint `6a89aa14...`, the applied tree `5d28bf7d...`, one observed binary hash, and the 15 suites and the 6 fuzz targets run against the 20-patch tree. An independent clean-room rebuild covered the earlier 18-patch state only; the current state has local verification. The rebuild reproduced that state's fingerprint and tree id on the same toolchain. Adversarial reviews (five layers plus three independent AI audits, recorded in the gitignored `audit/` directory, not shipped) found no Critical or High issue; the one Medium was operational -- `getblocktemplate` refuses while the node latches initial block download -- and is documented with its recovery in `doc/incident_runbook.md` section 10. PER economics remains unreviewed externally (README section 1.6). Builds are not bit-for-bit reproducible, so compare the patch fingerprint before trusting a binary.

## The patch series

`patches/` holds the twenty commits that apply the CacheCoin changes on top of Bitcoin Core v31.1, in order, applied to the peeled commit of tag `v31.1`, `9be056a8a72b624dae9623b2f7bded92c2a21c91`.
`0011` re-anchors `generateperticket` during the search, stops the `perticket` rate
limiter from charging for tickets the node already has, and fixes the
`-DCACHECOIN_RANDOMX=OFF` build; it also briefly made an unreadable history block
return an empty ticket set, which `0013` reverts to fail-closed. `0012` removes stale
development comments and dead code. Inspect the series hunk by hunk before relying on
any single patch. `scripts/build_linux.sh` verifies the Bitcoin
Core base commit and the RandomX commit and refuses to build if either has moved, and it
resets the tree to that base and reapplies the whole series whenever `patches/` changes.
What it does not do is pin a hash of the series itself: reordering or editing files inside
`patches/` would still be built, so a change there wants a human to look at it. It does
refuse a tree that still contains a merge conflict marker, because a marker that survives
into the build is compiled as nonsense or, worse, silently keeps one side of a merge.

Two things are not in the patch series because they are not CacheCoin's: RandomX itself,
which the build script clones at a pinned commit and verifies, and the fifteen test suites
under `tests/`, which live in this repository directly.

## The re-org barrier: what is local and what is not

The barrier has two rules measured from two different places, on purpose.

**Catch-up is always allowed.** A candidate that builds on the node's own tip disconnects
nothing, so it is ordinary catch-up rather than a re-organization, and it must keep working
however far behind the node is. A rule that only looked at the candidate's distance from the
fork would refuse everything from the sixth block onward, leaving a node that had been briefly
offline unable to advance at all.

**The refusal is local.** Beyond catch-up, what is limited is how much of *this* node's chain
the switch would undo: `rollback = reference->nHeight - fork->nHeight`, and `rollback <=
MAX_REORG_DEPTH` (5) is allowed. That number is local, and has to be, because it is what this
node would actually give up.

**The release is deterministic.** A refused branch is let through once
`candidate->nHeight - fork->nHeight > MAX_REORG_DEPTH + REORG_HEAL_LEAD_BLOCKS`, that is 36
blocks past the fork. It is measured from the candidate rather than from a local tip, so every
node lets the same branch through on the same block and a split always resolves at the same
height.

This replaced a formulation that measured the depth against the tip the node happened to
start from. That number is local: a node that was one block behind computed a different
depth for the same candidate, so two nodes holding identical data could adopt opposite
active chains, and the release condition was local too, so the node that had accepted
could not tell the node that had refused that it should catch up. Because a six-block
re-org is an ordinary event on a 60-second chain, that was reachable without any attacker.

Two escape hatches went with it, because both were stated against a local tip and could
not be made deterministic: a branch carrying more than twice the work since the fork, and a
branch 30 blocks of work ahead. The practical difference is that a deep but legitimate
re-organization is now delayed rather than released early. It is not discarded, and the delay
is counted in blocks rather than work, so it does not drift with difficulty.

`-reindex` turns the barrier off, and so do `-reindex-chainstate` and a lost chainstate
(catch-up from genesis runs with the barrier off), and so does catch-up on a node whose tip
is older than `-maxtipage`, 24 hours by default, while the node is still in initial block
download (that is, at start-up after a long outage). In all of these cases the node follows
the most-work chain without consulting the barrier, so a node that was offline for a day
forgets what it had refused. A node that has already left initial block download keeps the
barrier even if its tip later ages past `-maxtipage`; the 36-block release still heals the
split.

`invalidateblock` is the operator override (README section 1.2); `reconsiderblock` undoes it. The barrier is also off during `-reindex`, `-reindex-chainstate` (or a lost chainstate) and catch-up at start-up on a node whose tip is more than `-maxtipage` old, as described above.

## The reservoir pays out every ticket of the epoch, one block at a time

An epoch's fee share is divided across every ticket seen in the epoch, giving a per-ticket
rate. The rate is fixed once, when the epoch closes, and each ticket is paid in the coinbase
of the block exactly one epoch after the block that embedded it. Since that redemption point
moves one block per height, the payout happens on every block of the redemption epoch, not
only on the first block of it.

The reservoir is therefore debited for the whole epoch at the boundary block and paid out in
installments afterwards, and `pool` at any moment is the fees collected so far minus what has
already been paid, plus whatever has been collected for the epoch that has not closed yet.

The boundary block pays out for the first block of the epoch just closed, and the remaining
blocks of that epoch are paid out over the blocks that follow; the accounting balances.
`tests/per_regtest.py` covers the fee split and the epoch payout.

## Ticket replay detection fails closed

A ticket counts once per window. The ids of the tickets embedded by each block are kept
in memory and populated when the block connects, so a running node does not have to read
history blocks back to check the window. If a block in the window still has to be read
and the read fails, a real connect returns a retryable error: the block is not accepted
and not marked invalid, and the node tries again. The miner embeds no tickets until a read
succeeds again, so it degrades instead of wedging. An unreadable block is never treated as
"no tickets", because that would let a replayed ticket be paid twice out of the same
reservoir. `tests/durability_regtest.py` covers the recovery paths; the fail-closed path
itself needs a read fault to exercise and is not covered by a test.

## Long-run monitoring

`scripts/watch_invariants.py` is not part of the test suite: it is a live monitor
that walks new blocks and re-derives the PER accounting and the supply identity,
exiting 2 on any mismatch so a service manager or alerting script can notice. It
keeps a checkpoint and survives re-orgs. Run it next to any node whose operator
wants early warning; `doc/incident_runbook.md` describes how to react.

## Reporting a vulnerability

Public issues are the one place every fork can see, and they remain the default. If GitHub private vulnerability reporting is enabled in the repository settings, a weaponizable report can also be sent through the Security tab; if it is not enabled, open a public issue that says only that a report exists and ask for a contact, and do not put exploit details in that first public message. Any private channel is best-effort, not a response commitment; there is no SLA or bounty.

Include:

- the affected file or patch, and the line;
- steps to reproduce (regtest commands preferred; mainnet and `-regtest` are the supported chains);
- the impact, if you know it. From most to least severe: inflation, consensus fork, fund loss, remote crash, DoS, privacy deanonymization.

## Disclosure and terms

Because reports are public, keep the first issue to the affected code and the impact when a bug is easy to weaponize. Wait 90 days before publishing a working exploit, so forks have time to patch.

You are credited only with your explicit permission, by name and link or anonymously. The project's stated policy is not to pursue legal action over good-faith research conducted under this policy; that is a statement of intent, not a legal agreement, and it cannot bind forks or future maintainers. There is no bounty, no SLA and no investment advice. The code is MIT-licensed and provided as-is (see README section 11).

## Scope

In scope:

- Consensus-relevant patches: `patches/0001-0005`, `0007-0008`, `0010`, `0013` and `0016` (chain parameters, LWMA difficulty, RandomX proof of work, emission, re-org barrier and its restart-bypass fix, PER reservoir, fail-closed ticket replay, PER payout sigop bound and pool-drain order).
- Other node patches: `patches/0006`, `0009`, `0011-0012`, `0014-0015`, `0017-0020` (verification cost, data directory, network hardening, timestamp rules, CVE backport, Shunko transport, ticket-mining re-anchor, relay rate limit, CMake fix, comment cleanup, PER fuzz targets, Shunko target hygiene, clock warning, header hashing order, Shunko and RPC corrections, PER ticket caches, relay replay refusal, template throttle, extended-key version bytes, ticket-script fuzz target, Shunko configured-target exclusion, runtime-addnode exclusion while disconnected).
- `SHUNKO_PROTOCOL.md`, `explorer/`, `scripts/keygen.py`, `scripts/sendtoshunko.sh`, `scripts/reproduce_genesis.py`, `deploy/`, `config/cachecoin.conf` and `tests/*_regtest.py`.

Out of scope:

- Bitcoin Core, RandomX, Tor, and OS or toolchain issues. Report those upstream.
- `doc/research/hardware-notes.md` (speculative research, no executable code) and `assets/`.
- Social engineering, physical access, third-party wallets and exchanges, and clearnet use without a proxy.
- Cross-chain bridges, wrapped assets and peg or validator layers. CacheCoin has no custodial service and cannot verify another chain's state: there is no light client for another chain, RandomX cannot be checked in Bitcoin Script or the EVM, and there is no slashing or token layer, so a peg would be custodial by construction. Anything of that kind is a third-party project, not part of this codebase. Peer-to-peer atomic swaps are technically possible because CCCN inherits Bitcoin Script, but any swap tooling is third-party: the repository tests the hashlock/CLTV/CSV templates without signatures (`tests/swap_scripts_regtest.py`), not signature validation or any swap client.

## Known accepted risks

These are known and accepted. Please don't report them as vulnerabilities.

- The re-org barrier can hold the network split at roughly 50/50 hash. It heals on its own once one branch is 36 blocks past the fork, or immediately with a manual `invalidateblock` (README §1.2, and "If the network splits" in `deploy/README.md`). Two nodes can briefly disagree about whether a deep re-org is allowed, because the refusal is measured against each node's own chain; they cannot disagree about when the split ends.
- Unconnecting or below-threshold headers whose proof of work is invalid are dropped without a discouragement. Since patch 0017 the RandomX cost is only paid for headers that could actually be used, so the node does not learn the PoW was invalid; upstream hashes first and bans. The peer can still be banned for other objective misbehavior, and the exchange costs at most one `getheaders` reply per window.
- `getblocktemplate` refuses during initial block download. Before block 1, and after any restart whose tip is older than `-maxtipage` (24 hours by default), it throws `RPC_CLIENT_IN_INITIAL_DOWNLOAD`; `generatetoaddress` and `generateblock` do not. Mine one block locally or start with `-maxtipage=<seconds>` (`doc/incident_runbook.md` section 10, `doc/mining.md`). A miner set that only uses `getblocktemplate` cannot restart a stalled chain on its own.
- Shunko's automatic target selection does not resolve hostnames. A `-connect`/`-addnode`/`-seednode` hostname is excluded only when it resolves without DNS; use an IP address or `.onion` in the home config (`SHUNKO_PROTOCOL.md`). Privacy only; naming a target explicitly bypasses the exclusion by design.
- Shunko's automatic targets come from addrman, which any peer can add addresses to. A peer that supplied an address can be selected as the hand-over target and thereby recognize the transaction as coming from this node. This is the deferred addrman-steering item; name targets explicitly when that matters (`SHUNKO_PROTOCOL.md` section 4).
- A node whose own onion is not registered with the node (`-externalip` or Tor control) could select its own onion if that address is in its addrman. The shipped home sender has no onion (`listen=0`, `listenonion=0`), so this is a latent case for custom deployments.
- Shunko hides only the network origin, never amounts, addresses or coin flows. It needs a proxy plus a Tor hidden-service target, `walletbroadcast=0` and a fresh address for every payment (`onlynet=onion` is the shipped deployment setting).
- PER is unaudited fee-sharing logic. The reservoir only pays out fees that were actually collected.
- Full blocks add about 2.9 GB per day, and every node stays archival because `-prune` is refused.
- The money cap has 0.136656 CCCN of headroom.
- Each ticket costs about 20 ms of RandomX to verify, and there is no global cross-peer cap on ticket hashing.
- A ticket embedded in a block that is later re-orged out is not automatically returned to the local relay pool; it has to be re-relayed or re-mined before it can be embedded again. Consensus accounting is unaffected.
- The reservoir pool cannot overflow: coins are conserved, so `pool` is bounded by the issued supply (`pool + UTXO = issued - burned`), far below int64, and `rate * tickets <= pool` by construction. The economics of ticket mining remain unaudited.
- A payout script that passes the gate can still be unspendable in practice: opcodes like OP_RESERVED or OP_VER are valid enough to pass `HasValidOps` but always fail execution. Such a payout burns the ticket's rate into an unspendable coinbase output. No consensus impact and no chain stall; use a normal address script.
- The `generateblock` RPC fails with `bad-cb-per-state` when one of its explicit transactions pays a fee: it inserts the transactions after the template is built and does not regenerate the PER commitment, so only zero-fee transactions work. Not a vulnerability and not the mining path; use `getblocktemplate`/`submitblock`, `generatetoaddress`, or `sendrawtransaction` instead. The normal mining path is tested by every suite that mines.

## No financial promises

No bounty, no SLA, no investment advice. See README section 11, "License and disclaimer" (MIT, as-is).