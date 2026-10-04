#!/usr/bin/env python3
"""
CacheCoin mainnet smoke test - NEVER MINES.

Starts two cachecoind nodes with MAINNET parameters in throw-away datadirs, connected
only to each other on 127.0.0.1 (no DNS seeds, no fixed seeds, no discovery), and checks
what can be checked without creating a block:

  - the node starts and loads the real genesis block (and again after a restart)
  - P2P listens on the CacheCoin default port 29333
  - BIP34/65/66, CSV, SegWit and Taproot are active for the first block
  - SegWit (cccn1...) and legacy (C...) mainnet addresses validate, Bitcoin ones do not
  - the template for block 1 uses powLimit (nBits 1f0fffff) and pays 5 CCCN
  - shunkobroadcast refuses to send without Tor
  - a key from scripts/keygen.py is accepted by the node (WIF version byte) and the node
    derives the same SegWit and legacy addresses from it

The test addresses are derived here from a fixed string (nobody holds their keys); no
real address is hard-coded. The keygen key is a throw-away key that is never printed.

Usage: python3 tests/mainnet_smoke.py [path/to/cachecoind]
"""

import base64
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

BITCOIND = sys.argv[1] if len(sys.argv) > 1 else "cachecoind"
BASE = "/tmp/cachecoin-mainnet-smoke"
USER, PASS = "smoke", "smoke-test-only"
GENESIS = "1bc3387d50988b4b653389516f1d2b3672cffef48f124a3b8ff7b1ac3c1e3efa"
FORBIDDEN = {"generatetoaddress", "generateblock", "generatetodescriptor", "submitblock", "generate"}


def bech32_address(hrp, witver, program):
    """BIP173 bech32 encoding of a v0 witness program."""
    charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

    def polymod(values):
        gen = [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]
        chk = 1
        for v in values:
            top = chk >> 25
            chk = (chk & 0x1FFFFFF) << 5 ^ v
            for i in range(5):
                chk ^= gen[i] if ((top >> i) & 1) else 0
        return chk

    acc, bits, data = 0, 0, [witver]
    for b in program:
        acc = (acc << 8) | b
        bits += 8
        while bits >= 5:
            bits -= 5
            data.append((acc >> bits) & 31)
    if bits:
        data.append((acc << (5 - bits)) & 31)
    expanded = [ord(c) >> 5 for c in hrp] + [0] + [ord(c) & 31 for c in hrp]
    mod = polymod(expanded + data + [0] * 6) ^ 1
    checksum = [(mod >> 5 * (5 - i)) & 31 for i in range(6)]
    return hrp + "1" + "".join(charset[d] for d in data + checksum)


def base58check(version, payload):
    alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    raw = bytes([version]) + payload
    raw += hashlib.sha256(hashlib.sha256(raw).digest()).digest()[:4]
    n, out = int.from_bytes(raw, "big"), ""
    while n:
        n, r = divmod(n, 58)
        out = alphabet[r] + out
    return "1" * (len(raw) - len(raw.lstrip(b"\x00"))) + out


# A 20-byte hash nobody has a key for, as a P2WPKH (cccn1q...) and a P2PKH (version 28, C...) address.
TEST_HASH160 = hashlib.sha256(b"CacheCoin mainnet smoke test address").digest()[:20]
SEGWIT_ADDR = bech32_address("cccn", 0, TEST_HASH160)
LEGACY_ADDR = base58check(28, TEST_HASH160)


class Node:
    def __init__(self, name, rpc_port, p2p_port=None):
        self.name, self.rpc_port, self.p2p_port = name, rpc_port, p2p_port
        self.datadir = os.path.join(BASE, name)
        os.makedirs(self.datadir, mode=0o700, exist_ok=True)
        conf_path = os.path.join(self.datadir, "cachecoin.conf")
        with open(conf_path, "w") as f:
            f.write(f"rpcuser={USER}\nrpcpassword={PASS}\n")
        os.chmod(conf_path, 0o600)
        self.proc = None

    def start(self):
        bind = "-bind=127.0.0.1" if self.p2p_port is None else f"-bind=127.0.0.1:{self.p2p_port}"
        # -rpcdoccheck makes every RPC result in this suite prove that its keys
        # are declared in the help, so a CacheCoin RPC that grows an undeclared
        # field fails here instead of breaking tooling silently.
        args = [BITCOIND, f"-datadir={self.datadir}", f"-rpcport={self.rpc_port}", "-rpcbind=127.0.0.1", "-rpcallowip=127.0.0.1", "-listen=1", bind,
                "-connect=0", "-dnsseed=0", "-fixedseeds=0", "-discover=0", "-natpmp=0",
                "-listenonion=0", "-maxtipage=2000000000", "-rpcdoccheck=1", "-printtoconsole=0"]
        self.proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        end = time.time() + 120
        while time.time() < end:
            if self.proc.poll() is not None:
                raise RuntimeError(f"{self.name} exited: {self.proc.stderr.read().decode()[-1500:]}")
            try:
                self.rpc("getblockcount")
                return
            except Exception:
                time.sleep(0.3)
        tail = ""
        try:
            with open(os.path.join(self.datadir, "debug.log"), errors="replace") as f:
                tail = f.read()[-2000:]
        except OSError:
            pass
        listeners = ""
        try:
            listeners = subprocess.run(["ss", "-ltnp"], capture_output=True, text=True, timeout=10).stdout
        except Exception:
            pass
        raise RuntimeError(f"{self.name} did not start (exit={self.proc.poll()}); debug.log tail:\n{tail}\nlisteners:\n{listeners}")

    def stop(self):
        if self.proc and self.proc.poll() is None:
            try:
                self.rpc("stop")
                self.proc.wait(timeout=60)
            except Exception:
                self.proc.kill()

    def rpc(self, method, *params):
        if method in FORBIDDEN:
            raise RuntimeError(f"refusing to call {method} on mainnet")
        body = json.dumps({"jsonrpc": "1.0", "id": 1, "method": method, "params": list(params)}).encode()
        auth = base64.b64encode(f"{USER}:{PASS}".encode()).decode()
        req = urllib.request.Request(f"http://127.0.0.1:{self.rpc_port}/", data=body, headers={"Authorization": f"Basic {auth}"})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                data = json.loads(r.read())
        except urllib.error.HTTPError as e:
            data = json.loads(e.read() or b"{}")
        if data.get("error"):
            raise RuntimeError(f"{self.name}.{method}: {data['error']}")
        return data["result"]


