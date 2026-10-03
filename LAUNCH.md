# Launch record

CacheCoin (CCCN) is a Bitcoin Core v31.1 fork with RandomX CPU proof of work, LWMA difficulty, the PER fee reservoir and the Shunko relay. This file records the first blocks and the public seed so the start of the chain is transparent and checkable.

## First blocks

The chain began with the hardcoded genesis block and the first five blocks below, mined on mainnet. Every node carries the same genesis from `patches/0002` and self-tests its recorded RandomX digest; the hashes below are the ones this node produced and the seed node stored.

| Height | Block hash (SHA256d block id) |
|---|---|
| 0 (genesis) | `1bc3387d50988b4b653389516f1d2b3672cffef48f124a3b8ff7b1ac3c1e3efa` |
| 1 | `9d7be3837688864ed4e5428ec1289a3af498556ef27e0570cf53a2bd6e2dc2b4` |
| 2 | `d2a9b833deed48938c6027b1c7550e9f3c25292e0958d83e6a0f592cf23a8c2a` |
| 3 | `fa014d082b554ce4eeb5fef595082673b0a75d008d27b7c75022da8ff4e9e7f5` |
| 4 | `906c1606bbe0f8a6d21c842f524f271a7f674f40f533c1c4d7e980ba185627d1` |
| 5 | `e1ac7b5997d58d51af2d204675b7601e65cfea5650456ac18d1297399dbdcb8c` |

Check them on any synced node:

```
cachecoin-cli getblockhash 1     # and 2, 3, 4, 5
```

## Public seed

```
addnode=ag7rydtma6dt5fonz76sdbecrbugq3uln7cc6ddvg2c2jngio4lw6mid.onion:29333
```

Together with `proxy=127.0.0.1:9050` and `onlynet=onion`, this is how a new node reaches the network. The seed is a relay only; it does not mine. It is the same seed listed in `README.md` section 2; if the two ever disagree, the README is authoritative. `getconnectioncount` at 1 or more is the only in-repo check that the seed is reachable; the block hashes are the check that it served the right chain.

## How to join and verify

1. Build from source: `bash scripts/build_linux.sh` (Ubuntu/WSL2), or see `doc/build-windows.md`.
2. Set `proxy=127.0.0.1:9050`, `onlynet=onion` and the `addnode=` line above in `cachecoin.conf`.
3. Start `cachecoind`, check `cachecoin-cli getconnectioncount` is at least 1, then `getblockchaininfo`.
4. Compare each hash above (including the genesis row) with `getblockhash <height>`. `getblockhash` returns the SHA256d block id; the RandomX proof-of-work digest is a separate value (README section 1.1).
5. Without a running node, `python3 scripts/reproduce_genesis.py` rebuilds the genesis header and checks the hash, and `doc/verification.md` records the full verified state and the patch fingerprint.

## Notes

- No premine: coins exist only as block subsidies. The first blocks were mined under the published warm-up rules (5 CCCN, minimum difficulty for blocks 1-60).
- The consensus rules are fixed. A change under `patches/` is a hard fork that node operators choose to run.
- This is open-source software, provided as is under the MIT license; nothing here is financial advice, an offer or a promise of return.
