# Economics: emission and the PER reservoir

The numbers here are consensus constants. `scripts/check_supply.py --check`
asserts all of them without a node; `tests/emission_check.py` checks the node's
own `GetBlockSubsidy` against an independent schedule and the whole mainnet
total against `MAX_MONEY`.

## Emission

| Item | Value |
|---|---|
| Genesis | 0 CCCN (unspendable `OP_RETURN`) |
| Blocks 1–720 (12 h warm-up) | 5 CCCN each |
| Block 721 onward | 10 CCCN; halving `n` applies from block `n * 1,051,200 + 1` (first at 1,051,201), about every 2 years |
| First zero-subsidy block | 31,536,001 (30 halvings; `10 CCCN >> 30 = 0`) |
| Total emission | 21,020,399.86334400 CCCN |
| `MAX_MONEY` | 21,020,400 CCCN |
| Headroom | 0.136656 CCCN (13,665,600 sat) |
| Premine | none; coins exist only as block subsidies |

The reward never increases and never goes negative. The cap is untouched by
fees because fees are not minted: they already exist as spendable coins.

## Fees and the split

- The miner of a block claims the subsidy plus `fees - fees/2`.
- The other half, `fees/2` (integer floor), goes into the current epoch's
  reservoir.
- An odd 1 sat of total fees gives the miner the rounded-up half and the
  reservoir the rounded-down half; that sat is paid to the miner, not lost.

## PER (Protracted Entropy Reservoir)

- **Epoch**: 40,320 blocks, 28 days at a 60-second target.
- **Ticket**: a RandomX proof of work over `(anchor block, payout script,
  nonce)` at 1/16 of the block target. The anchor must be one of the last 10
  blocks; a block embeds at most 64 tickets; the search re-anchors to the
  current tip every 1024 nonces. A ticket is stored in full in the coinbase, so
  every node verifies it and it counts once.
- **Close**: at the first block of a new epoch, `rate = pool / tickets`
  (0 if no tickets), the whole epoch is debited `rate * tickets`, the remainder
  carries over, and the ticket count resets.
- **Payout**: each ticket is paid `rate` to its own payout script in the
  coinbase of the block exactly one epoch after the block that embedded it, so
  payouts spread across the whole redemption epoch. Reservoir payouts are
  coinbase outputs and mature after 100 blocks.
- **Payout script limits**: a payout script must be spendable, at most 100
  bytes, valid, and have at most one legacy sigop. It becomes a mandatory
  coinbase output one epoch later, and coinbase outputs count toward the block
  sigop limit; a sigop-heavy script would make its payout block impossible to
  mine. `patches/0016` enforces this at embedding time. A bare multisig payout
  script is refused by this bound; use a P2SH or P2WSH address instead.
- **Invariant**: the committed pool always equals collected `fees/2` minus what
  epoch closes have debited. No payout is covered by anything but collected
  fees. `tests/per_invariants.py` re-derives this from public data; the explorer
  computes it with a second implementation; `scripts/watch_invariants.py`
  checks it on a live node.
- **Dust**: the rate has no floor. Sparse fees can make a payout below 1000 sat,
  which costs more to spend than it is worth. These outputs are never pruned.

## What a ticket is worth

On a network at steady-state difficulty, a miner with hash-rate share `s` finds
a ticket in about `3.75 / s` seconds on average (1% ≈ a few minutes; 0.01% ≈ ten
hours). The payout is `pool / tickets`, where `tickets` is how many tickets the
epoch actually embedded, so more ticket miners means a smaller share. There is
the payout depends on the fees collected, which can be zero for long stretches.
A ticket is a bearer claim on the payout script it names: if you lose the key,
the payout cannot be recovered, and there is no revocation and no fallback to
the reservoir.

## What this is not

- Not an investment. No premine, no sale, no staking, no yield promise.
- Not audited economics: PER has had no external monetary audit. The
  bookkeeping is consensus-verified, the game theory is not.
- Not a way to out-earn block mining. Tickets spread thin fee income across
  small CPU miners; a block subsidy is still the main reward.
