#!/usr/bin/env python3
"""
CacheCoin swap-script conformance test (regtest, one node, hand-built transactions).

Atomic swaps on CCCN would use the inherited Bitcoin Script primitives: a
SHA-256 hashlock to claim, and CLTV/CSV timeouts to refund. This test exercises
those primitives against the node's own interpreter and, more importantly, their
interaction with CacheCoin's time rules (median-time-past, 60-second blocks, the
10-minute future limit, the 5/36 re-org barrier). It does not test any bridge or
trust model. The scripts here are signature-free on purpose: it proves opcode
and timeout behavior, not a signed swap client. Anyone building swap tooling
must test their own script composition and signing.

Cases:
  1. hashlock: correct preimage claims, wrong/missing preimage fails, replay fails
  2. CLTV height lock: fails early, is non-final before the height, claims at it
  3. CLTV time lock uses median-time-past, not height (deterministic via mocktime)
  4. CSV height lock: non-BIP68-final before maturity, spendable at it
  5. CSV time lock is 512-second units (about nine 60 s blocks for one unit)
  6. a re-org removes the funded output; the swap must re-verify funding
  7. at the timeout boundary claim and refund are both valid; mining one kills the other
  8. a sub-dust output is refused by policy (dust, not consensus)

Usage: python3 tests/swap_scripts_regtest.py [path/to/cachecoind]
"""

import hashlib
import os
import shutil
import struct
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import functional_regtest as ft  # noqa: E402
import mainnet_smoke as ms  # noqa: E402

ft.BITCOIND = sys.argv[1] if len(sys.argv) > 1 else "cachecoind"
ft.BASE = "/tmp/cachecoin-swap-scripts"
check, wait_for = ft.check, ft.wait_for

OP_IF = 0x63
OP_ELSE = 0x67
OP_ENDIF = 0x68
OP_SHA256 = 0xA8
OP_EQUAL = 0x87
OP_CHECKLOCKTIMEVERIFY = 0xB1
OP_CHECKSEQUENCEVERIFY = 0xB2
OP_DROP = 0x75
OP_TRUE = 0x51


def varint(n):
    if n < 0xFD:
        return bytes([n])
    if n <= 0xFFFF:
        return b"\xFD" + struct.pack("<H", n)
    if n <= 0xFFFFFFFF:
        return b"\xFE" + struct.pack("<I", n)
    return b"\xFF" + struct.pack("<Q", n)


def script_num(n):
    out = bytearray()
    while n:
        out.append(n & 0xFF)
        n >>= 8
    if out and out[-1] & 0x80:
        out.append(0)
    return bytes(out)


def push(data):
    return bytes([len(data)]) + data


def num_push(n):
    """Minimal script-number push (OP_1..OP_16 for small values)."""
    if n == 0:
        return b"\x00"
    if 1 <= n <= 16:
        return bytes([0x50 + n])
    return push(script_num(n))


