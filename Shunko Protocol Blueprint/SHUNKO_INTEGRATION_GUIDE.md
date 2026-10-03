# Shunko protocol: integration guide

Shunko version 1 is implemented across patches `0006`, `0010`, `0015`, `0016`, `0017`, `0019` and `0020`. It only touches the network and RPC layers.

## 1. Code

| File | Change |
| :--- | :--- |
| `src/shunko.h`, `src/shunko.cpp` | One-shot delivery. Connects through the configured proxy with random SOCKS5 credentials (so Tor builds a new circuit), does a minimal version/verack, sends `tx`, does a ping/pong and disconnects. |
| `src/rpc/mempool.cpp` | Adds the RPC `shunkobroadcast <hex> [peers] [targets] [maxfeerate]`. It checks the transaction against the mempool rules without adding it, then picks targets: random known addresses or the ones given, excluding every peer the node is currently connected to and every configured node (`-connect`, `-addnode`, `-seednode`, `addnode` RPC; patch 0019), and rotating out targets used in the last calls (`patches/0015`). Outside regtest it refuses targets that don't go through the proxy, and refuses unless `walletbroadcast=0`. Then it delivers and reports each attempt. |
| `src/rpc/client.cpp` | Argument types for `cachecoin-cli`. |
| `src/CMakeLists.txt` | Builds `shunko.cpp` into `bitcoin_node`. |
| (upstream) | BIP324 v2 transport is on by default since Bitcoin Core v27; no CacheCoin change is needed for it. |

Consensus code (validation, the block and transaction format, proof of work) is unchanged.

## 2. Configuration

Home node (`deploy/home/cachecoin.conf`):

```ini
proxy=127.0.0.1:9050
onlynet=onion
walletbroadcast=0   # the wallet never announces its own transactions; send through Shunko
```

## 3. Sending

```bash
bash scripts/sendtoshunko.sh <cccn1-address> <amount> [wallet-name]
```

Step by step:

```bash
cachecoin-cli -named send outputs='{"cccn1q...": 1.5}' add_to_wallet=false lock_unspents=true
cachecoin-cli shunkobroadcast <hex>
cachecoin-cli shunkobroadcast <hex> 1 '["xxxx.onion:29333"]'   # to a chosen node
```

The payment shows up in the sender's wallet once it is mined. If sending fails, the coins stay locked until the node restarts, or until you run `cachecoin-cli lockunspent true`.

## 4. Tests

`tests/shunko_regtest.py` checks that:

- the sender never has the transaction in its own mempool;
- the receiving node relays it onward;
- the one-shot connection is closed afterwards;
- the payment confirms and the receiver gets the exact amount;
- invalid transactions and unreachable targets are refused without sending anything.

`tests/mainnet_smoke.py` checks that mainnet refuses to send without Tor.