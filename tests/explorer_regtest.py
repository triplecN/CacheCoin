#!/usr/bin/env python3
"""
CacheCoin block explorer test (regtest, one real cachecoind node + explorer/app.py).

  1. the explorer indexes every block with the node's hashes
  2. circulating supply == gettxoutsetinfo (half of every fee held for the PER reservoir), address balance == scantxoutset
  3. a re-org is followed (rollback + re-index), also a deep re-org while it is still indexing
  4. only the explorer's own files are served; RPC errors are not reported as "node not reachable"

Runs a copy of explorer/ under /tmp, so explorer.db is never written into the repository.
Standard library only; never touches ~/.cachecoin and never runs mainnet.

Usage: python3 tests/explorer_regtest.py [path/to/cachecoind]
"""
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import functional_regtest as ft  # noqa: E402

NODE = sys.argv[1] if len(sys.argv) > 1 else "cachecoind"
ft.BITCOIND = NODE
ft.BASE = "/tmp/cachecoin-explorer-test"
EXP_DIR = "/tmp/cachecoin-explorer-copy"
HTTP_PORT = 39881
COIN = 100_000_000


def api(path):
    with urllib.request.urlopen(f"http://127.0.0.1:{HTTP_PORT}{path}", timeout=10) as r:
        return r.status, r.read()


def api_json(path):
    try:
        status, body = api(path)
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")
    return status, json.loads(body)


def consistent(node):
    """Every stored block hash equals the node's, and the height matches."""
    _, info = api_json("/api/info")
    if info["best_height"] != node.rpc("getblockcount"):
        return False
    import sqlite3
    conn = sqlite3.connect(os.path.join(EXP_DIR, "explorer.db"))
    rows = conn.execute("SELECT height, hash FROM blocks ORDER BY height").fetchall()
    conn.close()
    if len(rows) != node.rpc("getblockcount") + 1:
        return False
    return all(node.rpc("getblockhash", h) == bh for h, bh in rows)


