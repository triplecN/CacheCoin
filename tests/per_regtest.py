#!/usr/bin/env python3
"""
CacheCoin PER (epoch reservoir) test (regtest, one real cachecoind node).

  1. fees are not burned: half of every fee goes to the epoch reservoir (getperinfo.pool)
  2. generateperticket mines an entropy ticket; the next block embeds it (a ticket record
     output in the coinbase) and counts it for the epoch
  3. when the epoch ends the reservoir is divided per ticket (getperinfo.rate)
  4. one epoch later the coinbase pays that ticket its share, to the ticket's own address,
     and no coin is created beyond subsidy + fee share + reservoir payouts

Regtest uses a 20-block epoch (src/kernel/chainparams.cpp) so the payout is reachable.
Standard library only; throw-away datadir under /tmp; never mainnet.

Usage: python3 tests/per_regtest.py [path/to/cachecoind]
"""

import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import functional_regtest as ft  # noqa: E402
import p2p_dos_regtest as p2p  # noqa: E402  (raw P2P client, reused for the relay test)

ft.BITCOIND = sys.argv[1] if len(sys.argv) > 1 else "cachecoind"
ft.BASE = "/tmp/cachecoin-per"
COIN = ft.COIN
check = ft.check


def coinbase(node, height):
    return node.rpc("getblock", node.rpc("getblockhash", height), 2)["tx"][0]


def per_ticket_outputs(cb):
    return [o for o in cb["vout"] if o["scriptPubKey"]["hex"].startswith("6a") and "50455254" in o["scriptPubKey"]["hex"]]


