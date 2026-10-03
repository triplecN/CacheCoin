#!/usr/bin/env python3
"""
CacheCoin watcher conformance test (regtest, one real cachecoind node + tooling).

The live invariant watcher and check_supply.py are tools operators are told to
rely on; this suite proves they do not raise false alarms on valid chains and
that they actually fail when their constants are wrong.

Cases:
  1. check_supply.py --check exits 0, and exits 1 on a mutated copy
  2. the watcher parses a PUSHDATA2 ticket record (consensus accepts it)
  3. a coinbase that underpays (consensus-valid) does not alarm the watcher
  4. value burned into an OP_RETURN does not alarm the --txout supply identity

Usage: python3 tests/watcher_conformance_regtest.py [path/to/cachecoind]
"""

import hashlib
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.abspath(os.path.join(HERE, "..", "scripts")))
import functional_regtest as ft  # noqa: E402
import watch_invariants as watcher  # noqa: E402

ft.BITCOIND = sys.argv[1] if len(sys.argv) > 1 else "cachecoind"
ft.BASE = "/tmp/cachecoin-watcher-conformance"
STATE = "/tmp/cachecoin-watcher-conformance-state.json"
check, wait_for = ft.check, ft.wait_for
COIN = ft.COIN
SUPPLY = os.path.abspath(os.path.join(HERE, "..", "scripts", "check_supply.py"))


def run_watcher(node, txout=True):
    env = dict(os.environ)
    env["CACHECOIN_RPC_HOST"] = "127.0.0.1"
    env["CACHECOIN_RPC_PORT"] = str(node.rpc_port)
    env["CACHECOIN_RPC_USER"] = ft.RPC_USER
    env["CACHECOIN_RPC_PASS"] = ft.RPC_PASS
    env["WATCH_STATE"] = STATE
    args = [sys.executable, os.path.join(HERE, "..", "scripts", "watch_invariants.py")]
    if txout:
        args.append("--txout")
    return subprocess.run(args, capture_output=True, text=True, timeout=900, env=env)


def raw_tx(inputs, outputs, locktime=0, version=2):
    def varint(n):
        if n < 0xFD:
            return bytes([n])
        if n <= 0xFFFF:
            return b"\xFD" + struct.pack("<H", n)
        return b"\xFE" + struct.pack("<I", n)

    tx = struct.pack("<i", version) + varint(len(inputs))
    for txid, vout, sequence in inputs:
        tx += bytes.fromhex(txid)[::-1] + struct.pack("<I", vout) + b"\x00" + struct.pack("<I", sequence)
    tx += varint(len(outputs))
    for spk_hex, sats in outputs:
        tx += struct.pack("<q", sats) + varint(len(spk_hex) // 2) + bytes.fromhex(spk_hex)
    return (tx + struct.pack("<I", locktime)).hex()


def main():
    shutil.rmtree(ft.BASE, ignore_errors=True)
    if os.path.exists(STATE):
        os.remove(STATE)

    print("[1] check_supply.py --check fails when its constants are wrong")
    good = subprocess.run([sys.executable, SUPPLY, "--check"], capture_output=True, text=True, timeout=120)
    check(good.returncode == 0 and "CHECK PASSED" in good.stdout,
          "the schedule self-check passes and exits 0")
    with open(SUPPLY, encoding="utf-8") as f:
        source = f.read()
    mutated = source.replace("TOTAL_EMISSION = 2_102_039_986_334_400",
                             "TOTAL_EMISSION = 2_102_039_986_334_401")
    check(mutated != source, "the mutation was applied to the copy")
    with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False, encoding="utf-8") as f:
        f.write(mutated)
        mutated_path = f.name
    bad = subprocess.run([sys.executable, mutated_path, "--check"], capture_output=True, text=True, timeout=120)
    os.remove(mutated_path)
    check(bad.returncode == 1 and "CHECK FAILED" in bad.stdout,
          "a wrong total makes the self-check exit 1")

    print("[2] a PUSHDATA2 ticket record parses like a direct push")
    anchor = hashlib.sha256(b"anchor").digest()
    payout = bytes.fromhex("0014") + hashlib.sha256(b"payout").digest()[:20]
    nonce = struct.pack("<I", 42)
    body = b"PERT" + anchor + payout + nonce
    direct = b"\x6a" + bytes([len(body)]) + body
    pushdata2 = b"\x6a\x4d" + struct.pack("<H", len(body)) + body
    a, b = watcher.parse_ticket(direct.hex()), watcher.parse_ticket(pushdata2.hex())
    check(a is not None and a == b, "the PUSHDATA2 record parses to the same ticket as the direct push")

    node = ft.Node("watch", 39241, 39341)
    try:
        node.start()
        node.rpc("createwallet", "w")
        miner = node.rpc("getnewaddress", "", "bech32", wallet="w")
        node.rpc("generatetoaddress", 110, miner)

        print("[3] a coinbase that underpays does not alarm the watcher")
        tip = node.rpc("getbestblockhash")
        height = node.rpc("getblockcount")
        mediantime = node.rpc("getblockheader", tip)["mediantime"]
        ntime = max(int(time.time()) + 1, mediantime + 1)
        # Consensus rejects only overpayment; 1 sat short is a valid block.
        _, result = ft.submit_block(node, tip, height + 1, ntime, 5 * COIN - 1, b"underpay")
        check(result is None, f"the underpaying block is accepted ({result!r})")
        r = run_watcher(node)
        check(r.returncode == 0, "the watcher exits 0 on the underpaying chain"
              + ("" if r.returncode == 0 else f" (stderr: {r.stderr.strip()[-300:]})"))
        check("[ok] height" in r.stdout, "the watcher re-derived the chain")

        print("[4] burned value does not alarm the --txout identity")
        utxo = node.rpc("listunspent", 1, 9999999, [], True, {"minimumAmount": 1})[0]
        burn_spk = "6a0b68656c6c6f20776f726c64"  # OP_RETURN "hello world"
        change = node.rpc("getnewaddress", "", "bech32", wallet="w")
        change_spk = node.rpc("getaddressinfo", change)["scriptPubKey"]
        value = round(utxo["amount"] * COIN)
        tx = raw_tx([(utxo["txid"], utxo["vout"], 0xFFFFFFFE)],
                    [(burn_spk, 1000), (change_spk, value - 1000 - 2000)])
        signed = node.rpc("signrawtransactionwithwallet", tx, wallet="w")
        check(signed["complete"], "the wallet signed the burn transaction")
        node.rpc("sendrawtransaction", signed["hex"], 0, 0.001)  # allow a 1000-sat burn
        node.rpc("generatetoaddress", 1, miner)
        r = run_watcher(node)
        check(r.returncode == 0, "the watcher exits 0 with a burn in the chain"
              + ("" if r.returncode == 0 else f" (stderr: {r.stderr.strip()[-300:]})"))

        print("\nWATCHER CONFORMANCE CHECKS PASSED")
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
