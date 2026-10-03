#!/usr/bin/env python3
"""
CacheCoin soak test: a longer regtest chain with fees and tickets, a restart in
the middle, and the live invariant watcher (scripts/watch_invariants.py) run
against it twice.

The watcher is the tool operators are told to run for years; this is the test
that it actually works end to end: it walks the whole chain, re-derives the PER
accounting and the supply identity from the node's own data, writes a
checkpoint, and after a re-org rewinds to that checkpoint and re-walks without
a false alarm.

Usage: python3 tests/soak_regtest.py [path/to/cachecoind] [blocks-after-maturity]
"""

import json
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import functional_regtest as ft  # noqa: E402

ft.BITCOIND = sys.argv[1] if len(sys.argv) > 1 else "cachecoind"
BLOCKS = int(sys.argv[2]) if len(sys.argv) > 2 else 1000
ft.BASE = "/tmp/cachecoin-soak"
WATCHER = os.path.abspath(os.path.join(HERE, "..", "scripts", "watch_invariants.py"))
STATE = "/tmp/cachecoin-soak-state.json"
check, wait_for = ft.check, ft.wait_for


def run_watcher(node):
    env = dict(os.environ)
    env["CACHECOIN_RPC_HOST"] = "127.0.0.1"
    env["CACHECOIN_RPC_PORT"] = str(node.rpc_port)
    # The test nodes use rpcuser/rpcpassword from cachecoin.conf, so there is no
    # cookie file; the watcher takes credentials from the environment too.
    env["CACHECOIN_RPC_USER"] = ft.RPC_USER
    env["CACHECOIN_RPC_PASS"] = ft.RPC_PASS
    env["WATCH_STATE"] = STATE
    return subprocess.run([sys.executable, WATCHER, "--txout"], capture_output=True, text=True, timeout=900, env=env)


def main():
    shutil.rmtree(ft.BASE, ignore_errors=True)
    for path in (STATE,):
        if os.path.exists(path):
            os.remove(path)
    node = ft.Node("soak", 39211, 39311)
    try:
        node.start()
        node.rpc("createwallet", "w")
        addr = node.rpc("getnewaddress", "", "bech32", wallet="w")
        other = node.rpc("getnewaddress", "", "bech32", wallet="w")
        t0 = time.time()
        node.rpc("generatetoaddress", 120, addr)  # past COINBASE_MATURITY
        print(f"[1] mining {BLOCKS} blocks with fees and tickets (maturity + soak)")
        for i in range(BLOCKS):
            if i % 4 == 0:
                node.rpc("sendtoaddress", other, 0.5, wallet="w")
            if i % 5 == 0:
                node.rpc("generateperticket", addr)
            node.rpc("generatetoaddress", 1, addr)
            if i == BLOCKS // 2:
                # A restart in the middle: the watcher must pick up where it left off.
                node.stop()
                node.start()
                node.rpc("loadwallet", "w")
        wait_for(lambda: node.rpc("getrawmempool") == [], 120, "mempool drained")
        tip = node.rpc("getbestblockhash")
        height = node.rpc("getblockcount")
        check(height == 120 + BLOCKS, f"soak chain reached height {height} ({time.time() - t0:.0f}s)")

        print("[2] the invariant watcher on the full chain")
        r = run_watcher(node)
        check(r.returncode == 0, "the watcher exits 0 on a healthy chain"
              + ("" if r.returncode == 0 else f" (stderr: {r.stderr.strip()[-300:]})"))
        check("[ok] height" in r.stdout, "the watcher re-derived the chain to the tip"
              + ("" if "[ok] height" in r.stdout else f" (stderr: {r.stderr.strip()[-300:]})"))
        with open(STATE) as f:
            state = json.load(f)
        check(state["height"] == height and state["hash"] == tip, "the watcher checkpoint is at the node's tip")
        check(state.get("checkpoint") is not None, "a checkpoint was written (needed for a deep re-org rewind)")

        print("[3] re-org: the watcher rewinds to its checkpoint and re-walks")
        fork = height - 5
        node.rpc("invalidateblock", node.rpc("getblockhash", fork + 1))
        node.rpc("generatetoaddress", 10, addr)
        new_tip = node.rpc("getbestblockhash")
        r2 = run_watcher(node)
        check(r2.returncode == 0, "the watcher exits 0 after the re-org (no false alarm)")
        check("re-org detected" in r2.stdout, "the watcher detected the re-org")
        check("rewinding to checkpoint" in r2.stdout,
              "the rewind used the checkpoint instead of re-walking from genesis")
        with open(STATE) as f:
            state2 = json.load(f)
        check(state2["height"] == node.rpc("getblockcount") and state2["hash"] == new_tip,
              "the watcher state follows the new chain to its tip")

        print(f"\nSOAK CHECKS PASSED ({height} blocks, watcher output: {len(r.stdout.splitlines())} lines)")
        return 0
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"\nFAILED: {e}")
        return 1
    finally:
        node.stop()
        shutil.rmtree(ft.BASE, ignore_errors=True)
        if os.path.exists(STATE):
            os.remove(STATE)


if __name__ == "__main__":
    sys.exit(main())