def serialize_tx(inputs, outputs, witnesses, locktime=0, version=2):
    """inputs: [(txid_hex, vout, sequence)], outputs: [(script_hex, sats)],
    witnesses: [[item bytes, ...], ...] (one list per input)."""
    tx = struct.pack("<i", version) + b"\x00\x01" + varint(len(inputs))
    for txid, vout, sequence in inputs:
        tx += bytes.fromhex(txid)[::-1] + struct.pack("<I", vout) + b"\x00" + struct.pack("<I", sequence)
    tx += varint(len(outputs))
    for spk_hex, sats in outputs:
        tx += struct.pack("<q", sats) + varint(len(spk_hex) // 2) + bytes.fromhex(spk_hex)
    for items in witnesses:
        tx += varint(len(items))
        for item in items:
            tx += varint(len(item)) + item
    return (tx + struct.pack("<I", locktime)).hex()


def p2wsh(script):
    program = hashlib.sha256(script).digest()
    return "0020" + program.hex(), ms.bech32_address("tccn", 0, program)


def mtp(node):
    return node.rpc("getblockheader", node.rpc("getbestblockhash"))["mediantime"]


def fund(node, script, miner_addr, amount=0.001):
    """Send to the P2WSH, mine it, return (txid, vout)."""
    spk, addr = p2wsh(script)
    txid = node.rpc("sendtoaddress", addr, amount, wallet="w")
    node.rpc("generatetoaddress", 1, miner_addr)
    raw = node.rpc("getrawtransaction", txid, True)
    vout = next(i for i, o in enumerate(raw["vout"]) if o["scriptPubKey"]["hex"] == spk)
    return txid, vout


def out_script(node, addr):
    return node.rpc("getaddressinfo", addr)["scriptPubKey"]


def accept(node, raw):
    r = node.rpc("testmempoolaccept", [raw])[0]
    return r["allowed"], r.get("reject-reason", "")


def main():
    shutil.rmtree(ft.BASE, ignore_errors=True)
    node = ft.Node("swap", 39231, 39331)
    try:
        node.start()
        node.rpc("createwallet", "w")
        miner = node.rpc("getnewaddress", "", "bech32", wallet="w")
        sink = node.rpc("getnewaddress", "", "bech32", wallet="w")
        sink_spk = out_script(node, sink)
        node.rpc("generatetoaddress", 110, miner)  # past COINBASE_MATURITY

        print("[1] SHA-256 hashlock")
        preimage = b"cachecoin-swap-preimage-0001"
        h = hashlib.sha256(preimage).digest()
        lock = bytes([OP_SHA256]) + push(h) + bytes([OP_EQUAL])
        txid, vout = fund(node, lock, miner)
        # The wrong-preimage spend is witness-only different: same txid, so it has
        # to be checked before the real claim is broadcast, or the node answers
        # "txn-already-known" instead of validating the witness.
        wrong = serialize_tx([(txid, vout, 0xFFFFFFFE)], [(sink_spk, 99_000)], [[b"x" * len(preimage), lock]])
        ok, reason = accept(node, wrong)
        check(not ok and "script-verify-flag-failed" in reason, f"a wrong preimage is refused ({reason})")
        empty = serialize_tx([(txid, vout, 0xFFFFFFFE)], [(sink_spk, 99_000)], [[lock]])
        ok, reason = accept(node, empty)
        check(not ok, f"a missing preimage is refused ({reason})")
        claim = serialize_tx([(txid, vout, 0xFFFFFFFE)], [(sink_spk, 99_000)], [[preimage, lock]])
        ok, reason = accept(node, claim)
        check(ok, f"the preimage claims the output ({reason or 'allowed'})")
        node.rpc("sendrawtransaction", claim)
        node.rpc("generatetoaddress", 1, miner)
        check(node.rpc("gettxout", txid, vout) is None, "the output is spent after the claim")
        ok, reason = accept(node, claim)
        check(not ok, f"the same claim cannot be replayed ({reason})")

        print("[2] CLTV height lock")
        height = node.rpc("getblockcount")
        cltv = num_push(height + 5) + bytes([OP_CHECKLOCKTIMEVERIFY, OP_DROP, OP_TRUE])
        txid3, vout3 = fund(node, cltv, miner)  # confirms at height + 1
        early = serialize_tx([(txid3, vout3, 0xFFFFFFFE)], [(sink_spk, 99_000)], [[cltv]], locktime=height + 4)
        ok, reason = accept(node, early)
        check(not ok, f"a refund below the lock height is refused ({reason})")
        at_height = serialize_tx([(txid3, vout3, 0xFFFFFFFE)], [(sink_spk, 99_000)], [[cltv]], locktime=height + 5)
        ok, reason = accept(node, at_height)
        check(not ok and "non-final" in reason, f"at the lock height the refund is still non-final ({reason})")
        need = (height + 6) - node.rpc("getblockcount")  # finality needs nLockTime < tip height
        node.rpc("generatetoaddress", need, miner)
        ok, reason = accept(node, at_height)
        check(ok, f"once the height is passed the refund is accepted ({reason or 'allowed'})")
        node.rpc("sendrawtransaction", at_height)
        node.rpc("generatetoaddress", 1, miner)
        check(node.rpc("gettxout", txid3, vout3) is None, "the refund confirms and spends the output")

        print("[3] a time lock is median-time-past, not height")
        t0 = int(time.time()) + 3600
        node.rpc("setmocktime", t0)
        x = t0 + 600
        cltv_time = num_push(x) + bytes([OP_CHECKLOCKTIMEVERIFY, OP_DROP, OP_TRUE])
        txid4, vout4 = fund(node, cltv_time, miner)
        spend = serialize_tx([(txid4, vout4, 0xFFFFFFFE)], [(sink_spk, 99_000)], [[cltv_time]], locktime=x)
        ok, reason = accept(node, spend)
        check(not ok and "non-final" in reason, f"before the median time passes, the spend is non-final ({reason})")
        for i in range(1, 17):  # each block moves the median by 60 s
            node.rpc("setmocktime", t0 + 60 * i)
            node.rpc("generatetoaddress", 1, miner)
        check(mtp(node) >= x, f"the median time passed the lock ({mtp(node)} >= {x})")
        ok, reason = accept(node, spend)
        check(ok, f"the spend is accepted once the median time passes ({reason or 'allowed'})")
        # Keep mocktime at the last value: the chain now has future timestamps, so
        # resetting the clock to real time would make the next block look too new.

        print("[4] CSV height lock")
        csv = num_push(5) + bytes([OP_CHECKSEQUENCEVERIFY, OP_DROP, OP_TRUE])
        txid6, vout6 = fund(node, csv, miner)
        relative = serialize_tx([(txid6, vout6, 5)], [(sink_spk, 99_000)], [[csv]])
        ok, reason = accept(node, relative)
        check(not ok and "non-BIP68-final" in reason, f"a relative lock before maturity is refused ({reason})")
        node.rpc("generatetoaddress", 4, miner)
        ok, reason = accept(node, relative)
        check(ok, f"after the relative maturity it is accepted ({reason or 'allowed'})")
        node.rpc("sendrawtransaction", relative)
        node.rpc("generatetoaddress", 1, miner)
        check(node.rpc("gettxout", txid6, vout6) is None, "the relative-lock spend confirms")

        print("[5] CSV time units are 512 seconds")
        # Warm the median up to the mock clock first, so the coin's median time is
        # close to its block time and the 512 s unit is measured honestly.
        tip_time = node.rpc("getblockheader", node.rpc("getbestblockhash"))["time"]
        base = tip_time + 60
        for i in range(12):
            node.rpc("setmocktime", base + 60 * i)
            node.rpc("generatetoaddress", 1, miner)
        node.rpc("setmocktime", base + 720)
        csv_time = num_push((1 << 22) | 1) + bytes([OP_CHECKSEQUENCEVERIFY, OP_DROP, OP_TRUE])
        txid8, vout8 = fund(node, csv_time, miner)
        spend = serialize_tx([(txid8, vout8, (1 << 22) | 1)], [(sink_spk, 99_000)], [[csv_time]])
        accepted_at = None
        for i in range(1, 15):
            node.rpc("setmocktime", base + 720 + 60 * i)
            node.rpc("generatetoaddress", 1, miner)
            ok, reason = accept(node, spend)
            if ok:
                accepted_at = i
                break
        check(accepted_at is not None and accepted_at > 5,
              f"one 512 s unit needs more than five 60 s blocks (accepted after {accepted_at})")
        check(accepted_at is not None and accepted_at <= 12,
              f"and it matures within about nine blocks (accepted after {accepted_at})")

        print("[6] a re-org removes the funded output")
        txid9, vout9 = fund(node, lock, miner)
        height = node.rpc("getblockcount")
        check(node.rpc("gettxout", txid9, vout9, False) is not None, "the swap output is funded and confirmed")
        node.rpc("invalidateblock", node.rpc("getblockhash", height))
        node.rpc("generateblock", sink, [])  # a branch that does not include the funding tx
        node.rpc("generateblock", sink, [])
        check(node.rpc("gettxout", txid9, vout9, False) is None,
              "after the re-org the confirmed output is gone")
        check(node.rpc("gettxout", txid9, vout9, True) is not None,
              "but the mempool view still shows it: a swap must check confirmations, not the mempool view")
        check(txid9 in node.rpc("getrawmempool"), "the funding transaction is back in the mempool")
        node.rpc("generatetoaddress", 1, miner)
        check(node.rpc("gettxout", txid9, vout9, False) is not None, "re-mined, the output exists again")

        print("[7] the timeout boundary is a race, not a tie-break")
        preimage2 = b"cachecoin-swap-boundary-0002"
        h2 = hashlib.sha256(preimage2).digest()
        height = node.rpc("getblockcount")
        htlc = (bytes([OP_IF, OP_SHA256]) + push(h2) + bytes([OP_EQUAL, OP_ELSE]) + num_push(height + 2) +
                bytes([OP_CHECKLOCKTIMEVERIFY, OP_DROP, OP_TRUE, OP_ENDIF]))
        txid11, vout11 = fund(node, htlc, miner)  # confirms at height + 1
        node.rpc("generatetoaddress", 2, miner)   # tip = height + 3, locktime passed
        claim = serialize_tx([(txid11, vout11, 0xFFFFFFFE)], [(sink_spk, 99_000)], [[preimage2, b"\x01", htlc]])
        refund = serialize_tx([(txid11, vout11, 0xFFFFFFFE)], [(sink_spk, 99_000)], [[b"", htlc]],
                              locktime=height + 2)
        ok1, r1 = accept(node, claim)
        ok2, r2 = accept(node, refund)
        check(ok1 and ok2, f"at the boundary claim and refund are both valid (claim {r1 or 'ok'}, refund {r2 or 'ok'})")
        node.rpc("sendrawtransaction", claim)
        node.rpc("generatetoaddress", 1, miner)
        ok, reason = accept(node, refund)
        check(not ok, f"once the claim is mined the refund has nothing to spend ({reason})")

        print("[8] dust is policy, not consensus")
        txid13, vout13 = fund(node, lock, miner)
        dusty = serialize_tx([(txid13, vout13, 0xFFFFFFFE)], [(sink_spk, 1)], [[preimage, lock]])
        ok, reason = accept(node, dusty)
        check(not ok and "dust" in reason, f"a 1-sat output is refused as dust ({reason})")

        print("\nSWAP SCRIPT CHECKS PASSED")
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
