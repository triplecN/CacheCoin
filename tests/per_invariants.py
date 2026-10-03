#!/usr/bin/env python3
"""
CacheCoin PER invariant test: an independent second implementation of the
reservoir accounting, checked against every block of a regtest chain.

The node (C++) and this file (Python) share no code. This file re-derives, from
the public block data alone, what every block's PER commitment and payouts must
be, and fails if the chain disagrees. It also checks the supply identity.

Invariants checked for every block h:
  1. committed pool/tickets/rate == the rules (close at a boundary, add fee/2,
     add this block's tickets)
  2. payouts == rate * (tickets embedded exactly one epoch earlier), same count,
     same order, same scripts, same amounts
  3. coinbase total == subsidy + fees - fees/2 + payouts
  4. pool == cumulative fee/2 - cumulative payouts (the reservoir never invents
     or loses a satoshi)
  5. ticket ids are strictly sorted, unique within the block, and not repeated
     inside the anchor window
  6. sum(all coinbase outputs) - sum(all fees) == gettxoutsetinfo total

Then it re-orgs the chain past an epoch boundary and repeats 1-6 on the new
active chain.

Standard library only; throw-away datadir under /tmp; never mainnet.

Usage: python3 tests/per_invariants.py [path/to/cachecoind] [extra_blocks]
"""

import hashlib
import os
import shutil
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import functional_regtest as ft  # noqa: E402

ft.BITCOIND = sys.argv[1] if len(sys.argv) > 1 else "cachecoind"
EXTRA_BLOCKS = int(sys.argv[2]) if len(sys.argv) > 2 else 0
ft.BASE = "/tmp/cachecoin-per-invariants"
check, wait_for = ft.check, ft.wait_for
COIN = ft.COIN
# Regtest chain parameters (src/kernel/chainparams.cpp): warm-up 720, halving 150.
WARM_UP, HALVING, BASE_REWARD = 720, 150, 10 * COIN


def dsha256(b):
    return hashlib.sha256(hashlib.sha256(b).digest()).digest()


def subsidy(height):
    if height <= 0:
        return 0
    if height <= WARM_UP:
        return 5 * COIN
    halvings = (height - 1) // HALVING
    if halvings >= 64:
        return 0
    return BASE_REWARD >> halvings


def compact_size(n):
    if n < 253:
        return bytes([n])
    if n <= 0xFFFF:
        return b"\xfd" + struct.pack("<H", n)
    return b"\xfe" + struct.pack("<I", n)


def parse_commitment(script_hex):
    data = bytes.fromhex(script_hex)
    if len(data) != 30 or data[0] != 0x6A or data[1] != 0x1C or data[2:6] != b"PER\x01":
        return None
    p = data[6:]
    return {
        "pool": int.from_bytes(p[0:8], "little", signed=True),
        "tickets": int.from_bytes(p[8:12], "little"),
        "rate": int.from_bytes(p[12:20], "little", signed=True),
        "block_tickets": int.from_bytes(p[20:22], "little"),
        "payouts": int.from_bytes(p[22:24], "little"),
    }


def parse_ticket(script_hex):
    data = bytes.fromhex(script_hex)
    if len(data) < 2 or data[0] != 0x6A:
        return None
    if data[1] <= 75:
        if len(data) < 2 + data[1]:
            return None
        body = data[2:2 + data[1]]
    elif data[1] == 0x4C:  # OP_PUSHDATA1
        if len(data) < 3 or len(data) < 3 + data[2]:
            return None
        body = data[3:3 + data[2]]
    elif data[1] == 0x4D:  # OP_PUSHDATA2: OpReturnData accepts it
        if len(data) < 4:
            return None
        n = int.from_bytes(data[2:4], "little")
        if len(data) < 4 + n:
            return None
        body = data[4:4 + n]
    else:
        return None
    if len(body) < 40 or body[:4] != b"PERT":
        return None
    anchor, payout, nonce = body[4:36], body[36:-4], body[-4:]
    tid = dsha256(anchor + compact_size(len(payout)) + payout + nonce)
    return {"id": tid, "payout": payout.hex(), "anchor": anchor}