def main():
    shutil.rmtree(ft.BASE, ignore_errors=True)
    node = ft.Node("per", 39151, 39251)
    try:
        node.start()
        node.rpc("createwallet", "w")
        fund = node.rpc("getnewaddress", "", "bech32", wallet="w")
        ticket_addr = node.rpc("getnewaddress", "", "bech32", wallet="w")
        ticket_spk = node.rpc("validateaddress", ticket_addr)["scriptPubKey"]  # hex string
        EPOCH = node.rpc("getperinfo")["epoch_blocks"]
        check(EPOCH == 20, f"regtest epoch length is {EPOCH} blocks")
        info0 = node.rpc("getperinfo")
        check(info0["pool"] == 0 and info0["tickets"] == 0 and info0["rate"] == 0,
              "fresh chain has an empty reservoir state (no pool, tickets, or rate)")
        node.rpc("generatetoaddress", 110, fund)

        print("[1] fees are split, not burned")
        node.rpc("sendtoaddress", ticket_addr, 2.0, "", "", False, True, None, "unset", None, 25, wallet="w")
        txid = node.rpc("getrawmempool")[0]
        fee = round(node.rpc("getmempoolentry", txid)["fees"]["base"] * COIN)
        h_fee = node.rpc("generatetoaddress", 1, fund)[0]
        info = node.rpc("getperinfo", h_fee)
        check(info["pool"] == fee // 2, f"half the fee ({fee // 2}) went to the reservoir, none burned")
        cb = node.rpc("getblock", h_fee, 2)["tx"][0]
        miner_out = sum(round(o["value"] * COIN) for o in cb["vout"] if o["value"] > 0)
        check(miner_out == 5 * COIN + fee - fee // 2, "the miner kept subsidy + the other half of the fee")
        fee_height = node.rpc("getblockcount")

        print("[2] a ticket is mined and embedded in the next block")
        r = node.rpc("generateperticket", ticket_addr)
        check(r["found"] and r["pool"] == 1, "generateperticket found a ticket and pooled it")
        gbt = node.rpc("getblocktemplate", {"rules": ["segwit"]})
        check(any("50455254" in o["script"] for o in gbt["peroutputs"]), "the block template embeds the pooled ticket")
        before = node.rpc("getperinfo")["tickets"]
        h_ticket = node.rpc("generatetoaddress", 1, fund)[0]
        ticket_height = node.rpc("getblockcount")
        cb = node.rpc("getblock", h_ticket, 2)["tx"][0]
        check(len(per_ticket_outputs(cb)) == 1, "the mined block embeds exactly one ticket record")
        check(node.rpc("getperinfo", h_ticket)["tickets"] == before + 1, "the epoch's ticket count went up by one")
        check(node.rpc("generateperticket", ticket_addr, 0)["found"] is False, "maxtries=0 finds nothing")

        print("[2b] a burst of five duplicate tickets does not disconnect the peer")
        # The embedded-ticket cache refuses all five before any pool or rate-limit
        # accounting (0018) and the rate limiter drops silently since 0017, so
        # this checks the observable that matters: an honest duplicate burst keeps
        # the connection. A regression that re-introduced Misbehaving() on flood
        # exhaustion would fail here. Token accounting itself is not observable
        # through RPC; the comment used to claim it was.
        cb = node.rpc("getblock", h_ticket, 2)["tx"][0]
        pert_hex = next(o["scriptPubKey"]["hex"] for o in cb["vout"]
                        if o["scriptPubKey"]["hex"].startswith("6a")
                        and "50455254" in o["scriptPubKey"]["hex"])
        data = bytes.fromhex(pert_hex)
        if data[1] == 0x4C:                      # OP_PUSHDATA1 (long payout)
            body = data[3:3 + data[2]]
        else:
            body = data[2:2 + data[1]]
        check(body[:4] == b"PERT", "parsed the embedded ticket record from the block")
        payload_body = body[4:]                  # anchor(32) + payout(N) + nonce(4)
        anchor, payout, nonce = payload_body[:32], payload_body[32:-4], payload_body[-4:]
        check(len(payout) < 253, "ticket payout fits a one-byte CompactSize")
        p2p_payload = anchor + bytes([len(payout)]) + payout + nonce
        p2p.P2P_PORT = node.p2p_port
        peer = p2p.Peer()
        peer.handshake()
        peer.sync_ping()
        for _ in range(5):
            peer.send("perticket", p2p_payload)
        peer.sync_ping(timeout=30)
        check(True, "5 quick duplicate perticket messages did not disconnect the peer")
        peer.sock.close()

        print("[3] the epoch closes and a per-ticket rate is set")
        # reservoir of this epoch so far, and the ticket count, fix the rate at the boundary
        this_epoch = node.rpc("getperinfo", h_ticket)["epoch"]
        pool_now = node.rpc("getperinfo", h_ticket)["pool"]
        tickets_now = node.rpc("getperinfo", h_ticket)["tickets"]
        boundary = (this_epoch + 1) * EPOCH + 1        # first block of the next epoch
        node.rpc("generatetoaddress", boundary - node.rpc("getblockcount"), fund)
        binfo = node.rpc("getperinfo")
        check(binfo["epoch"] == this_epoch + 1, f"reached the next epoch ({binfo['epoch']})")
        check(binfo["rate"] == pool_now // tickets_now, f"rate = reservoir {pool_now} / {tickets_now} tickets = {binfo['rate']}")
        rate = binfo["rate"]
        check(rate == fee // 2, "with one ticket, the rate is the whole reservoir (half the fee)")

        print("[4] one epoch after it was embedded, the ticket is paid")
        pay_height = ticket_height + EPOCH
        node.rpc("generatetoaddress", pay_height - node.rpc("getblockcount"), fund)
        cb = coinbase(node, pay_height)
        payout = [o for o in cb["vout"] if o["scriptPubKey"]["hex"] == ticket_spk and round(o["value"] * COIN) == rate]
        check(len(payout) == 1, f"block {pay_height} pays the ticket {rate} sat to its own address")
        subsidy = 5 * COIN if pay_height <= 720 else 0
        # regtest halves every 150 blocks after the 720 warm-up; pay_height is well under 720
        total = sum(round(o["value"] * COIN) for o in cb["vout"])
        check(total == subsidy + rate, f"coinbase total {total} = subsidy {subsidy} + reservoir payout {rate}; no coin created")
        check(node.rpc("getblockcount") >= pay_height, "chain advanced through the payout block")

        print("[5] blocks with no tickets pay nothing and keep the reservoir consistent")
        pinfo = node.rpc("getperinfo")
        node.rpc("generatetoaddress", 1, fund)
        pinfo2 = node.rpc("getperinfo")
        check(pinfo2["pool"] == pinfo["pool"], "an empty block does not change the reservoir")

        print("[6] a ticket relays over P2P and another node embeds it")
        peer = ft.Node("per_peer", 39152, 39252)
        peer.start()
        ft.connect(node, peer)
        ft.wait_for(lambda: ft.synced(node, peer), 60, "second node synced")
        peer.rpc("createwallet", "lw")
        laptop_addr = peer.rpc("getnewaddress", "", "bech32", wallet="lw")
        laptop_spk = peer.rpc("validateaddress", laptop_addr)["scriptPubKey"]

        def node_template_has_ticket():
            gbt = node.rpc("getblocktemplate", {"rules": ["segwit"]})
            return any(laptop_spk in o["script"] for o in gbt["peroutputs"])

        r = peer.rpc("generateperticket", laptop_addr)
        check(r["found"], "the second node mined a ticket")
        ft.wait_for(node_template_has_ticket, 30, "ticket reached the first node and its template")
        check(True, "the ticket propagated to the block-mining node over P2P")
        h = node.rpc("generatetoaddress", 1, fund)[0]
        cb = node.rpc("getblock", h, 2)["tx"][0]
        embedded = [o for o in cb["vout"] if o["scriptPubKey"]["hex"].startswith("6a") and laptop_spk in o["scriptPubKey"]["hex"]]
        check(len(embedded) == 1, "the first node embedded the second node's ticket in its block")
        peer.stop()

        print("[7] -coinstatsindex is refused instead of crashing at the first payout")
        stats = ft.Node("per_stats", 39153, 39253)
        try:
            stats.start(extra_args=["-coinstatsindex=1"])
            check(False, "-coinstatsindex should be refused")
        except Exception as e:
            check("coinstatsindex" in str(e), "-coinstatsindex is refused with a clear message")
        finally:
            stats.stop()

        print("\nPER CHECKS PASSED")
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
