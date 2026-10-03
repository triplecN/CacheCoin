# Shunko protocol specification (version 1)

**Scope:** the transport layer of CacheCoin nodes. There is no consensus change: blocks and transactions are byte-for-byte ordinary, and nodes without Shunko relay them normally.

## 1. Goal

A normal Bitcoin-style node announces its own new transaction to all of its long-lived peers. An observer running many listening nodes can see which node announced a transaction first, conclude that it came from there, and work back to the sender's IP address and location.

Shunko's goal is to break that link while keeping the ledger public:

- **Unlinkable transport:** under the threat model in §3, an observer watching for the first announcer should not be able to tell which node or IP a transaction came from. A receiver that supplied the chosen target address is outside this claim, because automatic targets come from addrman. Global passive adversaries and Tor's own limits are explicitly out of scope.
- **Public ledger:** amounts, addresses and coin flows stay visible and auditable, so supply checks and chain analysis work as they do on Bitcoin.

## 2. Mechanism

| Layer | What it does |
| :--- | :--- |
| Tor-only network | Nodes connect only through Tor onion services. No peer sees an IP address. |
| One-shot hand-over | The sending node never announces its own transaction. It checks the transaction locally, without adding it to its own mempool, and hands it to a few other nodes (2 by default), each over a short-lived connection through its own new Tor circuit. Those nodes relay it as ordinary traffic. |
| Minimal handshake | The one-shot connection sends no services, no addresses and no clock, uses the common user agent, and always reports start_height 0, so it reveals as little as possible about the sender. Before disconnecting, a ping/pong confirms the peer read the transaction. It does not confirm that the peer's mempool accepted it. |
| No wallet broadcast | The home configuration sets `walletbroadcast=0`, so the wallet never announces or rebroadcasts its own transactions. |
| BIP324 | Encrypted v2 transport is on by default between peers that support it. |
| Safety guard | Outside regtest, the node refuses to hand over a transaction unless the target is a Tor hidden service and a proxy is configured, so it cannot reveal the sender's IP address by accident. Loopback targets are allowed on regtest only. |

Flow:

```
wallet: build and sign, do not broadcast
  -> shunkobroadcast: check, pick 2 nodes, one fresh Tor circuit each, send, disconnect
  -> those nodes relay it to the network as ordinary traffic
  -> a miner includes it; the sender's wallet sees it in the next block
```

## 3. Threat model

| Observer | What Shunko changes |
| :--- | :--- |
| Spy nodes watching who announces a transaction first | The sender's node never announces it. The first announcers are unrelated nodes. |
| Receiving nodes | They see a Tor client with no visible IP that disconnects right away. No anonymity against global observers is claimed. |
| Internet provider | Sees only Tor traffic. |
| Chain analysts, auditors, forensics | Nothing changes. The ledger is fully public. |

## 4. What Shunko does not protect

- **The ledger is public.** Anyone, attackers included, can follow coins between addresses. Shunko hides the network origin, not the payment.
- **Address reuse links payments.** Use a new receiving address for every payment.
- **Tor has limits.** An adversary who watches both ends of a circuit, or controls most of the nodes a transaction is handed to, can still correlate timing. Shunko makes this much harder, not impossible.
- **The local machine.** A compromised computer, wallet file or exchange account reveals everything, whatever the transport.
- **Before a block.** Once handed over, the transaction spreads like any other. Version 1 does not keep it out of public mempools.
- **Timing is coarse but visible.** Blocks land about every 60 seconds, so an observer sees which block a payment confirmed in. Don't send at a predictable second.
- **Don't hand transactions to peers you are connected to.** Name addresses of nodes you are not connected to. The automatic path excludes every connected peer and every node configured with `-connect`, `-addnode`, `-seednode` or the `addnode` RPC (patch 0019), refuses when no other known address exists (there is no fallback to your own peers), and rotates auto-selected targets (the last 16, in memory) so one receiver does not see every hand-over.
- **`walletbroadcast=0` is required.** Without it your own wallet rebroadcasts over your long-lived connections, and the hand-over buys you nothing.

The full limits, prior art and usage are in [`SHUNKO_PROTOCOL.md`](../SHUNKO_PROTOCOL.md) at the repo root. That file is the user-facing guide, not this blueprint folder.

## 5. Design decisions

Version 1 has no private "miner mempool" and no special miner role, on purpose. That design would make miners targets, route every early transaction through the few first miners (one central point for censorship and surveillance), hide pending payments from merchants, slow block propagation, and add new peer-to-peer messages to attack. The one-shot hand-over already hides the origin from anyone watching for the first announcer, and ordinary public relay takes over after that.

## 6. Prior art

- Dandelion (2017) and Dandelion++ (2018), which hide the origin of a transaction before it spreads.
- The private broadcast work in Bitcoin Core, which sends your own transactions over short-lived Tor connections.
- Private transaction submission to miners on other networks, for example Flashbots Protect.

Shunko combines these ideas for CacheCoin. The node doesn't use it by default, so ordinary sends still announce normally. Private sending needs `scripts/sendtoshunko.sh` (or `shunkobroadcast`), plus `walletbroadcast=0` and Tor. The home deployment template sets up both.

## 7. Possible later versions

Transport only, no consensus change:

- a Dandelion++-style stem phase among ordinary nodes before a transaction spreads;
- optional private submission to miners, once there are many independent miners;
- BIP324 for manually configured connections.