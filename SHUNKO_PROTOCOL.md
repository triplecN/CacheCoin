# Shunko protocol (瞬鬨)

Shunko hides which node first handed a transaction to the network. It does not hide what was sent. The ledger stays an ordinary, fully auditable UTXO chain, so supply audits and chain analysis work the same way they do on Bitcoin.

Status: implemented in the node as version 1, transport layer only. It changes no consensus rule. Blocks and transactions are byte-for-byte ordinary, and nodes without Shunko relay them normally.

---

## 1. What problem it solves

A normal Bitcoin-style node announces its own new transaction to all of its long-lived peers. Someone who runs many listening nodes can watch which node announced a transaction first, conclude that it came from there, and work back to the sender's IP address and location.

Shunko breaks that link in three layers:

| Layer | What it does |
| :--- | :--- |
| Tor only | Nodes connect only through Tor onion services (`deploy/`), so no peer sees your IP address. |
| One-shot hand-over (`shunkobroadcast`) | Your node does not announce the transaction over its long-lived connections (this needs `walletbroadcast=0` plus Tor). It hands the transaction to other nodes over short-lived connections instead, each through its own new Tor circuit, and those nodes relay it as if it were theirs. |
| not part of Shunko | BIP324 v2 transport is on by default upstream, so ordinary peer-to-peer traffic between nodes that found each other is encrypted. That is Bitcoin Core's doing, not this protocol's, and it does **not** apply to the hand-over: `shunkobroadcast` speaks P2P v1 inside Tor. Tor is what provides the confidentiality here, not v2 transport. |

## 2. How the one-shot hand-over works

```
 your wallet ── builds and signs, does NOT broadcast (send ... add_to_wallet=false)
      │
      ▼
 shunkobroadcast
   1. checks the transaction against the mempool rules (it is NOT added to your mempool)
   2. picks 2 nodes (random known addresses, or ones you name)
   3. for each: new SOCKS5 session to Tor with random credentials -> Tor builds a fresh circuit (with a generic SOCKS proxy the streams may share one; Tor with stream isolation is what gives a fresh circuit)
      -> minimal version/verack (no services, no addresses, no clock, common user agent)
      -> tx -> ping/pong (proof the peer read it, NOT proof its mempool accepted it) -> disconnect
      │
      ▼
 those nodes relay it to the whole network as an ordinary transaction
      │
      ▼
 a miner includes it; your wallet sees it in the next block
```

Your node's long-lived connections never carry the transaction first, so someone watching them doesn't see your node as the origin. The receiving nodes see a Tor client with no visible IP that disconnects right away. Shunko claims no anonymity against a global observer. With `walletbroadcast=0` (set in `deploy/home/cachecoin.conf`), the wallet never rebroadcasts the transaction either.

When you can, keep mining and spending in separate wallets. A wallet that both finds blocks and pays links your income to your payments.

> `delivered: 1` means the hand-over connection completed. It does not mean any mempool accepted the transaction: a peer can drop it silently under its own policy (Bitcoin Core sends no reject messages). If it never confirms, or the call failed, do not build a new payment for the same debt: the transaction may already be on a target. Retry the same raw transaction with `shunkobroadcast <same hex>`, or check the targets' mempools first.

## 3. How to use it

```bash
bash scripts/sendtoshunko.sh <cccn1-address> <amount> [wallet-name]
```

Or step by step:

```bash
cachecoin-cli -named send outputs='{"cccn1q...": 1.5}' add_to_wallet=false lock_unspents=true
cachecoin-cli shunkobroadcast <hex>                   # 2 random nodes
cachecoin-cli shunkobroadcast <hex> 1 '["xxxx.onion:29333"]'   # or chosen nodes
# 4th optional arg: maxfeerate in CCCN/kvB (default 0.1)
```

`shunkobroadcast` refuses any target that is not a hidden service, with or without a proxy, on every chain: the target must be an onion address and have a proxy configured, so it can't leak your IP by accident. There is no I2P transport path in the node, so an I2P address is refused rather than half-supported. The one exception is loopback on regtest, which has no onion services to hand over to. It also refuses unless `walletbroadcast=0` is set.

## 4. What Shunko does not protect

