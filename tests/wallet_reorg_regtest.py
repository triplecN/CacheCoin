#!/usr/bin/env python3
"""
CacheCoin wallet re-org test (regtest, three nodes).

What an exchange has to survive: a transaction that was confirmed gets re-orged
out. The wallet must move it from "confirmed" back to the mempool, report zero
confirmations, list it as unconfirmed in listsinceblock, and show it confirmed
again once the new branch includes it. A wallet that kept the old confirmation
would let a deposit be credited against a transaction that no longer exists.

Setup: A and B are connected and synced. C is disconnected before the payment
so it never sees it, then builds a longer branch from the fork point without
the payment. A follows C's branch (depth 2, allowed), and the payment has to
come back.

Usage: python3 tests/wallet_reorg_regtest.py [path/to/cachecoind]
"""

import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import functional_regtest as ft  # noqa: E402

ft.BITCOIND = sys.argv[1] if len(sys.argv) > 1 else "cachecoind"
ft.BASE = "/tmp/cachecoin-wallet-reorg"
check, wait_for, connect, disconnect, synced = ft.check, ft.wait_for, ft.connect, ft.disconnect, ft.synced


def main():
    shutil.rmtree(ft.BASE, ignore_errors=True)
    a = ft.Node("reorg_a", 39221, 39321)
    b = ft.Node("reorg_b", 39222, 39322)
    c = ft.Node("reorg_c", 39223, 39323)
    try:
        for n in (a, b, c):
            n.start()
        a.rpc("createwallet", "w")
        b.rpc("createwallet", "w")
        c.rpc("createwallet", "w")
        addr_a = a.rpc("getnewaddress", "", "bech32", wallet="w")
        addr_b = b.rpc("getnewaddress", "", "bech32", wallet="w")
        addr_c = c.rpc("getnewaddress", "", "bech32", wallet="w")
        a.rpc("generatetoaddress", 120, addr_a)
        connect(a, b)
        connect(b, c)
        wait_for(lambda: synced(a, b, c), 120, "all nodes synced")

        print("[1] a payment is confirmed, with C disconnected")
        # Drop only the B<->C link: C must not see the payment, or its branch
        # would include it, and the A<->B link has to stay up for the relay.
        for p in c.rpc("getpeerinfo"):
            c.rpc("disconnectnode", "", p["id"])
        wait_for(lambda: c.rpc("getconnectioncount") == 0, 30, "C isolated")
        check(a.rpc("getconnectioncount") > 0 and b.rpc("getconnectioncount") > 0, "A and B stay connected")
        txid = a.rpc("sendtoaddress", addr_b, 1.25, wallet="w")
        a.rpc("generatetoaddress", 1, addr_a)  # height 121, includes the payment
        wait_for(lambda: b.rpc("getblockcount") == 121, 60, "B synced the payment block")
        check(b.rpc("getreceivedbyaddress", addr_b) == 1.25, "B sees the confirmed 1.25")
        check(a.rpc("gettransaction", txid, wallet="w")["confirmations"] == 1,
              "A's wallet sees one confirmation")
        disconnect(a, b)

        print("[2] C builds a longer branch without the payment; A follows it")
        fork_hash = c.rpc("getblockhash", 120)
        for _ in range(2):
            c.rpc("generateblock", addr_c, [])
        check(c.rpc("getblockcount") == 122, "C is at height 122 without the payment")
        connect(a, c)
        wait_for(lambda: a.rpc("getbestblockhash") == c.rpc("getbestblockhash"), 120,
                 "A followed C's heavier branch")

        print("[3] the re-orged payment is back in the mempool, unconfirmed")
        wait_for(lambda: txid in a.rpc("getrawmempool"), 60, "the payment returned to A's mempool")
        check(a.rpc("gettransaction", txid, wallet="w")["confirmations"] == 0,
              "A's wallet reports zero confirmations after the re-org")
        listed = a.rpc("listsinceblock", fork_hash)["transactions"]
        entry = next((t for t in listed if t["txid"] == txid), None)
        check(entry is not None and entry["confirmations"] == 0,
              "listsinceblock lists it as unconfirmed (what an exchange watches)")
        check(b.rpc("getreceivedbyaddress", addr_b) == 1.25,
              "B still reports the old confirmation while disconnected (nodes can disagree mid-re-org)")

        print("[4] the new branch confirms the payment again")
        # Submit the raw transaction to C directly instead of waiting on mempool
        # relay: what is under test is the wallet's accounting after the re-org,
        # not relay timing. Mining then goes through the normal template path,
        # which commits to the fees of what it includes.
        raw = a.rpc("gettransaction", txid, wallet="w")["hex"]
        c.rpc("sendrawtransaction", raw)
        wait_for(lambda: txid in c.rpc("getrawmempool"), 30, "C accepted the raw payment")
        c.rpc("generatetoaddress", 1, addr_c)
        wait_for(lambda: synced(a, c) and a.rpc("getblockcount") == 123, 120, "A and C on the new tip")
        wait_for(lambda: a.rpc("gettransaction", txid, wallet="w")["confirmations"] >= 1, 60,
                 "A's wallet confirms it again")
        check(True, "A's wallet confirms the payment on the new branch")
        connect(a, b)
        wait_for(lambda: synced(a, b, c), 120, "B synced the new branch")
        check(b.rpc("getreceivedbyaddress", addr_b) == 1.25, "B sees the payment confirmed again")

        print("\nWALLET REORG CHECKS PASSED")
        return 0
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"\nFAILED: {e}")
        return 1
    finally:
        for n in (a, b, c):
            n.stop()
        shutil.rmtree(ft.BASE, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
