#!/usr/bin/env python3
"""
CacheCoin PER adversarial block test (regtest, one real cachecoind node).

Builds coinbase-only blocks by hand and submits them, checking that the node
rejects each malformed PER construction with the right reason and never moves
its tip:

  1. no PER commitment
  2. commitment not at vout[1]
  3. commitment output with a non-zero value
  4. malformed ticket record
  5. PERT record smuggled outside the committed ticket range
  6. more tickets than nPerMaxBlockTickets
  7. the same ticket twice in one block (duplicate id)
  8. a ticket whose payout script would blow the block sigop limit at payout time
  9. a valid ticket slice with a wrong committed state must not drain the local pool

Each block still carries a valid proof of work, so the rejection comes from the
PER rules, not from the header. Standard library only; throw-away datadir under
/tmp; never mainnet.

Usage: python3 tests/per_adversarial_regtest.py [path/to/cachecoind]
"""

import os
import shutil
import struct
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import functional_regtest as ft  # noqa: E402

ft.BITCOIND = sys.argv[1] if len(sys.argv) > 1 else "cachecoind"
ft.BASE = "/tmp/cachecoin-per-adversarial"
check = ft.check
COIN = ft.COIN


def compact_size(n):
    if n < 253:
        return bytes([n])
    if n <= 0xFFFF:
        return b"\xfd" + struct.pack("<H", n)
    return b"\xfe" + struct.pack("<I", n)


def build_coinbase(height, vouts, tag):
    """Coinbase-only transaction with the BIP34 height and the given outputs."""
    if 1 <= height <= 16:
        height_push = bytes([0x50 + height])
    else:
        sn = ft.script_num(height)
        height_push = bytes([len(sn)]) + sn
    script_sig = height_push + bytes([len(tag)]) + tag
    outs = compact_size(len(vouts)) + b"".join(
        struct.pack("<q", value) + compact_size(len(script)) + script
        for value, script in vouts)
    return (struct.pack("<i", 2) + b"\x01" + b"\x00" * 32 + b"\xff\xff\xff\xff"
            + compact_size(len(script_sig)) + script_sig + b"\xff\xff\xff\xff"
            + outs + struct.pack("<I", 0))


def submit(node, prev_hash, height, ntime, vouts, tag):
    """Mine the header nonce until the RandomX proof of work passes, then submit."""
    tx = build_coinbase(height, vouts, tag)
    merkle = ft.sha256d(tx)
    for nonce in range(300):
        header = (struct.pack("<i", 0x20000000) + bytes.fromhex(prev_hash)[::-1] + merkle
                  + struct.pack("<III", ntime, ft.REGTEST_BITS, nonce))
        result = node.rpc("submitblock", (header + b"\x01" + tx).hex())
        if result != "high-hash":
            return result
    raise AssertionError("no nonce with valid proof of work found")


