#!/usr/bin/env python3
"""
CacheCoin functional test (regtest, real cachecoind nodes).

Checks the behaviour that matters for a live network instead of printing PASS:
  1. cachecoin.conf is read from the datadir (rpcuser/rpcpassword only live there),
     and the RandomX self-test (genesis known answer) runs at startup
  2. RandomX mining via generatetoaddress
  3. A fresh node syncs the chain from a peer over P2P (headers + blocks from disk)
  4. Every block can be read back from disk (getblock at every height)
  5. Restarting a node reloads its block index and chain
  6. Subsidy: 5 CCCN for blocks 1-720
  7. fee split (PER): coinbase == subsidy + fee - fee/2 (exact, in satoshis), the other half to the reservoir, and
     getblocktemplate reports the same split
  8. Re-org of depth <= 5 is followed
  8a. Catch-up: a node that is 20 blocks behind on the same chain follows immediately
      (a barrier measured from the candidate alone would refuse this, because a plain
      extension has the same shape as a deep fork)
  8b. Boundary: a switch that gives up 5 blocks is followed, one that gives up 6 is refused
  9. Re-org of depth  > 5 is refused, the node keeps extending its own chain, the refusal
     shows in getblockchaininfo warnings, and it survives a restart
 10. A refused branch is released once it is more than MAX_REORG_DEPTH + REORG_HEAL_LEAD_BLOCKS
     blocks past the fork; the release is stated in height, so it happens on the same
     block on every node
 11. After a deep split heals, ordinary short re-orgs are followed again
  12. A permitted re-org (within MAX_REORG_DEPTH) that hits an invalid block halfway
      returns to the original tip instead of stopping on the shorter valid prefix
  12b. A block with a wrong PER commitment is rejected (bad-cb-per-state)
 13. Blocks more than 10 minutes in the future are rejected, 5 minutes is accepted
 14. -testnet and -signet are refused (CacheCoin has no public test network)
 15. Under W^X enforcement (emulated MemoryDenyWriteExecute) the node falls back to the
     RandomX interpreter instead of crashing, and still validates and mines
 16. The subsidy steps from the 5 CCCN warm-up to 10 CCCN >> halvings exactly at block 721
     (regtest halves every 150 blocks, so the halving boundaries are reachable)

Standard library only. Uses throw-away datadirs under /tmp and non-default ports, never
touches ~/.cachecoin, and never runs mainnet.

Usage: python3 tests/functional_regtest.py [path/to/cachecoind]
"""

import base64
import ctypes
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request

BITCOIND = sys.argv[1] if len(sys.argv) > 1 else "cachecoind"
BASE = "/tmp/cachecoin-functional"
RPC_USER, RPC_PASS = "functional", "functional-test-only"
COIN = 100_000_000
REGTEST_BITS = 0x207FFFFF