def main():
    shutil.rmtree(ft.BASE, ignore_errors=True)
    shutil.rmtree(EXP_DIR, ignore_errors=True)
    shutil.copytree(os.path.join(HERE, "..", "explorer"), EXP_DIR,
                    ignore=shutil.ignore_patterns("explorer.db*", "__pycache__"))
    a = ft.Node("node_e", 39131, 39231)
    # cookie auth only (the explorer reads the cookie like on a real node)
    open(os.path.join(a.datadir, "cachecoin.conf"), "w").write("")
    exp = None
    try:
        a.rpc = _cookie_rpc(a)
        a.start()
        a.rpc("createwallet", "w")
        addr = a.rpc("getnewaddress", "", "bech32", wallet="w")
        other = a.rpc("getnewaddress", "", "bech32", wallet="w")
        a.rpc("generatetoaddress", 110, addr)
        for i in range(5):
            a.rpc("sendtoaddress", other, 1.5 + i, wallet="w")
        a.rpc("generatetoaddress", 1, addr)
        env = dict(os.environ, CACHECOIN_RPC_PORT=str(a.rpc_port),
                   CACHECOIN_RPC_COOKIE=os.path.join(a.datadir, "regtest", ".cookie"),
                   EXPLORER_HTTP_PORT=str(HTTP_PORT))
        exp = subprocess.Popen([sys.executable, os.path.join(EXP_DIR, "app.py")], env=env,
                               stdout=subprocess.DEVNULL, stderr=open("/tmp/explorer-test.log", "w"))
        ft.wait_for(lambda: _up() and consistent(a), 60, "explorer indexed the chain")
        ft.check(True, "explorer indexed all blocks with the node's hashes")

        def supply_matches():
            _, info = api_json("/api/info")
            utxo = a.rpc("gettxoutsetinfo")["total_amount"]
            return round(info["circulating_supply_cccn"] * COIN) == round(utxo * COIN)
        ft.check(supply_matches(), "circulating supply == gettxoutsetinfo total (fees held for the reservoir, none burned)")
        _, bal = api_json(f"/api/address/{other}")
        scan = a.rpc("scantxoutset", "start", [f"addr({other})"])["total_amount"]
        ft.check(bal["balance_sats"] == round(scan * COIN), "address balance == scantxoutset")

        print("[re-org]")
        h = a.rpc("getblockcount")
        a.rpc("invalidateblock", a.rpc("getblockhash", h - 2))
        a.rpc("generatetoaddress", 4, other)
        ft.wait_for(lambda: consistent(a) and supply_matches(), 60, "explorer followed the re-org")
        ft.check(True, "explorer rolled back 3 blocks and indexed the new branch; supply still matches")

        print("[re-org while indexing]")
        a.rpc("generatetoaddress", 300, addr)
        time.sleep(0.5)  # the explorer is now indexing the 300 new blocks
        h = a.rpc("getblockcount")
        a.rpc("invalidateblock", a.rpc("getblockhash", h - 250))
        a.rpc("generatetoaddress", 260, other)
        ft.wait_for(lambda: consistent(a) and supply_matches(), 180, "explorer consistent after a re-org during indexing")
        ft.check(True, "after a deep re-org during indexing every stored block matches the node and supply matches")

        print("[static files and errors]")
        status, body = api("/logo.svg")
        ft.check(status == 200 and body.lstrip().startswith(b"<svg"), "/logo.svg is served")
        status, body = api("/../../../../etc/passwd")
        ft.check(status == 200 and b"<html" in body.lower(), "any other path returns the page itself, no file probing")
        status, j = api_json("/api/block/99999999")
        ft.check(status == 404, "unknown block -> 404 JSON")

        print("[host header]")
        def host_status(host, path="/api/info", method=None):
            req = urllib.request.Request(f"http://127.0.0.1:{HTTP_PORT}{path}",
                                         headers={"Host": host}, method=method)
            try:
                with urllib.request.urlopen(req, timeout=10) as r:
                    return r.status
            except urllib.error.HTTPError as e:
                return e.code
        ft.check(host_status("127.0.0.1") == 200, "the loopback Host is served")
        ft.check(host_status("evil.com") == 421, "a foreign Host is refused")
        ft.check(host_status("127.0.0.1.nip.io") == 421,
                 "a name that only starts with 127. is refused (DNS rebinding)")
        ft.check(host_status("evil.com", path="/index.html", method="HEAD") == 421,
                 "HEAD is checked too")

        log = open("/tmp/explorer-test.log").read()
        ft.check("node not reachable" not in log, "RPC errors were never reported as 'node not reachable'")
        print("\nEXPLORER CHECKS PASSED")
        return 0
    except Exception as e:
        print(f"\nFAILED: {e}")
        print(open("/tmp/explorer-test.log").read()[-3000:])
        return 1
    finally:
        if exp:
            exp.terminate()
        a.stop()


def _up():
    try:
        return api_json("/api/info")[0] == 200
    except Exception:
        return False


def _cookie_rpc(node):
    import base64
    import urllib.error

    def rpc(method, *params, wallet=None):
        url = f"http://127.0.0.1:{node.rpc_port}/" + (f"wallet/{wallet}" if wallet else "")
        cookie = open(os.path.join(node.datadir, "regtest", ".cookie")).read().strip()
        body = json.dumps({"jsonrpc": "1.0", "id": "t", "method": method, "params": list(params)}).encode()
        req = urllib.request.Request(url, data=body, headers={"Authorization": "Basic " + base64.b64encode(cookie.encode()).decode()})
        try:
            with urllib.request.urlopen(req, timeout=600) as resp:
                data = json.loads(resp.read())
        except urllib.error.HTTPError as e:
            data = json.loads(e.read() or b"{}")
            if not data:
                raise
        if data.get("error"):
            raise RuntimeError(f"{method}: {data['error']}")
        return data["result"]
    return rpc


if __name__ == "__main__":
    sys.exit(main())
