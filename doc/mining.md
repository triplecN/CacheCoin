# Mining

Practical guide for mining CCCN. Read `doc/economics.md` first for what mining
can and cannot pay; read `README.md` §1.6 for the known limitations. There is no
bundled pool software or stratum server in this repository.

## What the node can mine for you

The built-in miner uses RandomX in light mode (a 256 MiB cache, no 2 GiB
dataset). It is the easy path and it is what the tests exercise:

```bash
# a block to your own address (the address must be one you control)
cachecoin-cli generatetoaddress 1 <your-cccn1-address>

# one entropy ticket: 16x easier than a block, pays a share of the fee reservoir.
# Pass a bounded maxtries: the default is 1,000,000 tries, which can outlive the
# CLI timeout while the server keeps searching and holding an RPC thread.
cachecoin-cli -rpcclienttimeout=0 generateperticket <your-cccn1-address> 20000
```

`scripts/ticket_loop.sh` runs the ticket search in a loop with an address check
and safe error handling:

```bash
bash scripts/ticket_loop.sh <your-cccn1-address> 5          # every 5 s
bash scripts/ticket_loop.sh <your-cccn1-address> 0 --once   # one attempt (test)
CACHECOIN_CLI_ARGS="-regtest -datadir=/tmp/n -rpcport=39201" \
  bash scripts/ticket_loop.sh <address> 0 --once
```

Use `deploy/README.md` for the production setup (Tor-only VPS seed plus a home
miner, systemd service, mining loop with safety checks).

## Expectations

- **Block variance is huge.** At a 60-second target, a solo miner with 1% of the
  network hashes finds a block roughly every 100 minutes *on average*; with
  0.1% it is about 17 hours on average, and a day or two of silence is normal,
  not a fault. Check `getblocktemplate` / the node log before assuming a
  problem.
- **The subsidy is the main reward.** At launch the warm-up pays 5 CCCN and the
  normal subsidy is 10 CCCN; fees are likely to be zero or tiny for a long time.
- **Tickets are not a salary.** The per-ticket rate is `pool / tickets` for the
  epoch. If few fees were collected, the rate is small or zero. Tickets are a
  way to spread sparse fee income, not to out-earn block mining.
- **Light mode vs fast mode.** A miner with the full ~2 GiB RandomX dataset in
  RAM is several times faster per core than the built-in light-mode miner. This
  repository ships no fast-mode miner; building one is third-party work, and it
  must produce the same RandomX v1 hashes with the fixed consensus key.

## Mining with external software

The node exposes `getblocktemplate` (BIP22/BIP145) and `submitblock`, so
third-party tooling can build blocks; the coinbase must carry the PER
commitment and the embedded tickets exactly as consensus requires. The
mandatory outputs are in the template's `peroutputs` array, not only in
`coinbasevalue`: the commitment goes at vout 1, the ticket records follow it,
and any reservoir payouts for this block follow the tickets, in the order
given. There is no bundled stratum server and none is tested
here. Do not mine with a tool that cannot construct the coinbase commitment:
its blocks will be rejected with `bad-cb-per-state` (see
`tests/per_adversarial_regtest.py`).

**Bootstrap and stalled chains.** `getblocktemplate` refuses while the node
believes it is in initial block download. Before block 1 every node is (the
genesis timestamp is fixed), and a node restarted after a stall longer than 24
hours re-arms that state until it sees a fresh block; a node that stayed
running is not affected. Mine the first block -- and the first block after a
long stall -- locally with `generatetoaddress` (the `deploy/home/mine.sh`
path), or set `-maxtipage=<seconds>` (a hidden debug option) so a restarted
node leaves IBD at once. Once a fresh block exists, external tooling gets
templates normally. See `doc/incident_runbook.md` section 10.

## Address and key hygiene

- Mine to a `cccn1...` address you generated and backed up offline
  (`scripts/keygen.py --save`, mode 0600). Never mine to an address a tool
  printed as an example; `README.md` §1.6 explains the bearer-claim risk.
- A PER payout goes to the payout script embedded in the ticket. If you lose the
  key, the payout is gone. Mine one throwaway ticket before pointing a real loop
  at an address.
- Keep the mining wallet on your own machine. The seed node should run
  `disablewallet=1` and never mine (`doc/exchange_integration.md` §5 explains
  why `walletbroadcast=0` must not be set on a node that also sends).

## Monitoring a miner

- `cachecoin-cli getblockchaininfo` and `getmininginfo` for height and difficulty.
- `cachecoin-cli getperinfo` for the current reservoir, ticket count and rate.
- `scripts/watch_invariants.py` next to the node re-derives the PER accounting
  and the supply identity and exits 2 on a mismatch.
- Watch the clock: a block more than 10 minutes ahead of your node's clock is
  rejected (`time-too-new`), and a slow clock makes the node look stuck
  (`doc/incident_runbook.md` §5).