class Node:
    def __init__(self, name, p2p_port, rpc_port):
        self.name = name
        self.p2p_port = p2p_port
        self.rpc_port = rpc_port
        self.datadir = os.path.join(BASE, name)
        self.proc = None
        # Throw-away RPC credentials: keep them out of sight from other local users.
        os.makedirs(self.datadir, mode=0o700, exist_ok=True)
        # Credentials only in cachecoin.conf: RPC works only if the file is read.
        conf_path = os.path.join(self.datadir, "cachecoin.conf")
        with open(conf_path, "w") as f:
            f.write(f"rpcuser={RPC_USER}\nrpcpassword={RPC_PASS}\n")
        os.chmod(conf_path, 0o600)

    def start(self, preexec_fn=None, extra_args=()):
        args = [
            BITCOIND, "-regtest", f"-datadir={self.datadir}",
            f"-port={self.p2p_port}", f"-rpcport={self.rpc_port}",
            "-rpcbind=127.0.0.1", "-rpcallowip=127.0.0.1",
            "-listen=1", "-bind=127.0.0.1", "-connect=0", "-dnsseed=0", "-fixedseeds=0",
            "-discover=0", "-natpmp=0", "-txindex=1", "-fallbackfee=0.0001",
            "-printtoconsole=0", *extra_args,
        ]
        self.proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, preexec_fn=preexec_fn)
        wait_for(lambda: self._ready(), 90, f"{self.name} RPC ready")

    def _ready(self):
        if self.proc.poll() is not None:
            raise RuntimeError(f"{self.name} exited early: {self.proc.stderr.read().decode()[-2000:]}")
        try:
            self.rpc("getblockcount")
            return True
        except Exception:
            return False

    def stop(self):
        if self.proc and self.proc.poll() is None:
            try:
                self.rpc("stop")
            except Exception:
                pass
            try:
                self.proc.wait(timeout=60)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.proc = None

    def rpc(self, method, *params, wallet=None):
        url = f"http://127.0.0.1:{self.rpc_port}/" + (f"wallet/{wallet}" if wallet else "")
        body = json.dumps({"jsonrpc": "1.0", "id": "t", "method": method, "params": list(params)}).encode()
        auth = base64.b64encode(f"{RPC_USER}:{RPC_PASS}".encode()).decode()
        req = urllib.request.Request(url, data=body, headers={"Authorization": f"Basic {auth}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=600) as resp:
                data = json.loads(resp.read())
        except urllib.error.HTTPError as e:
            data = json.loads(e.read() or b"{}")
            if not data:
                raise
        if data.get("error"):
            raise RuntimeError(f"{self.name}.{method}: {data['error']}")
        return data["result"]

    def log_contains(self, text):
        with open(os.path.join(self.datadir, "regtest", "debug.log"), errors="replace") as f:
            return text in f.read()


def wait_for(cond, timeout, what):
    end = time.time() + timeout
    while time.time() < end:
        if cond():
            return
        time.sleep(0.25)
    raise AssertionError(f"timeout waiting for: {what}")


def warnings_text(node):
    """getblockchaininfo "warnings" as one string.

    Up to v27 this field is a single string. From v28 it is an array of strings, where
    a substring test on the array itself would silently stop matching, so the entries
    are joined before searching.
    """
    w = node.rpc("getblockchaininfo")["warnings"]
    if isinstance(w, list):
        return " ".join(w)
    return w


def has_warning(node, text):
    return text in warnings_text(node)


def connect(a, b):
    b.rpc("addnode", f"127.0.0.1:{a.p2p_port}", "onetry")
    wait_for(lambda: a.rpc("getconnectioncount") > 0 and b.rpc("getconnectioncount") > 0, 30, f"{a.name}<->{b.name} connected")


def disconnect(a, b):
    for n in (a, b):
        for p in n.rpc("getpeerinfo"):
            try:
                n.rpc("disconnectnode", "", p["id"])
            except RuntimeError:
                pass
    wait_for(lambda: a.rpc("getconnectioncount") == 0 and b.rpc("getconnectioncount") == 0, 30, "disconnected")


def synced(*nodes):
    tips = {n.rpc("getbestblockhash") for n in nodes}
    return len(tips) == 1


def tip_status(node, block_hash):
    """getchaintips status of block_hash on node ("valid-headers" = all blocks stored, not active)."""
    return next((t["status"] for t in node.rpc("getchaintips") if t["hash"] == block_hash), None)


def coinbase_sats(node, block_hash):
    blk = node.rpc("getblock", block_hash, 2)
    return sum(round(v["value"] * COIN) for v in blk["tx"][0]["vout"]), blk


def check(cond, msg):
    if not cond:
        raise AssertionError(msg)
    print(f"  PASS  {msg}")


# ---- hand-made regtest blocks (for blocks the node's own miner would refuse to build) ----

def sha256d(data):
    return hashlib.sha256(hashlib.sha256(data).digest()).digest()


def script_num(n):
    """Minimal CScriptNum encoding of a positive integer (BIP34 height)."""
    out = bytearray()
    while n:
        out.append(n & 0xFF)
        n >>= 8
    if out and out[-1] & 0x80:
        out.append(0)
    return bytes(out)


def per_commitment_script(pool, tickets, rate, block_tickets=0, payouts=0):
    """The coinbase output script that commits to the PER reservoir state (src/per.cpp)."""
    data = b"PER\x01" + struct.pack("<qIqHH", pool, tickets, rate, block_tickets, payouts)
    return b"\x6a" + bytes([len(data)]) + data


def per_next_script(node, prev_hash, height):
    """PER commitment for a block without fees or tickets on top of prev_hash."""
    s = node.rpc("getperinfo", prev_hash)
    if (height - 1) % s["epoch_blocks"] == 0:  # first block of an epoch closes the previous one
        # Consensus (per.cpp PerNextState) debits the whole closing epoch at the
        # boundary: rate = pool / tickets, pool -= rate * tickets, tickets = 0, and
        # the remainder (pool mod tickets) carries over. A helper that did not debit
        # would build a commitment the node rejects whenever the closing epoch had
        # tickets; it only passed before because this suite never mines tickets.
        rate = s["pool"] // s["tickets"] if s["tickets"] else 0
        pool = s["pool"] - rate * s["tickets"]
        return per_commitment_script(pool, 0, rate)
    return per_commitment_script(s["pool"], s["tickets"], s["rate"])


def coinbase_tx(height, value, tag, per_script):
    # BIP34 height exactly as CScript() << nHeight: OP_1..OP_16 for 1-16, else a minimal push.
    height_push = bytes([0x50 + height]) if 1 <= height <= 16 else bytes([len(script_num(height))]) + script_num(height)
    script_sig = height_push + bytes([len(tag)]) + tag
    return (struct.pack("<i", 2) + b"\x01" + b"\x00" * 32 + b"\xff\xff\xff\xff"
            + bytes([len(script_sig)]) + script_sig + b"\xff\xff\xff\xff"
            + b"\x02" + struct.pack("<q", value) + b"\x01\x51"  # output to OP_TRUE
            + struct.pack("<q", 0) + bytes([len(per_script)]) + per_script  # PER commitment
            + struct.pack("<I", 0))


def submit_block(node, prev_hash, height, ntime, value, tag, per_script=None):
    """Build a coinbase-only block and submit it, trying nonces until the RandomX proof of work
    passes (the regtest target accepts about half of all hashes). Returns (hash, submitblock result)."""
    if per_script is None:
        per_script = per_next_script(node, prev_hash, height)
    tx = coinbase_tx(height, value, tag, per_script)
    merkle = sha256d(tx)
    for nonce in range(200):
        header = (struct.pack("<i", 0x20000000) + bytes.fromhex(prev_hash)[::-1] + merkle
                  + struct.pack("<III", ntime, REGTEST_BITS, nonce))
        result = node.rpc("submitblock", (header + b"\x01" + tx).hex())
        if result != "high-hash":
            return sha256d(header)[::-1].hex(), result
    raise AssertionError("no nonce with valid proof of work found")


def set_mdwe():
    """Emulate systemd MemoryDenyWriteExecute=yes (Linux >= 6.3): refuse making memory executable."""
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(65, 1, 0, 0, 0) != 0:  # PR_SET_MDWE, PR_MDWE_REFUSE_EXEC_GAIN
        raise OSError(ctypes.get_errno(), "prctl(PR_SET_MDWE) failed")


def main():
    shutil.rmtree(BASE, ignore_errors=True)
    a = Node("node_a", 39101, 39201)
    b = Node("node_b", 39102, 39202)
    m = Node("node_m", 39103, 39203)
    try:
        print("[1] config file + startup + RandomX self-test")
        a.start()
        check(a.rpc("getblockcount") == 0, "node A reads rpc credentials from cachecoin.conf and starts at genesis")
        check(a.log_contains("RandomX proof-of-work: JIT (W^X), self-test passed"),
              "RandomX genesis known-answer self-test passed at startup (JIT with W^X pages)")

        print("[2] RandomX mining")
        a.rpc("createwallet", "w")
        addr_a = a.rpc("getnewaddress", "", "bech32", wallet="w")
        check(addr_a.startswith("tccn1"), f"regtest bech32 address uses the tccn prefix ({addr_a[:8]}...)")
        t0 = time.time()
        a.rpc("generatetoaddress", 120, addr_a)
        check(a.rpc("getblockcount") == 120, f"mined 120 blocks ({time.time() - t0:.1f}s)")

        print("[3] fresh node syncs over P2P")
        b.start()
        b.rpc("createwallet", "w")
        addr_b = b.rpc("getnewaddress", "", "bech32", wallet="w")
        connect(a, b)
        wait_for(lambda: synced(a, b), 120, "B synced to A")
        check(b.rpc("getblockcount") == 120, "node B downloaded all 120 blocks from node A")
        check(a.rpc("getconnectioncount") > 0 and b.rpc("getconnectioncount") > 0, "peers are still connected after the sync (nobody was disconnected for bad PoW)")

        print("[4] blocks readable from disk")
        ok = all(a.rpc("getblock", a.rpc("getblockhash", h))["height"] == h for h in range(0, 121))
        check(ok, "getblock works for every height 0..120")

        print("[5] restart reloads the chain")
        tip = a.rpc("getbestblockhash")
        disconnect(a, b)
        a.stop()
        a.start()
        a.rpc("loadwallet", "w")
        check(a.rpc("getbestblockhash") == tip and a.rpc("getblockcount") == 120, "node A restarted on the same tip")
        check(a.rpc("getblock", a.rpc("getblockhash", 1))["height"] == 1, "old block still readable after restart")
        connect(a, b)

        print("[6] subsidy")
        for h in (1, 60, 120):
            sats, _ = coinbase_sats(a, a.rpc("getblockhash", h))
            check(sats == 5 * COIN, f"block {h} pays 5 CCCN")

        print("[6b] an immature coinbase is refused by consensus, not just by the wallet")
        # The tip's own coinbase has zero confirmations. The wallet hides immature
        # coins, so the spend is built and signed by hand: what is under test is the
        # consensus rejection reason, which protects re-orged coinbases from being
        # spent as if they were final.
        cb = a.rpc("getblock", a.rpc("getblockhash", 120), 2)["tx"][0]
        raw = a.rpc("createrawtransaction", [{"txid": cb["txid"], "vout": 0}], {addr_b: 4.9})
        signed = a.rpc("signrawtransactionwithwallet", raw, wallet="w")
        check(signed["complete"], "the wallet signed a spend of its own immature coinbase")
        try:
            a.rpc("sendrawtransaction", signed["hex"])
            refused = False
        except RuntimeError as e:
            refused = "premature-spend-of-coinbase" in str(e) or "bad-txns" in str(e)
        check(refused, "spending an immature coinbase is rejected (premature-spend-of-coinbase)")

        print("[7] fee split: half to the miner, half to the PER reservoir")
        a.rpc("sendtoaddress", addr_b, 3.0, "", "", False, True, None, "unset", None, 25, wallet="w")
        wait_for(lambda: len(a.rpc("getrawmempool")) == 1, 30, "tx in mempool")
        txid = a.rpc("getrawmempool")[0]
        fee = round(a.rpc("getmempoolentry", txid)["fees"]["base"] * COIN)
        gbt = a.rpc("getblocktemplate", {"rules": ["segwit"]})
        check(gbt["coinbasefee"] == fee - fee // 2 and gbt["reservoirfee"] == fee // 2,
              f"getblocktemplate: fee {fee} -> miner {gbt['coinbasefee']}, reservoir {gbt['reservoirfee']}")
        check(len(gbt["peroutputs"]) >= 1 and gbt["peroutputs"][0]["script"].startswith("6a1c50455201"),
              "getblocktemplate lists the PER commitment output")
        check(gbt["coinbasevalue"] == 5 * COIN + fee - fee // 2, "template coinbasevalue = subsidy + half the fee")
        bh = a.rpc("generatetoaddress", 1, addr_a)[0]
        sats, blk = coinbase_sats(a, bh)
        block_fees = sum(round(t.get("fee", 0) * COIN) for t in blk["tx"][1:])
        check(block_fees == fee, "mined block contains exactly that fee")
        check(sats == 5 * COIN + fee - fee // 2, f"coinbase {sats} = subsidy + {fee - fee // 2}; {fee // 2} sats to the reservoir")
        wait_for(lambda: synced(a, b), 60, "sync after fee block")

        print("[8] re-org depth <= 5 is followed")
        disconnect(a, b)
        a.rpc("generatetoaddress", 3, addr_a)
        b.rpc("generatetoaddress", 4, addr_b)
        connect(a, b)
        wait_for(lambda: synced(a, b), 60, "A re-orgs to B (depth 3)")
        check(True, "node A switched to the heavier branch (re-org depth 3)")

        print("[8a] a node that is 20 blocks behind on the same chain catches up")
        # No fork at all here: A just stops mining for a while and B carries on. A short
        # gap would hide the bug, because a candidate within MAX_REORG_DEPTH of the tip
        # is permitted either way, and 20 blocks is inside the window the barrier used
        # to refuse.
        disconnect(a, b)
        a_before = a.rpc("getblockcount")
        b.rpc("generatetoaddress", 20, addr_b)          # only B advances; A stays put
        check(b.rpc("getblockcount") == a_before + 20, "B is exactly 20 blocks ahead of A")
        check(a.rpc("getblockcount") == a_before, "A did not move while disconnected")
        connect(a, b)
        wait_for(lambda: a.rpc("getbestblockhash") == b.rpc("getbestblockhash"), 90,
                 "A catches up 20 blocks on the same chain")
        check(True, "a node that is behind follows the chain without any re-org")
        check(not has_warning(a, "re-org barrier"), "catching up is not reported as a refused re-org")
        disconnect(a, b)

        print("[8b] re-org boundary: 5 blocks past the fork is followed, 6 is refused")
        disconnect(a, b)
        a.rpc("generatetoaddress", 4, addr_a)
        b.rpc("generatetoaddress", 5, addr_b)
        connect(a, b)
        wait_for(lambda: synced(a, b), 60, "A re-orgs to B (5 blocks past the fork, at the limit)")
        check(True, "node A followed a branch 5 blocks past the fork (MAX_REORG_DEPTH boundary)")
        # The permit clause keys on how much of A's own chain the switch would undo,
        # so the boundary is rollback 5. A mines five, B mines six: A gives up
        # exactly MAX_REORG_DEPTH blocks and must follow. Without this case a
        # `rollback < MAX_REORG_DEPTH` regression would pass every suite.
        disconnect(a, b)
        a.rpc("generatetoaddress", 5, addr_a)
        b.rpc("generatetoaddress", 6, addr_b)
        connect(a, b)
        wait_for(lambda: synced(a, b), 60, "A re-orgs to B (giving up 5 of its own blocks, at the limit)")
        check(True, "node A followed a branch that gives up exactly MAX_REORG_DEPTH of its own blocks")
        disconnect(a, b)
        fork8b = a.rpc("getblockcount")
        # Six blocks for A, seven for B: switching to B's branch costs A six blocks, one
        # past the limit. Building it the other way round (A five, B six) does not test
        # the boundary, because A would only be giving up five blocks there.
        a.rpc("generatetoaddress", 6, addr_a)
        b.rpc("generatetoaddress", 7, addr_b)
        a_tip5 = a.rpc("getbestblockhash")
        b_tip5 = b.rpc("getbestblockhash")
        connect(a, b)
        wait_for(lambda: tip_status(a, b_tip5) == "valid-headers", 60, "A stored all of B's branch")
        time.sleep(2)
        check(a.rpc("getbestblockhash") == a_tip5, "node A refused a switch that would give up 6 blocks (just over the limit)")
        # Reunite the nodes. A will not follow B, and rewinding A would not help: the
        # limit is what this node gives up, so A stays refused either way. B is the one
        # that can move. Rewinding B past its own first block after the fork leaves it on
        # the common block, where A's branch is simply an extension of what B already has,
        # so B joins A and the nodes are back in step.
        disconnect(a, b)
        b.rpc("invalidateblock", b.rpc("getblockhash", fork8b + 1))
        connect(a, b)
        wait_for(lambda: synced(a, b), 60, "B rejoins A's branch after rewinding past the refused fork")
        check(True, "operator override reunites the nodes for the next tests")
        disconnect(a, b)

        print("[9] re-org depth > 5 is refused, node keeps working, refusal survives a restart")
        disconnect(a, b)
        fork_height = a.rpc("getblockcount")
        a.rpc("generatetoaddress", 7, addr_a)
        b.rpc("generatetoaddress", 8, addr_b)
        a_tip = a.rpc("getbestblockhash")
        b_tip = b.rpc("getbestblockhash")
        connect(a, b)
        wait_for(lambda: tip_status(a, b_tip) == "valid-headers", 60, "A stored all of B's branch")
        time.sleep(2)
        check(a.rpc("getbestblockhash") == a_tip, "node A refused B's branch 8 blocks past the fork")
        check(a.log_contains("refused re-org"), "refusal is logged")
        check(has_warning(a, "re-org barrier"), "getblockchaininfo warns that a chain with more work is refused")
        disconnect(a, b)
        a.stop()
        a.start()
        a.rpc("loadwallet", "w")
        check(a.rpc("getbestblockhash") == a_tip, "after a restart node A still refuses B's branch (start-up import is not IBD)")
        a.rpc("generatetoaddress", 1, addr_a)
        check(a.rpc("getblockcount") == fork_height + 8, "node A still extends its own chain afterwards (no freeze)")
        connect(a, b)

        print("[10] a refused branch is released once it is 36 blocks past the fork")
        # [9] left A 8 blocks past the fork on its own branch and B 8 past on its
        # own. The release is MAX_REORG_DEPTH + REORG_HEAL_LEAD_BLOCKS + 1, stated
        # in height so that a node which is behind releases on the same block as
        # one that is ahead. A work-based release could not do that.
        a_tip10 = a.rpc("getbestblockhash")  # a_tip is A's tip from [9], one block behind now
        b.rpc("generatetoaddress", 27, addr_b)  # B: 35 past the fork, still refused
        b_tip = b.rpc("getbestblockhash")
        wait_for(lambda: tip_status(a, b_tip) == "valid-headers", 90, "A stored B's branch")
        time.sleep(2)
        check(a.rpc("getbestblockhash") == a_tip10, "still refused 35 blocks past the fork")
        b.rpc("generatetoaddress", 1, addr_b)   # B: 36 past the fork, released
        b_tip = b.rpc("getbestblockhash")
        wait_for(lambda: a.rpc("getbestblockhash") == b_tip, 90, "A follows B once the branch is 36 blocks past the fork")
        check(True, "node A followed a branch 36 blocks past the fork (deterministic release)")
        check(not has_warning(a, "re-org barrier"), "the barrier warning is cleared once nothing is refused")

        print("[11] after a deep split heals, short re-orgs are followed again")
        disconnect(a, b)
        a.rpc("generatetoaddress", 4, addr_a)
        b.rpc("generatetoaddress", 5, addr_b)
        connect(a, b)
        wait_for(lambda: synced(a, b), 90, "a fresh branch 5 blocks past the fork is followed")
        check(True, "the barrier is back to following ordinary short re-orgs")

        print("[12] a permitted re-org that hits an invalid block returns to the original tip")
        disconnect(a, b)
        fork_hash = a.rpc("getbestblockhash")
        fork = a.rpc("getblockheader", fork_hash)
        # Three blocks on A's own chain, so the five-block branch below carries more
        # work and A really tries to activate it. If A's own branch were the longer one
        # the branch would simply lose on work and never be validated at all, which
        # would make this test pass without exercising the rollback path.
        a.rpc("generatetoaddress", 3, addr_a)
        a_tip = a.rpc("getbestblockhash")
        prev, results, hashes = fork_hash, [], []
        # Five blocks, so the branch is within MAX_REORG_DEPTH and the barrier permits it.
        # The test needs a permitted re-org: the barrier now refuses anything past the
        # fork until it is 36 blocks deep, so a deeper branch would simply be ignored
        # rather than followed and then abandoned, and the return-to-start-tip path
        # would never be exercised. Block 3 overpays its coinbase.
        for i in range(1, 6):
            value = 5 * COIN + (1 if i == 3 else 0)
            prev, result = submit_block(a, prev, fork["height"] + i, fork["time"] + i, value, b"split" + bytes([i]))
            results.append(result)
            hashes.append(prev)
        # Block 3 is stored first and only fails validation once the chain is assembled,
        # so it comes back inconclusive; block 5 is refused outright because its parent
        # is already known to be invalid.
        check(all(r in (None, "inconclusive") for r in results[:4]), "the blocks up to the bad one were stored")
        check(results[4] == "bad-prevblk", "the block after the invalid one is refused (bad-prevblk)")
        time.sleep(2)
        check(a.rpc("getbestblockhash") == a_tip, "node A is back on its own 3-block tip after the other branch failed at block 3")
        check(tip_status(a, hashes[3]) == "invalid", "the branch with the invalid block is marked invalid")
        check(a.log_contains("bad-cb-amount"), "the invalid block was rejected for overpaying its coinbase")

        print("[12b] a block with a wrong PER commitment is rejected")
        tip_h = a.rpc("getbestblockhash")
        tip = a.rpc("getblockheader", tip_h)
        good = per_next_script(a, tip_h, tip["height"] + 1)
        bad = bytearray(good)
        bad[10] ^= 1  # flip one byte of the committed pool: same shape, wrong state
        bad_hash, _ = submit_block(a, tip_h, tip["height"] + 1, tip["time"] + 1,
                                   5 * COIN, b"badper", per_script=bytes(bad))
        time.sleep(2)
        check(a.rpc("getbestblockhash") == tip_h, "tip unchanged after the bad-PER block")
        check(tip_status(a, bad_hash) == "invalid", "the bad-PER branch is marked invalid")
        check(a.log_contains("bad-cb-per-state"), "rejected for the wrong reservoir state")

        print("[13] future block time limit is 10 minutes")
        tip = a.rpc("getbestblockhash")
        height = a.rpc("getblockcount")
        now = int(time.time())
        _, result = submit_block(a, tip, height + 1, now + 11 * 60, 5 * COIN, b"ftl-far")
        check(result == "time-too-new", "a block 11 minutes in the future is rejected (time-too-new)")
        new_hash, result = submit_block(a, tip, height + 1, now + 5 * 60, 5 * COIN, b"ftl-near")
        check(result is None and a.rpc("getbestblockhash") == new_hash, "a block 5 minutes in the future is accepted")
        check(a.rpc("getnetworkinfo")["timeoffset"] == 0, "peer time adjustment is off (timeoffset 0)")

        print("[13b] a clock behind the tip warns at start-up instead of looking stuck")
        # Consensus rejects blocks more than MAX_FUTURE_BLOCK_TIME (10 min) ahead, but
        # the start-up sanity check keeps Bitcoin's 2-hour TIMESTAMP_WINDOW. A clock in
        # between starts "healthy" and then rejects every new block; the warning has to
        # name the clock so the operator does not hunt a network problem.
        tip_time = a.rpc("getblockheader", a.rpc("getbestblockhash"))["time"]
        a.stop()
        a.start(extra_args=[f"-mocktime={tip_time - 20 * 60}"])  # 20 min behind, inside the 2 h window
        check(a.log_contains("clock is behind the chain tip"),
              "start-up warns when the tip is more than 10 minutes ahead of the clock")
        check(a.rpc("getblockcount") > 0, "the warning is not fatal; the node still starts")
        a.stop()
        a.start()

        print("[14] no public test network")
        for flag in ("-testnet", "-testnet4", "-signet"):
            datadir = os.path.join(BASE, "testnet" + flag)
            os.makedirs(datadir, exist_ok=True)
            r = subprocess.run([BITCOIND, flag, f"-datadir={datadir}", "-printtoconsole=0"], capture_output=True, text=True, timeout=120)
            check(r.returncode != 0 and "no public test network" in (r.stderr + r.stdout), f"{flag} is refused at startup")

        print("[15] W^X enforcement: RandomX falls back to the interpreter")
        # Probe PR_SET_MDWE (Linux >= 6.3) in a throw-away child, never in this process.
        probe = subprocess.run([sys.executable, "-c", "import ctypes, sys; sys.exit(0 if ctypes.CDLL(None).prctl(65, 1, 0, 0, 0) == 0 else 1)"])
        if probe.returncode != 0:
            print("  SKIP  kernel has no PR_SET_MDWE")
        else:
            m.start(preexec_fn=set_mdwe)
            check(m.log_contains("RandomX proof-of-work: interpreter (this system does not allow JIT memory), self-test passed"),
                  "under emulated MemoryDenyWriteExecute the node detects it and uses the RandomX interpreter")
            m.rpc("generatetoaddress", 3, addr_a)
            check(m.rpc("getblockcount") == 3, "and it still mines and validates blocks")
            connect(a, m)
            wait_for(lambda: synced(a, m), 900, "M syncs A's chain with the interpreter")
            check(True, "node M synced node A's chain with the interpreter")
            m.stop()

        print("[16] subsidy schedule after the warm-up (regtest halving interval: 150 blocks)")
        need = 752 - a.rpc("getblockcount")
        if need > 0:
            a.rpc("generatetoaddress", need, addr_a)
        # GetBlockSubsidy: 5 CCCN up to 720, then 10 CCCN >> ((height - 1) / interval)
        expected = {720: 5 * COIN, 721: (10 * COIN) >> 4, 750: (10 * COIN) >> 4, 751: (10 * COIN) >> 5}
        for h, subsidy in expected.items():
            st = a.rpc("getblockstats", h, ["subsidy", "totalfee"])
            sats, _ = coinbase_sats(a, a.rpc("getblockhash", h))
            fee = st["totalfee"]
            check(st["subsidy"] == subsidy and sats == subsidy + fee - fee // 2,
                  f"block {h}: subsidy {subsidy / COIN} CCCN, coinbase = subsidy + half the fees")

        print("\nALL CHECKS PASSED")
        return 0
    except Exception as e:
        print(f"\nFAILED: {e}")
        return 1
    finally:
        a.stop()
        b.stop()
        m.stop()


if __name__ == "__main__":
    sys.exit(main())