- **The ledger is public.** Amounts, addresses and the flow of coins between addresses are visible to everyone, attackers as well as forensic analysts. Shunko hides the link to your network identity, not the payment itself.
- **Address reuse links your payments.** Use a new receiving address for every payment, and don't carelessly merge coins from different sources.
- **Tor has limits.** An adversary who watches both ends of a Tor circuit, or controls most of the nodes you hand transactions to, can still correlate timing. Shunko makes that much harder, not impossible.
- **Your own machine.** A compromised computer, wallet file or exchange account reveals everything, whatever the transport.
- **Timing is coarse but visible.** Blocks come about every 60 seconds, so an observer sees which block your payment landed in. Don't send at a predictable second, and don't count on being unlinkable within a minute.
- **Heights are blurred, not hidden.** The hand-over metadata doesn't pin your exact tip height, but the transaction itself confirms on-chain within a block or two either way. The wallet also sets the transaction's `nLockTime` to the current height (anti-fee-sniping), so the transaction reveals roughly your tip height even though the hand-over's version message reports `start_height=0`.
- **Don't hand transactions to peers you are connected to.** `shunkobroadcast` picks random known addresses (or ones you name) and excludes peers this node is currently connected to, so the receivers are not the peers already watching your long-lived traffic. On the automatic path it also excludes nodes you configured yourself (`-connect`, `-addnode`, `-seednode`, and the `addnode` RPC), whether or not they are currently connected: your home VPS stays your home VPS, so a hand-over to it would link the one-shot connection to your node. Naming one of those peers explicitly as a target defeats this on purpose; the automatic path never picks those addresses (matching is by address, not by node identity, so a configured node reachable under a second address is not covered). One limit: the automatic path matches names without a DNS lookup, so a `-connect`/`-seednode` given as a hostname is excluded only when it resolves without DNS. Use an IP address or an onion address in the home config to keep the exclusion exact. A node added at runtime with the `addnode` RPC is excluded while it is down too (patch 0020). An inbound onion peer cannot be matched by address, so it is not excluded from the connected set; a listening sender should name targets it trusts. If every known address is already connected or configured (or addrman is empty), the call refuses and you must name other targets. Auto-selected targets also rotate: recently used ones are skipped while fresh ones exist, so a single receiver does not see every hand-over. The rotation list is in memory only (a restart forgets it), holds the last 16 targets, and is a no-op when the reachable set is that small or smaller.
- **Automatic targets come from addrman.** Any peer can add addresses to it. A peer that supplied the address selected for a hand-over can recognize the transaction as coming from this node, because the hand-over arrives at the address it planted. The configured-node exclusion does not bind an address to the peer that supplied it, so it does not close this. Name targets explicitly if your threat model includes the peers you connect to.
- **Your own onion is only excluded when the node knows it.** The self-check uses the node's registered local addresses (`-externalip`, Tor control `ADD_ONION`, or an interface address). A hidden service configured only in torrc, with no `-externalip`, is not registered, so if that onion ends up in addrman (gossip or an old `peers.dat`) the automatic path could hand the transaction to your own node. The shipped home template now listens and publishes its own onion through Tor control (`listen=1`, `listenonion=1`), so its address is registered; a sender that gets an onion some other way must register it with `-externalip` or name targets.
- **`walletbroadcast=0` is required.** Without it (see `deploy/home/cachecoin.conf`), your own wallet rebroadcasts the transaction over your long-lived connections and the hand-over buys you nothing. Check the setting before you fund the wallet.

## 5. Design choices and prior art

Shunko version 1 has no secret "miner mempool" and no special miner role, on purpose. That design would make miners targets, route every early transaction through the few first miners, hide pending payments from merchants, slow block propagation, and add a new P2P attack surface. The one-shot hand-over hides the origin from anyone watching for the first announcer, and ordinary public relay takes over after that.

The ideas come from public research: Dandelion and Dandelion++ (hiding the origin of a transaction before it spreads) and the "private broadcast" work in Bitcoin Core (sending your own transactions over short-lived Tor connections). Shunko is CacheCoin's implementation. The node doesn't use it by default, but the home deployment template is set up for it: it sets `walletbroadcast=0`, so the wallet never announces anything on its own and you send with `scripts/sendtoshunko.sh`.

Dandelion and Dandelion++ were the inspiration, but they relay a transaction node to node along a random path (the stem phase) before full diffusion (the fluff phase). Shunko v1 skips the stem and hands the transaction directly to 2 nodes. Your node opens two one-shot Tor connections, hands each target the transaction once, and disconnects, and ordinary relay takes over from there. That means fewer hops, no special stem role and a smaller attack surface. The cost is that there is no stem to hide the sender among.

Possible later versions (transport only, no consensus change):

- a Dandelion++-style stem phase among ordinary nodes before the transaction spreads;
- Manually configured connections (`connect=`/`addnode`) follow whatever upstream does about v2 transport; this is upstream's setting, not a CacheCoin decision. Over Tor the circuit is encrypted end to end regardless.

---
*MIT License, like the rest of CacheCoin.*