def check(cond, msg):
    if not cond:
        raise AssertionError(msg)
    print(f"  PASS  {msg}")


def listening_ports():
    out = subprocess.run(["ss", "-ltnH"], capture_output=True, text=True).stdout
    return out


def main():
    shutil.rmtree(BASE, ignore_errors=True)
    a = Node("main_a", 39701)            # default P2P port (29333) on 127.0.0.1
    b = Node("main_b", 39702, 39703)
    try:
        print("[1] startup on mainnet parameters")
        a.start()
        info = a.rpc("getblockchaininfo")
        check(info["chain"] == "main" and info["blocks"] == 0, "node runs on mainnet at height 0")
        check(a.rpc("getblockhash", 0) == GENESIS, f"genesis hash {GENESIS[:16]}...")
        check("127.0.0.1:29333" in listening_ports(), "P2P listens on the default CacheCoin port 29333")

        print("[2] restart")
        a.stop()
        a.start()
        check(a.rpc("getblockhash", 0) == GENESIS and a.rpc("getblockcount") == 0, "restart reloads the genesis block")

        print("[3] soft forks active for block 1")
        dep = a.rpc("getdeploymentinfo")["deployments"]
        for name in ("bip34", "bip65", "bip66", "csv", "segwit", "taproot"):
            check(dep[name]["active"] is True, f"{name} active")

        print("[4] addresses")
        v = a.rpc("validateaddress", SEGWIT_ADDR)
        check(v["isvalid"] and v.get("iswitness") and v.get("witness_version") == 0, f"SegWit address {SEGWIT_ADDR[:9]}... is a valid v0 witness address")
        check(v["scriptPubKey"] == "0014" + TEST_HASH160.hex(), "and encodes the expected witness program")
        v = a.rpc("validateaddress", LEGACY_ADDR)
        check(v["isvalid"] and v["scriptPubKey"] == "76a914" + TEST_HASH160.hex() + "88ac", f"legacy address {LEGACY_ADDR[:3]}... (version 28) is a valid P2PKH address")
        check(not a.rpc("validateaddress", "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq")["isvalid"], "Bitcoin addresses are rejected")

        print("[5] template for block 1 (not mined)")
        b.start()
        b.rpc("addnode", "127.0.0.1:29333", "onetry")
        end = time.time() + 30
        while time.time() < end and a.rpc("getconnectioncount") == 0:
            time.sleep(0.3)
        check(a.rpc("getconnectioncount") > 0, "two mainnet nodes connect (magic bytes / handshake)")
        t = a.rpc("getblocktemplate", {"rules": ["segwit"]})
        check(t["height"] == 1, "template height 1")
        check(t["bits"] == "1f0fffff", f"block 1 difficulty = powLimit (bits {t['bits']})")
        check(t["coinbasevalue"] == 5 * 100_000_000, "block 1 pays 5 CCCN (warm-up reward)")
        check(t["previousblockhash"] == GENESIS, "template builds on the genesis block")

        print("[6] Shunko refuses to send without Tor on mainnet")
        dummy_tx = ("02000000" + "01" + "11" * 32 + "00000000" + "00" + "ffffffff"
                    + "01" + (1000).to_bytes(8, "little").hex() + "0151" + "00000000")
        try:
            a.rpc("shunkobroadcast", dummy_tx)
            refused = ""
        except RuntimeError as e:
            refused = str(e)
        check("Shunko needs Tor" in refused, "shunkobroadcast refuses when no peer is reachable through Tor (nothing sent)")

        print("[7] scripts/keygen.py output is accepted by the node")
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))
        sys.dont_write_bytecode = True   # leave no __pycache__ in scripts/
        import keygen
        keys = keygen.generate_cachecoin_keypair()   # throw-away key, never printed
        wif = keys["wif_private_key"]
        try:
            desc_w = a.rpc("getdescriptorinfo", f"wpkh({wif})")
            desc_l = a.rpc("getdescriptorinfo", f"pkh({wif})")
        except RuntimeError as e:
            raise RuntimeError(str(e).replace(wif, "<WIF>")) from None
        check(desc_w["hasprivatekeys"] and keys["public_key_hex"] in desc_w["descriptor"],
              "the node decodes keygen's WIF (version byte 156) to the same public key")
        check(a.rpc("deriveaddresses", desc_w["descriptor"]) == [keys["segwit_address"]],
              "the node derives keygen's SegWit address from that key")
        check(a.rpc("deriveaddresses", desc_l["descriptor"]) == [keys["legacy_address"]],
              "the node derives keygen's legacy address from that key")

        print("\nMAINNET SMOKE TEST PASSED (nothing was mined)")
        return 0
    except Exception as e:
        print(f"\nFAILED: {e}")
        return 1
    finally:
        a.stop()
        b.stop()
        if not os.environ.get("KEEP_DATADIRS"):
            shutil.rmtree(BASE, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