def walk(node, label):
    """Re-derive every block's PER state and payouts; return supply totals."""
    epoch = node.rpc("getperinfo")["epoch_blocks"]
    tip = node.rpc("getblockcount")
    pool = tickets = rate = 0
    cum_fees_half = cum_payouts = cum_coinbase = cum_fees = cum_burns = 0
    block_tickets = {}          # height -> list of ticket dicts
    window = []                 # (height, [ids]) for the duplicate-window check
    debit_by_epoch = {}         # epoch index -> what its close debited
    paid_by_epoch = {}          # epoch index -> what its tickets were paid
    problems = []

    def bad(h, what):
        problems.append(f"{label} height {h}: {what}")

    for h in range(0, tip + 1):
        blk = node.rpc("getblock", node.rpc("getblockhash", h), 2)
        cb = blk["tx"][0]
        fees = sum(round(t["fee"] * COIN) for t in blk["tx"][1:])
        vout_values = [round(o["value"] * COIN) for o in cb["vout"]]
        cum_fees += fees
        # Value sent to an unspendable output is neither in the UTXO set nor a fee.
        for t in blk["tx"]:
            for o in t["vout"]:
                spk = o["scriptPubKey"]["hex"]
                if spk.startswith("6a") or len(spk) // 2 > 10000:
                    cum_burns += round(o["value"] * COIN)
        if h == 0:
            # Bitcoin Core never adds the genesis coinbase to the UTXO set, so it
            # is not part of the supply identity. Mainnet pays 0; regtest keeps
            # Bitcoin's 50 CCCN genesis output, which is unspendable and never
            # circulates.
            continue
        cum_coinbase += sum(vout_values)

        comm = None
        for i, o in enumerate(cb["vout"]):
            c = parse_commitment(o["scriptPubKey"]["hex"])
            if c is not None:
                if i != 1:
                    bad(h, f"commitment at vout {i}, not 1")
                comm = c
                break
        if comm is None:
            bad(h, "no PER commitment")
            continue

        # 1. state transition
        if h > 1 and (h - 1) % epoch == 0:
            closed_epoch = (h - 1) // epoch - 1
            new_rate = pool // tickets if tickets else 0
            debit = new_rate * tickets
            debit_by_epoch[closed_epoch] = debit
            pool -= debit
            tickets = 0
            rate = new_rate
        pool += fees // 2
        tickets += comm["block_tickets"]
        if (comm["pool"], comm["tickets"], comm["rate"]) != (pool, tickets, rate):
            bad(h, f"state mismatch: committed {comm['pool']},{comm['tickets']},{comm['rate']} "
                   f"!= expected {pool},{tickets},{rate}")

        # 2. ticket records
        recs = []
        for i in range(2, 2 + comm["block_tickets"]):
            t = parse_ticket(cb["vout"][i]["scriptPubKey"]["hex"])
            if t is None:
                bad(h, f"ticket record {i} does not parse")
                continue
            recs.append(t)
        block_tickets[h] = recs
        ids = [t["id"] for t in recs]
        if any(ids[i - 1] >= ids[i] for i in range(1, len(ids))):
            bad(h, "ticket ids are not strictly sorted")
        if len(set(ids)) != len(ids):
            bad(h, "duplicate ticket id inside the block")
        for prev_h, prev_ids in window:
            if h - prev_h <= 10 and set(ids) & set(prev_ids):
                bad(h, f"ticket repeated from height {prev_h} inside the window")
        window.append((h, ids))
        window = [(hh, ii) for hh, ii in window if h - hh < 10]

        # 3. payouts
        src_h = h - epoch
        src = block_tickets.get(src_h, [])
        expected = len(src) if (src_h >= 1 and rate > 0) else 0
        if comm["payouts"] != expected:
            bad(h, f"payout count {comm['payouts']} != expected {expected}")
        paid = 0
        for i in range(expected):
            o = cb["vout"][2 + comm["block_tickets"] + i]
            if round(o["value"] * COIN) != rate:
                bad(h, f"payout {i} amount != rate {rate}")
            if o["scriptPubKey"]["hex"] != src[i]["payout"]:
                bad(h, f"payout {i} script != source ticket")
            paid += rate
        cum_payouts += paid
        if src_h >= 1:
            src_epoch = (src_h - 1) // epoch
            paid_by_epoch[src_epoch] = paid_by_epoch.get(src_epoch, 0) + paid
            if paid_by_epoch[src_epoch] > debit_by_epoch.get(src_epoch, 0):
                bad(h, f"payouts for epoch {src_epoch} exceed what its close debited")

        # 4. coinbase limit
        expected_total = subsidy(h) + fees - fees // 2 + paid
        if sum(vout_values) != expected_total:
            bad(h, f"coinbase total {sum(vout_values)} != {expected_total}")

        # 5. reservoir bookkeeping: the committed pool is fee/2 collected minus
        #    everything debited at epoch closes. Payouts still in flight were
        #    already debited, so they are not subtracted a second time.
        cum_fees_half += fees // 2
        if pool != cum_fees_half - sum(debit_by_epoch.values()):
            bad(h, f"pool {pool} != fee/2 {cum_fees_half} - debits {sum(debit_by_epoch.values())}")

    # Every closed epoch whose whole redemption window is behind the tip must have
    # paid its tickets exactly what the close debited for them. This is the check
    # that would catch a reservoir that keeps or destroys part of an epoch.
    for e, debit in debit_by_epoch.items():
        if tip >= (e + 2) * epoch and paid_by_epoch.get(e, 0) != debit:
            bad(tip, f"epoch {e}: paid {paid_by_epoch.get(e, 0)} != debited {debit}")

    utxo = node.rpc("gettxoutsetinfo")
    utxo_sats = round(utxo["total_amount"] * COIN)
    if cum_coinbase - cum_fees - cum_burns != utxo_sats:
        bad(tip, f"supply identity: coinbase {cum_coinbase} - fees {cum_fees} "
                 f"- burns {cum_burns} = {cum_coinbase - cum_fees - cum_burns} != utxo {utxo_sats}")

    if problems:
        for p in problems[:20]:
            print("  FAIL ", p)
        raise AssertionError(f"{len(problems)} invariant violation(s) in {label}")
    print(f"  PASS  {label}: {tip + 1} blocks, every PER state, payout, coinbase "
          f"and supply identity holds (epoch {epoch})")
    return tip