def main():
    shutil.rmtree(ft.BASE, ignore_errors=True)
    node = ft.Node("adv", 39191, 39291)
    try:
        node.start()
        node.rpc("createwallet", "w")
        addr = node.rpc("getnewaddress", "", "bech32", wallet="w")
        node.rpc("generatetoaddress", 110, addr)

        # One real ticket, embedded in a block, for the duplicate case.
        check(node.rpc("generateperticket", addr)["found"], "mined a PER ticket")
        h_ticket = node.rpc("generatetoaddress", 1, addr)[0]
        cb = node.rpc("getblock", h_ticket, 2)["tx"][0]
        pert_hex = next(o["scriptPubKey"]["hex"] for o in cb["vout"]
                        if o["scriptPubKey"]["hex"].startswith("6a")
                        and "50455254" in o["scriptPubKey"]["hex"])
        pert = bytes.fromhex(pert_hex)
        if pert[1] == 0x4C:                  # OP_PUSHDATA1
            pert_body = pert[3:3 + pert[2]]
        else:
            pert_body = pert[2:2 + pert[1]]
        check(pert[0] == 0x6A and pert_body[:4] == b"PERT",
              "the real ticket record has the expected shape")

        miner = (5 * COIN, b"\x51")          # OP_TRUE, valid coinbase output
        dummy = (0, b"\x6a\x04\x00\x00\x00\x00")

        def expect_reject(name, vouts, expected, tag):
            tip = node.rpc("getbestblockhash")
            height = node.rpc("getblockcount")
            # The block time must be strictly after the median time past of the tip,
            # which fast regtest mining can push ahead of the wall clock.
            mediantime = node.rpc("getblockheader", tip)["mediantime"]
            ntime = max(int(time.time()) + 1, mediantime + 1)
            result = submit(node, tip, height + 1, ntime, vouts, tag)
            check(result == expected, f"{name}: rejected with {result!r} (expected {expected!r})")
            check(node.rpc("getbestblockhash") == tip, f"{name}: tip unchanged")

        tip = node.rpc("getbestblockhash")
        valid = ft.per_next_script(node, tip, node.rpc("getblockcount") + 1)

        expect_reject("no commitment", [miner], "bad-cb-per", b"adv1")
        expect_reject("commitment at vout[2]", [miner, dummy, (0, valid)], "bad-cb-per", b"adv2")
        expect_reject("commitment value 1", [miner, (1, valid)], "bad-cb-per", b"adv3")
        expect_reject("malformed ticket",
                      [miner, (0, ft.per_commitment_script(0, 0, 0, 1, 0)), (0, b"\x6a\x04PERT")],
                      "bad-cb-per-ticket", b"adv4")
        expect_reject("extra PERT outside the range",
                      [miner, (0, ft.per_commitment_script(0, 0, 0, 0, 0)), (0, pert)],
                      "bad-cb-per-ticket", b"adv5")
        expect_reject("65 tickets",
                      [miner, (0, ft.per_commitment_script(0, 0, 0, 65, 0))],
                      "bad-cb-per-tickets", b"adv6")
        expect_reject("duplicate ticket",
                      [miner, (0, ft.per_commitment_script(0, 0, 0, 2, 0)), (0, pert), (0, pert)],
                      "bad-cb-per-ticket", b"adv7")

        # A payout script full of CHECKMULTISIG opcodes would become a mandatory
        # coinbase output one epoch later and push the payout block over
        # MAX_BLOCK_SIGOPS_COST, stalling the chain. It must be refused when the
        # ticket is embedded, not when it is paid.
        bad_payout = b"\xae" * 100
        body = b"PERT" + bytes.fromhex(tip)[::-1] + bad_payout + struct.pack("<I", 0)
        pert_bad = b"\x6a\x4c" + bytes([len(body)]) + body
        expect_reject("sigop-bomb payout script",
                      [miner, (0, ft.per_commitment_script(0, 0, 0, 1, 0)), (0, pert_bad)],
                      "bad-cb-per-ticket", b"adv8")
        check(node.log_contains("bad payout script"),
              "the sigop-heavy payout script is the rejection reason")

        # A block that carries a valid ticket slice but commits a wrong state is
        # rejected, and it must leave the local ticket pool untouched.
        check(node.rpc("generateperticket", addr)["found"], "mined a second PER ticket")
        tpl = node.rpc("getblocktemplate", {"rules": ["segwit"]})

        def pooled_pert():
            for o in tpl.get("peroutputs", []):
                h = o["script"]
                if h.startswith("6a") and "50455254" in h:
                    return h
            return None

        fresh = pooled_pert()
        check(fresh is not None, "the template carries the pooled ticket")
        tip2 = node.rpc("getbestblockhash")
        height2 = node.rpc("getblockcount")
        ntime2 = max(int(time.time()) + 1, node.rpc("getblockheader", tip2)["mediantime"] + 1)
        wrong_state = ft.per_commitment_script(0, 0, 0, 1, 0)  # ticket count not committed
        result = submit(node, tip2, height2 + 1, ntime2,
                        [miner, (0, wrong_state), (0, bytes.fromhex(fresh))], b"adv9")
        check(result == "bad-cb-per-state", f"wrong committed state: rejected with {result!r}")
        check(node.rpc("getbestblockhash") == tip2, "wrong committed state: tip unchanged")
        tpl2 = node.rpc("getblocktemplate", {"rules": ["segwit"]})
        still = any(o["script"].startswith("6a") and "50455254" in o["script"]
                    for o in tpl2.get("peroutputs", []))
        check(still, "the rejected block did not drain the local ticket pool")

        print("\nPER ADVERSARIAL CHECKS PASSED")
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
