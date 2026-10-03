<p align="center">
  <img src="assets/logo.svg" width="160" alt="CacheCoin (CCCN) Logo">
</p>

<h1 align="center">CacheCoin (CCCN) Core</h1>

<p align="center">
  <strong>A CPU-mined proof-of-work coin with no central operator</strong>
</p>

> **Three things to know first.**
> 1. CacheCoin is CPU-friendly, not perfectly fair. A miner that keeps the full 2 GiB RandomX dataset in RAM ("fast mode", as XMRig does) is several times faster per core than the built-in light-mode miner. The RandomX key (`CacheCoin CCCN Genesis Seed Key`) is fixed and never rotated, which also makes specialized hardware easier to build than with a rotating key. There is no premine, but mining an empty network early on is still cheap.
> 2. Open source under the MIT license. CacheCoin was started by triplecN and is carried forward by the people who run nodes, review the code and propose changes; each of those is open to anyone through the public repository.
> 3. The code and the chain are separate things. Continuing the project means working on the chain these rules define. Changing anything in `patches/` changes block validation, and that produces a competing chain with a different block history. Coins on the branch that loses adoption stay on it and are not repriced onto the other. Bitcoin grew without changing its own rules, and that is the only kind of continuation that does not cost the people already holding the coin.

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/Consensus-RandomX%20CPU%20PoW-emerald.svg" alt="Consensus: CPU PoW">
  <img src="https://img.shields.io/badge/Premine-Zero%20(No%20Premine)-indigo.svg" alt="Premine: 0%">
  <img src="https://img.shields.io/badge/Block%20Time-60s-cyan.svg" alt="Target Time: 60s">
</p>

CacheCoin (CCCN) is a CPU-mined proof-of-work coin, released as-is under the MIT license. An ordinary computer can mine it, and small miners can earn a share of transaction fees without ever finding a block. Consensus uses RandomX for proof-of-work, LWMA-1 for difficulty, a fee reservoir shared with small miners (PER), and Tor for transaction relay (Shunko). There is no premine.

Specialized hardware pushes mining toward whoever can afford the most machines, and control of the money follows. CacheCoin starts from where Bitcoin began: a 4 GB computer can mine in light mode, in the background, while you browse or play, giving the miner only the capacity you choose. That is not perfectly fair -- a machine holding the full RandomX dataset in RAM is several times faster per core (section 1.6) -- but the door stays open to a small contribution without buying special hardware.

The rules are written down and the numbers can be reproduced, so you can check the claims yourself. The test suite has 15 suites in about 3,000 lines. It has about 250 named assertions, mines several thousand blocks under real RandomX, and includes about two dozen checks that are expected to fail. The re-org barrier is tested at its boundary: depth 5 is followed, depth 6 is refused, and a split heals at 36 blocks past the fork but not at 35. It also checks the emission schedule against `MAX_MONEY`, wallet accounting when a confirmed payment is re-orged out, the hashlock/CLTV/CSV script primitives an atomic swap would use, and a 1,000-block soak with the live invariant watcher. `SECURITY.md` lists what the suite does not cover: transaction and signature validation, power-loss mid-flush and chainstate corruption, and independent verification of the proof of work.