def main():
    shutil.rmtree(ft.BASE, ignore_errors=True)
    node = ft.Node("inv", 39181, 39281)
    try:
        node.start()
        node.rpc("createwallet", "w")
        addr = node.rpc("getnewaddress", "", "bech32", wallet="w")
        other = node.rpc("getnewaddress", "", "bech32", wallet="w")
        node.rpc("generatetoaddress", 120, addr)  # past COINBASE_MATURITY (100)
        # Fees every few blocks and tickets at several points, so the reservoir,
        # the rate and the payouts all move.
        for i in range(18):
            node.rpc("sendtoaddress", other, round(1.0 + i * 0.01, 2), wallet="w")
            if i % 3 == 0:
                node.rpc("generateperticket", addr)
            node.rpc("generatetoaddress", 1, addr)
        extra = 30 + EXTRA_BLOCKS
        for i in range(extra):
            if i % 4 == 0:
                node.rpc("generateperticket", addr)
            if i % 5 == 0:
                node.rpc("sendtoaddress", other, 0.5, wallet="w")
            node.rpc("generatetoaddress", 1, addr)
        wait_for(lambda: node.rpc("getrawmempool") == [], 60, "mempool drained")
        tip = walk(node, "active chain")

        print("[reorg] invalidating past an epoch boundary and rebuilding")
        fork = tip - 25
        node.rpc("invalidateblock", node.rpc("getblockhash", fork + 1))
        for i in range(35):
            if i % 3 == 0:
                node.rpc("generateperticket", addr)
            # The transactions from the invalidated branch come back to the
            # mempool and are mined again here, so fees are still exercised.
            node.rpc("generatetoaddress", 1, addr)
        wait_for(lambda: node.rpc("getrawmempool") == [], 60, "mempool drained after reorg")
        new_tip = walk(node, "chain after reorg")
        check(new_tip >= fork + 35, f"reorg branch active at height {new_tip}")

        print("\nPER INVARIANTS PASSED")
        return 0
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"\nFAILED: {e}")
        return 1
    finally:
        node.stop()
        shutil.rmtree(ft.BASE, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