Started by [triplecN](https://github.com/triplecN). CacheCoin is open-source software, provided as is under the MIT license; nothing here is financial advice, an offer or a promise of return. Open research questions include fair-launch economics, CPU-only security, and private relay.

The node (`cachecoind`) is Bitcoin Core v31.1 with the CacheCoin changes in [`patches/`](patches/), and RandomX does the proof-of-work. If you know Bitcoin Core, most of this codebase will look familiar.

> **Running a node:** see [`deploy/README.md`](deploy/README.md) for a Tor-only VPS seed node and a home mining node that connects to it. On Windows, WSL2 Ubuntu is the supported path. Tor has to be running before the node connects to anything, and the port has to match: the shipped config asks for `127.0.0.1:9050`, which is the Tor Expert Bundle and system-daemon port, while Tor Browser listens on `9150`. New to all this? Start with [`START_HERE.md`](START_HERE.md).

---

## 1. Consensus

### 1.1 Proof-of-work: RandomX

- **Algorithm.** RandomX v1 ([tevador/RandomX](https://github.com/tevador/RandomX), pinned commit `7607fb2`) hashes the 80-byte block header with one fixed key: `CacheCoin CCCN Genesis Seed Key`.
- **Block id and PoW are different hashes of the same header.** The block id everyone quotes is SHA256d, as in Bitcoin. The proof of work is the RandomX digest. The two are not interchangeable.
- **Verification** runs in light mode, with one 256 MiB cache shared by all threads. It takes roughly 20 ms per header on a normal desktop with the JIT. Each header is hashed once, and anything already validated is never re-hashed.
- **JIT safety.** Generated code lives on W^X pages (`RANDOMX_FLAG_SECURE`). If the system forbids JIT memory (systemd `MemoryDenyWriteExecute=true` is the classic case), the node quietly falls back to the interpreter. The hashes are identical but about 6-7x slower. You can force this path with `CACHECOIN_RANDOMX_NOJIT=1`.
- **Self-test.** On every start the node re-hashes the genesis header and compares the result to the known digest. A mismatch means this build computes the wrong function, and the node refuses to run.
- **Mining.** RandomX rewards big caches and fast memory, which is what desktop CPUs have. The built-in miner (`generatetoaddress`) runs in light mode, one core per call. You can use a faster miner. Anyone keeping the full 2 GiB dataset in RAM (fast mode, like XMRig) gets several times more hashes per core.
- **Memory, in layers.** Four different numbers appear in this repository and they are not alternatives. A node always allocates the 256 MiB light-mode cache; each hash uses a 2 MiB scratchpad that stays in CPU cache; the ~2080 MiB dataset is only for external fast-mode miners and is never loaded by this node; and the machine-RAM figures (4 GB for a desktop that also browses, about 2 GB for a headless seed VPS) cover the whole node plus the operating system, not RandomX alone.
- **Fixed key.** Monero rotates its RandomX key every 2048 blocks. CacheCoin keeps one key forever. That is simpler to run and has no cache-rebuild pauses, but it makes life easier for anyone building specialized hardware later. Changing it would be a hard fork.
- **No fallback.** If RandomX can't initialize, the node stops. It never validates blocks with a different hash.

### 1.2 Deep re-organization limit

Two rules, measured from different places. A candidate that builds on the node's own tip is always followed: it disconnects nothing, so that is catch-up rather than a re-organization, and it is allowed however far behind the node is. Beyond catch-up, the switch is refused when it would undo more than 5 blocks of this node's own chain (`MAX_REORG_DEPTH = 5`). A refused branch is followed again once it reaches more than 35 blocks past the fork (`MAX_REORG_DEPTH + REORG_HEAL_LEAD_BLOCKS`, with `REORG_HEAL_LEAD_BLOCKS = 30`).

The 35-block threshold lets a split network heal by itself, for example after the seed node was offline. Once one side is far enough past the fork, every node follows it, and they all do so on the same block.

What the release is measured from matters: it is the candidate's distance past the fork, so every node lets the same branch through on the same block, and a split always resolves at the same height. What the refusal is measured from is necessarily local, because it is how much of this node's own chain the switch would undo. An earlier version measured both from the tip the node happened to start from, which made the release land at a different block on each node and left two nodes holding identical data able to adopt opposite chains over an ordinary six-block re-org.

Details:

- A refused branch is not marked invalid. The node keeps extending its own chain, re-evaluates the branch as it grows, logs the refusal and shows a warning in `getblockchaininfo`. The refusal survives restarts.
- If a re-org is allowed but the other branch turns out to contain an invalid block, the node returns to the chain it came from.
- The limit is not applied while a node is catching up at start-up (still in initial block download with a tip more than 24 hours old) or reindexing, so new nodes converge on the most-work chain. A node restarted after more than 24 hours offline, with `-reindex`, or with `-reindex-chainstate` (or after losing its chainstate) therefore forgets any branch it refused before, because the catch-up from genesis runs with the barrier off. A node that has already left initial block download keeps the barrier even if its tip later ages past 24 hours; the 36-block release still heals the split.
- To join a refused branch immediately, run `cachecoin-cli invalidateblock <hash of the first block after the fork on your own branch>`. `getchaintips` shows both branches. `reconsiderblock` with the same hash undoes it.

**What it protects against.** A miner with less than half of the hash rate cannot force a re-org deeper than 5 blocks, and the branch they build is held back until it is 36 blocks past the fork, so the re-org it buys them costs them 36 blocks. A majority can still reorganise the chain, but only by spending that lead, and the lead is counted in blocks rather than in work against whichever chain a node happens to be on, so every node agrees on when it happens. The cost is 36 blocks of the attacker's own mining, and the release threshold is counted in height rather than work, so it does not slide with difficulty. In wall-clock terms a lone attacker spends about 36 blocks of their own hash rate, roughly 71 blocks at a 51% share, and a minority attack stays cheap in blocks because nothing about the threshold scales with what the honest chain is doing. No rule can stop a majority that keeps its lead for good, because the same rule has to let a split network heal. An even 50/50 split with no majority heals as soon as one side gets 36 blocks past the fork: at an even split each side mines at half rate, so that is about 72 minutes on average, with a longer tail when the split is uneven. Base production monitoring on `getchaintips` and the `getblockchaininfo` warning, not on a fixed clock time.

**What this costs you.** A deep but legitimate re-organization, for example one caused by a miner being offline for a few hours, is not followed straight away. It is delayed until the competing branch is 36 blocks past the fork, so the network can be split for that long. The earlier rule released such a branch sooner if it had out-mined the local tip by a factor of two, but that factor was measured against a local tip, which is what made the limit non-deterministic. If you need to resolve a split immediately, use `invalidateblock` as described below.

**Confirmations.** The limit does not protect against re-orgs of 5 blocks or fewer. Wait for at least 10 confirmations, and many more (60+) for large amounts, especially while the network is young.

**If you resolved a split with `invalidateblock`,** transactions confirmed on the abandoned branch come back to the mempool on their own. On regtest, `gettransaction` drops to `confirmations: 0` and `getmempoolinfo` counts them again. Shunko payments behave the same way, because a Shunko transfer is delivered as an ordinary `tx` message and the receiving node puts it in its mempool. So don't re-send a payment just because its confirmations dropped to 0. Check the mempool first, or you will pay twice. A payment only needs re-sending if it did not come back, which happens when another branch spent one of its inputs or it is no longer above the fee floor. Check with `getchaintips` and `gettransaction <txid>`, and treat confirmations as final only while the `getblockchaininfo` re-org warning is clear.

### 1.3 Difficulty retargeting and timestamps

- The difficulty algorithm is LWMA-1 (Zawy) with a window of `N = 60` blocks, retargeting every block. As in the reference LWMA-1, each block's solve time is counted from the latest earlier timestamp in the window, at least 1 second and at most `6 × T`. A block timestamped before its predecessor never counts as a negative solve time. So the window counts no more time than its latest timestamp lies after the block before the window, plus one second per out-of-order block. A difficulty rise is limited to 10x per block. `tests/lwma_check.sh` checks this behavior on the node's own code.
- Blocks 1-60 are mined at the minimum difficulty (`powLimit`). After that, LWMA targets 60 seconds per block.
- Recovery from a hash-rate collapse is gradual, by design. The window is 60 blocks, a rise is capped at 10x per block and a fall at 6x per block. If the network loses 100x of its hash overnight, blocks stretch to about 100 minutes and then shorten over roughly 120 blocks, which is 3-4 days at the reduced rate. Don't reindex, restart repeatedly, or hand-edit the chain to speed this up. The window has to refill, and `-reindex` throws away the evidence of the outage.
- A block may be at most 10 minutes ahead of the node's clock (Bitcoin allows 2 hours), and peers cannot shift a node's clock. Keep the system clock synchronized with NTP.

### 1.4 Emission and fees

- Genesis pays 0 CCCN (an unspendable `OP_RETURN`).
- Blocks 1-720 (a 12-hour warm-up) pay 5 CCCN. From block 721 the reward is 10 CCCN, halving every 1,051,200 blocks (about 2 years). It reaches 0 at block 31,536,001.
- Total emission is 21,020,399.86334400 CCCN (`scripts/check_supply.py`), just below `MAX_MONEY` = 21,020,400 CCCN.
- **Fees are shared, not burned (PER).** The miner of a block claims the subsidy plus `fees - fees/2`. The other half of the fees goes into a 28-day reservoir that is shared out to CPU miners through entropy tickets (section 1.5). No coin is created beyond the fees themselves, so the cap is untouched. The split is integer: the miner takes the rounded-up half and the reservoir the rounded-down half. An odd total (1 sat of fees) gives the miner 1 sat and the reservoir 0; that sat is paid to the miner, not lost.
- All of Bitcoin's soft forks (BIP34/65/66, CSV, SegWit, Taproot) apply from the first mined block.
- The full schedule, the reservoir mechanics and the ticket math are in [`doc/economics.md`](doc/economics.md); `scripts/check_supply.py --check` asserts them without a node.

### 1.5 Entropy tickets (PER: Protracted Entropy Reservoir)

On a normal proof-of-work chain, a single laptop can mine for months and find nothing, because only the miner who finds a block earns anything. PER shares the fee reservoir (section 1.4) with ordinary CPU miners at the consensus layer, with no staking and no separate pool.

- An entropy ticket is a RandomX proof of work over `(anchor block, payout address, nonce)`. It is 16x easier than a full block. On a network that is at its steady-state difficulty, a miner holding a share `s` of the network hash rate finds one in about `3.75 / s` seconds on average (so a miner with 1% of the hash rate waits a few minutes, and one with 0.01% waits about ten hours). Mine them with `generateperticket <address>`. The search re-anchors to the current tip every 1024 nonces, so a ticket found after a long search is still anchored to a recent block; without that, anything found after the 10-block anchor window would be stale and thrown away. Run it in a loop for a chance at reservoir shares; the payout depends on the fees collected and can be zero. Tickets are relayed to other nodes with the `perticket` message.
- A block embeds up to 64 tickets whose anchor is one of the last 10 blocks on its own chain. Each ticket is stored in full in the coinbase, so every node verifies it, and a ticket counts once. A ticket's payout script must be spendable, at most 100 bytes, valid, and have at most one legacy sigop: one epoch later it becomes a mandatory coinbase output, and coinbase outputs count toward the block sigop limit, so a sigop-heavy script could make its payout block impossible to mine. `patches/0016` enforces this, and `tests/per_adversarial_regtest.py` submits such a ticket to check the rejection.
- A ticket embedded in a block that is later re-orged out is not automatically returned to the local relay pool; it has to be re-relayed or re-mined before it can be embedded again. The reservoir accounting is unaffected.
- Epochs are 40,320 blocks (28 days). Each block puts half of its fees into the current epoch's reservoir. When the epoch ends the reservoir is divided equally among all tickets seen in the epoch, which fixes a per-ticket rate. Each ticket is then paid that rate, to its own address, in the coinbase of the block exactly one epoch after the block that embedded it. Because that redemption point moves one block per height, tickets are paid out over the whole redemption epoch, a block's worth at a time.
- The reservoir is debited for the whole epoch when the epoch closes and paid out in installments after that, so at any moment the balance is the fees collected so far minus what has already been paid, plus the fees belonging to the epoch that has not closed yet. Tickets never get dropped and no money is created: every payout is covered by fees that were already collected.
- Payouts come only from collected fees. The coinbase may pay out subsidy + `fees - fees/2` + the reservoir shares owed that block, and no more. The 21,020,400 CCCN cap is untouched.
- `getperinfo` shows the current reservoir, ticket count and per-ticket rate. Reservoir payouts are coinbase outputs, so like any coinbase they mature after 100 blocks.
- Payouts can be dust. The rate is whatever the pool divides into, with no minimum. When fees are sparse it can fall below 1000 sat, and such an output costs more to spend than it is worth. These outputs are never pruned (`-prune` is refused) and stay in the UTXO set for good. Fixing this would mean changing consensus. Don't create dust outputs to pay for anything.
- Ticket mining has no fixed upside or ceiling: a ticket is 16x easier than a block, but the rate is `pool / tickets` with no cap against the subsidy, so if an epoch collects a lot of fees and few tickets exist, one block carrying the maximum 64 tickets can pay more than a block reward. Tickets spread thin fee income across small CPU miners. They are not a way to out-earn block mining. The reservoir is divided among the tickets that actually appear, so your share depends on how many others are mining.

This is transport and economics only. It does not change the proof-of-work or the money supply. `tests/per_regtest.py` checks the fee split, ticket relay and embedding, and the epoch payout.

### 1.6 Known limitations

- **CPU-friendly, not perfectly fair.** Fast mode (the full ~2 GiB RandomX dataset in RAM) is several times faster per core than the built-in light-mode miner. The fixed key makes dedicated hardware easier to specialize than with Monero's rotating key. Switching keys later would be a hard fork.
- **The re-org barrier can hold the network split at ~50/50 hash.** If two sides keep mining evenly, neither gets 36 blocks past the fork, and every node keeps its own branch until one side does. A manual `invalidateblock` override is then required (see "If the network splits" in `deploy/README.md`). At a true 50/50 split this resolves in about 72 minutes on average (each side mines 36 blocks at half rate), with a longer tail for uneven splits. Two nodes can still disagree about whether a deep re-org is allowed, because the refusal is measured against each node's own chain; what they cannot disagree about is when it ends, because the release is measured from the branch itself, so the split resolves at the same height everywhere. After an override, re-check the payments described in section 1.2.
- **PER economics are not externally reviewed.** The reservoir only pays out collected fees, so the cap is untouched, but ticket grinding, fee gaming and payout edge cases have not been reviewed by an external monetary audit. Treat future reservoir income as uncertain.
- **Shunko hides the network origin, not the payment.** The node refuses to hand over to anything that is not a hidden service: a clearnet address is rejected even when a proxy is configured, because a global `-proxy` applies to every network and a clearnet target would otherwise leave through a Tor exit. It also needs `walletbroadcast=0`, and a new address for every payment. The hand-over itself is P2P v1 inside Tor, so its confidentiality and the sender's anonymity rest entirely on Tor, not on anything the node adds. Amounts, address reuse and timing (~60 s block cadence) stay visible on the public ledger.
- **Chain growth.** If blocks stay full, the chain grows by up to ~2.9 GB per day (~1 TB per year). Plan disk accordingly. Every node stays archival because `-prune` is refused: PER payouts verify blocks up to a full epoch back.
- **The money cap margin is thin.** Maximum emission is 21,020,399.86334400 CCCN against `MAX_MONEY` = 21,020,400, which leaves 0.136656 CCCN of headroom (`scripts/check_supply.py`). Recompute the margin before touching the subsidy, warm-up or halving constants.
- **Ticket-heavy blocks cost more to verify.** A block can carry up to 64 tickets at ~20 ms of RandomX each. Honest sparse chains barely notice, but syncing a chain full of ticket-packed blocks is proportionally slower.
- **Ticket DoS.** Relayed tickets are hashed outside `cs_main`, with a per-peer token bucket that drops excess messages silently (an honest burst or Tor bunching is not punished with a disconnect; patch 0017 changed this from the earlier discouragement), but there is no global cross-peer hash cap. A relayed ticket does not have to be valid to cost the receiver a hash, so a well-funded Sybil attacker can burn receiver CPU, like on any permissionless relay.
- **A ticket is a bearer claim on a real payout address.** The node checks that the address is spendable and not oversized, but it can't know whether you still hold the key. A payout to a valid address you don't control cannot be recovered. It does not fall back to the reservoir, because the reservoir was already divided when the rate was set. Generate and back up the key offline (`scripts/keygen.py --save`, mode 0600), confirm the address with `validateaddress`, and mine one throwaway ticket before pointing a real mining loop at it. There is no revocation and no key recovery.

---

## 2. Network parameters (mainnet)

| Parameter | Value |
| :--- | :--- |
| Ticker / unit | `CCCN`, `1 CCCN = 100,000,000 Cache` |
| P2P port | `29333` |
| RPC port | `29332` (bound to localhost) |
| Tor onion service target port | `29334` |
| Message start (magic) | `0x43 0x43 0x43 0x4e` (ASCII `CCCN`) |
| Target block spacing | 60 seconds |
| Bech32 HRP | `cccn` (native SegWit addresses `cccn1q...`) |
| Base58 prefixes | P2PKH `28` (`C...`), P2SH `88`, WIF `156`. The legacy `C...` versions are shared with some old altcoins, so prefer `cccn1q...` to keep wallets from confusing chains. |
| HD (BIP32) versions | Deliberately not Bitcoin's `xpub/xprv`. CacheCoin uses distinct bytes so its extended keys can't be mistaken for Bitcoin's. |
| Max block weight | 2,000,000 weight units (BIP141): at most 2 MB per block, of which at most 500 kB is non-witness data. Bitcoin allows 4,000,000 per 10 minutes; CacheCoin allows about 5x Bitcoin's throughput per hour. |
| Chain growth | Follows actual use. If every block were full, up to about 2.9 GB per day (about 1 TB per year). |
| Coinbase maturity | 100 blocks |
| Max future block time | 10 minutes |
| Data directory | `~/.cachecoin` (config `cachecoin.conf`) |
| Seeds | No DNS seeds and no fixed seeds are compiled in. Community seed: `ag7rydtma6dt5fonz76sdbecrbugq3uln7cc6ddvg2c2jngio4lw6mid.onion:29333` (`addnode=` or `-seednode`, with `proxy=127.0.0.1:9050` and `onlynet=onion`). |

Addresses and keys from `scripts/keygen.py` work with the node (same HRP, prefixes and WIF version). The node's wallets are descriptor wallets. Import a key with `importdescriptors` (see the header of `keygen.py`).

CacheCoin has one public chain (mainnet). `-testnet`, `-testnet4` and `-signet` are disabled by design; use `-regtest` for local development.

### 2.1 Genesis block

- **Coinbase message:** `"CacheCoin (CCCN) - Pure CPU PoW. Open computational research under the MIT License."`
- **Coinbase scriptSig:** `<nBits 0x1e0ffff0> <4> <message>` (Bitcoin uses 486604799 as the first push)
- **Timestamp:** `1790360718` (2026-09-25 18:25:18 UTC)
- **nBits:** `0x1e0ffff0`
- **Nonce:** `1349294`
- **Block hash:** `1bc3387d50988b4b653389516f1d2b3672cffef48f124a3b8ff7b1ac3c1e3efa`
- **Merkle root:** `3c80c391de679ce4ddd9dbc11acb2020b81958a4ace7eb4209f232f4f5af5ed8`
- **RandomX PoW hash:** `00000efb2763af08d300a6899fa4297b4fc41f43c323e2275a238311fd3b35e4` (below the `0x1e0ffff0` target)

The coinbase and header are fully determined by `patches/0002`, with no secret preimage. `scripts/reproduce_genesis.py` rebuilds them byte for byte and checks the hashes. The RandomX digest is a known answer that every node self-tests at startup.

CacheCoin is unrelated to the 2014 scrypt coin "CACHeCoin (CACH)". The network (magic, ports, genesis) and ticker (`CCCN` vs `CACH`) are different. The shared `~/.cachecoin` / `cachecoin.conf` names are a coincidence, so back up before running both on one machine.

---

## 3. Sending with network-origin privacy: the Shunko protocol

Shunko hides which node first handed a transaction from its long-lived connections. The ledger stays public: amounts, addresses and coin flows are fully visible and auditable, so anyone can check the supply. The automatic path draws targets from addrman, so a peer that supplied the chosen address can recognize the hand-over; name targets explicitly if that matters to you (`SHUNKO_PROTOCOL.md` section 4).

- Nodes run over Tor only (see `deploy/`), so no peer sees your IP address.
- `shunkobroadcast` is designed not to announce your transaction from your long-lived connections. It requires `walletbroadcast=0` plus Tor. The transaction is handed to two other nodes over one-shot connections, each through its own new Tor circuit, and they relay it as ordinary traffic.
- BIP324 encrypted transport is on by default.

```bash
bash scripts/sendtoshunko.sh <cccn1-address> <amount> [wallet-name]
```

Use a new receiving address for every payment. Shunko hides the network origin, not the ledger. The full description, limits and prior art are in [SHUNKO_PROTOCOL.md](SHUNKO_PROTOCOL.md).

---

## 4. Hardware research notes

This is a design study: no NPU, photonic or quantum code exists in `patches/`, `scripts/` or `tests/`.

[doc/research/hardware-notes.md](doc/research/hardware-notes.md) collects speculative long-term notes on how CPU-friendly mining could evolve. It is not a roadmap and none of it is part of the consensus rules. The proof-of-work is RandomX, and changing it would take a hard fork that node operators choose to run.

---

## 5. Directory layout

```
Cachecoin/
├── patches/                  # CacheCoin changes to Bitcoin Core v31.1 (20 patches, applied in order)
│   ├── 0001-lwma-verification-cost-emission-datadir.patch
│   ├── 0002-chain-parameters-and-genesis.patch
│   ├── 0003-reorg-depth-barrier.patch
│   ├── 0004-randomx-proof-of-work-cmake.patch
│   ├── 0005-integration-fixes.patch
│   ├── 0006-network-hardening-timestamps-shunko.patch
│   ├── 0007-per-fee-reservoir.patch
│   ├── 0008-fix-barrier-bypass-on-restart.patch
│   ├── 0009-fix-help-text-and-ticket-pool-drain.patch
│   ├── 0010-deterministic-reorg-barrier-and-transport.patch
│   ├── 0011-ticket-reanchor-relay-rate-limit-cmake-off.patch
│   ├── 0012-clean-development-comments.patch
│   ├── 0013-fail-closed-ticket-replay.patch
│   ├── 0014-per-fuzz-targets.patch
│   ├── 0015-shunko-target-hygiene-clock-warning.patch
│   ├── 0016-per-payout-sigop-bound-and-pool-drain.patch
│   ├── 0017-hash-headers-last-shunko-and-rpc-fixes.patch
│   ├── 0018-per-caches-relay-refusal-gbt-throttle-xkey-bytes.patch
│   ├── 0019-shunko-skip-configured-targets.patch
│   └── 0020-shunko-addnode-runtime-exclusion.patch
├── scripts/
│   ├── build_linux.sh        # Build and install cachecoind / cachecoin-cli
│   ├── run_local_node.sh     # Start a local node with ~/.cachecoin
│   ├── sendtoshunko.sh       # Send a payment through the Shunko protocol
│   ├── keygen.py             # Offline key and address generator
│   ├── check_supply.py       # Emission schedule calculator and --check self-test
│   ├── ticket_loop.sh        # Loop generateperticket against a local node
│   ├── reproduce_genesis.py  # Rebuilds genesis byte for byte, checks hashes
│   ├── watch_invariants.py   # Long-run PER/supply invariant monitor (alarms on mismatch)
│   └── release_sign.sh       # SHA256SUMS (+ optional GPG signature) for releases
├── private/                  # NEVER committed: your addresses, test notes (gitignored)
├── .github/workflows/        # CI: Linux and ARM64 build+test, Windows .exe + SHA256SUMS
├── deploy/                   # VPS seed node (Tor) + home miner node
├── config/cachecoin.conf     # Generic node configuration template
├── doc/incident_runbook.md   # What to do when the chain splits, an alarm fires or data is damaged
├── doc/verification.md       # Verified patch fingerprint, binary hash and suite results
├── doc/exchange_integration.md # What a centralized exchange needs to integrate CCCN
├── doc/release.md            # Tag, CI draft release, offline signing, verification
├── doc/economics.md          # Emission schedule, PER reservoir mechanics, ticket math
├── doc/mining.md             # Mining practically: expectations, tools, hygiene
├── doc/wallet.md             # Create, back up, spend and restore a wallet
├── doc/research/hardware-notes.md # Speculative hardware research notes (not a roadmap)
├── explorer/                 # Block explorer (Python standard library + static HTML)
├── tests/
│   ├── functional_regtest.py # Multi-node regtest: sync, subsidy, fee split, re-org limit, time rules
│   ├── p2p_dos_regtest.py    # Raw P2P client: replayed headers/blocks are cheap, bad PoW is punished
│   ├── explorer_regtest.py   # Explorer: supply/balances match the node, re-orgs are followed
│   ├── shunko_regtest.py     # Shunko: one-shot hand-over, target selection, refusals
│   ├── per_regtest.py        # PER: fee split, ticket relay/embedding, 28-day epoch payout
│   ├── mainnet_smoke.py      # Mainnet parameters without mining anything
│   ├── durability_regtest.py # Crash, -reindex, lost index/chainstate, truncated-file, bit-flip recovery
│   ├── per_invariants.py     # Independent re-derivation of the PER accounting and supply
│   ├── per_adversarial_regtest.py # Hand-built blocks the PER rules must reject
│   ├── emission_check.py     # Node subsidies vs an independent schedule; mainnet cap and headroom
│   ├── wallet_reorg_regtest.py # Wallet accounting when a confirmed payment is re-orged out
│   ├── soak_regtest.py       # 1,000+ block soak with fees/tickets and the live invariant watcher
│   ├── swap_scripts_regtest.py # Hashlock/CLTV/CSV primitives, MTP timeouts and a funded-output re-org
│   ├── watcher_conformance_regtest.py # The live watcher and check_supply on valid edge cases
│   ├── run_fuzz.sh           # Build and run the PER fuzz targets (clang/libFuzzer)
│   └── lwma_check.sh/.cpp    # LWMA difficulty: 90% hash-rate drop/recovery and pulse mining
├── assets/                   # Logo
├── SHUNKO_PROTOCOL.md        # Private sending (transport layer)
├── START_HERE.md             # Plain-language newcomer guide
├── SECURITY.md               # How to report vulnerabilities
├── LAUNCH.md                # First blocks and the public seed node
├── LICENSE
└── README.md
```

---

## 6. Build (Ubuntu / Debian)

```bash
bash scripts/build_linux.sh
```

The script installs the build dependencies, fetches Bitcoin Core `v31.1` (checked against its commit hash) and RandomX at the pinned commit, applies `patches/*.patch`, builds a portable `cachecoind` and `cachecoin-cli` (no `-march=native`), and installs them to `/usr/local/bin`. It is safe to re-run.

On Windows, WSL2 Ubuntu is the supported path and the commands are the same. There is no native Windows build script, and nothing in this repository tests the `.exe` files that CI produces. See [`doc/build-windows.md`](doc/build-windows.md) to build them yourself.

Run the tests against the fresh build. They use throwaway data directories and never mine on mainnet:

```bash
B=~/cachecoin-build/cachecoin-v31.1
python3 tests/functional_regtest.py $B/build/bin/bitcoind
python3 tests/p2p_dos_regtest.py $B/build/bin/bitcoind
python3 tests/explorer_regtest.py $B/build/bin/bitcoind
python3 tests/shunko_regtest.py $B/build/bin/bitcoind
python3 tests/per_regtest.py $B/build/bin/bitcoind
python3 tests/mainnet_smoke.py $B/build/bin/bitcoind
python3 tests/durability_regtest.py $B/build/bin/bitcoind
python3 tests/per_invariants.py $B/build/bin/bitcoind
python3 tests/per_adversarial_regtest.py $B/build/bin/bitcoind
python3 tests/emission_check.py $B/build/bin/bitcoind $B
python3 tests/wallet_reorg_regtest.py $B/build/bin/bitcoind
python3 tests/soak_regtest.py $B/build/bin/bitcoind
python3 tests/swap_scripts_regtest.py $B/build/bin/bitcoind
python3 tests/watcher_conformance_regtest.py $B/build/bin/bitcoind
bash tests/lwma_check.sh $B
```

Run them one at a time. The harnesses each start nodes on the same default regtest
ports, so running them concurrently makes them collide.

The PER fuzz targets are built and run separately, because they need clang and a
separate build: `bash tests/run_fuzz.sh $B` (see `SECURITY.md` for what they do and
do not cover).

---

## 7. Running a node and mining

```bash
mkdir -p ~/.cachecoin
cp config/cachecoin.conf ~/.cachecoin/cachecoin.conf   # add addnode= lines for your peers
cachecoind -daemon
cachecoin-cli getblockchaininfo
```

On Windows these commands run inside WSL2, so your `~/.cachecoin` lives on the Linux side. The typical setup is two machines: a Tor-only VPS seed that stays online, and a home miner behind Tor that connects to it.

Two inherited Bitcoin Core defaults assume 10-minute blocks and are adjusted in the shipped config. First, the fee estimator's horizons are counted in blocks, so `estimatesmartfee 6` means about 6 minutes here, not about an hour. Second, the mempool holds about five times as many blocks per hour, so `config/cachecoin.conf` lowers `maxmempool` and `deploy/` lowers `dbcache` from the upstream defaults. Mempool expiry stays at the inherited 336 hours (14 days) on both chains: it is wall-clock, not block-based, so it does not need adjusting. If you write your own config instead of copying the shipped one, re-check those values and expect a slower initial sync. There is no `assumevalid` shortcut, so every block from genesis is fully validated.

Mine to your own address, never to an address a tool generated for you:

```bash
cachecoin-cli generatetoaddress 1 <your-cccn1-address>
```

For a production setup (Tor-only VPS seed node, home miner behind Tor, systemd service, mining loop with safety checks), follow [`deploy/README.md`](deploy/README.md). Practical guides: [`doc/mining.md`](doc/mining.md) and [`doc/wallet.md`](doc/wallet.md).

---

## 8. Block explorer

```bash
python3 explorer/app.py
```

Open `http://127.0.0.1:8080`. The explorer reads the node over RPC (cookie authentication from `~/.cachecoin/.cookie`) and keeps its own index in `explorer/explorer.db`, which is safe to delete and gets rebuilt. It follows re-orgs and tracks spent outputs for address balances. It listens on localhost only unless `EXPLORER_BIND` is set.

Don't expose it directly to the internet. It is a Python `http.server` with one thread per connection, a 32-connection cap and no rate limiting of its own, and it rejects any `Host` header that is not loopback. If it has to be public, put a reverse proxy in front of it and **make that proxy rewrite `Host` to `127.0.0.1`**, otherwise every request is answered `421`. On the proxy, cache `/api/info` for ~5 s and cap request rate and concurrency. `/api/tx` returns at most 20000 outputs per request and `/api/address` at most 1000; `/api/block` returns at most 2000 transactions and sets `transactions_truncated` when there were more. Address queries for large holders return a large JSON body, so add pagination at the proxy if that matters.

After a network split, delete `explorer/explorer.db`. The explorer refuses to walk back more than 512 blocks and would otherwise keep serving the abandoned branch.

---

## 9. JSON-RPC

CacheCoin keeps Bitcoin Core's RPC interface: same commands, same shapes, plus a few new ones for PER tickets and Shunko. If you have scripted against `bitcoin-cli` before, the same habits work here.

| RPC method | Description |
| :--- | :--- |
| `getblockchaininfo` | Chain height, best block, difficulty |
| `getblock <hash> <verbosity>` | Block header and transactions |
| `getblocktemplate '{"rules":["segwit"]}'` | Block template. Also reports `coinbasefee` (claimable), `reservoirfee` (to the PER reservoir) and the required `peroutputs`. |
| `getperinfo [blockhash]` | PER reservoir state after a block: epoch, pool, tickets, per-ticket rate |
| `generateperticket <address> [maxtries]` | Mine one PER entropy ticket to your address and relay it. Run it in a loop for a chance at reservoir shares; the payout depends on the fees collected and can be zero. |
| `submitblock <hex>` | Submit a solved block |
| `generatetoaddress <n> <address> [maxtries]` | Mine blocks with the built-in RandomX miner |
| `shunkobroadcast <hex> [peers] [targets] [maxfeerate]` | Send a signed transaction through the Shunko protocol (one-shot Tor hand-over, designed not to announce from your node; requires `walletbroadcast=0`) |

---

## 10. Maintenance

CacheCoin is maintained by whoever runs it. The consensus rules are fixed;
changes under `patches/` are a hard fork that node operators choose to run.
Development and vulnerability reports happen in public (`SECURITY.md`).

---

## 11. License and disclaimer

This software is released under the MIT License. It includes code from Bitcoin Core (MIT) and RandomX (BSD-3-Clause). CacheCoin is open-source software, released as-is under the MIT License. It makes no financial claims, investment promises or roadmap guarantees, and it comes with no custodial service. Cross-chain bridges, wrapped assets and peg or validator layers are not part of CacheCoin and are out of scope: the chain cannot verify another chain's state, and there is no custodian here. Any such project is third-party and independent, like any community fork. Nothing here is financial advice, an offer or a promise of return. Operators are responsible for complying with the tax, securities and AML laws that apply to them. Coins are created only by mining, and there is no premine.
