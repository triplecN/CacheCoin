#!/usr/bin/env python3
"""
CacheCoin P2P anti-DoS test (regtest, one real cachecoind node and a raw P2P client).

RandomX makes each proof-of-work check cost milliseconds instead of Bitcoin's microseconds,
so the node must not hash data it has already validated, or data it would reject anyway:
  1. 3 x 200 already-known headers are processed quickly (no RandomX per header)
  2. 400 replays of known blocks (genesis included) are processed quickly
  3. the replaying peer is not disconnected (valid data is not punished)
  4. unrequested blocks with an unknown parent, or with far too little work, are dropped
     without any RandomX hash (same outcome as Bitcoin Core: missing-prev / low-work)
  5-7. a header with invalid proof of work, sent in a headers, block or cmpctblock message,
     gets the peer disconnected

Standard library only. Uses a throw-away datadir under /tmp and non-default ports, never
touches ~/.cachecoin, and never runs mainnet.

Usage: python3 tests/p2p_dos_regtest.py [path/to/cachecoind]
"""

import base64
import hashlib
import json
import os
import random
import shutil
import socket
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request

BITCOIND = sys.argv[1] if len(sys.argv) > 1 else "cachecoind"
# Unique per run. A fixed path made this suite flaky: a node left over from an
# earlier run still held the fixed P2P and RPC ports below, so the new one could
# not bind them and the run failed in a way that looked like a real defect.
BASE = f"/tmp/cachecoin-p2p-dos-{os.getpid()}"
P2P_PORT, RPC_PORT = 39111, 39211
RPC_USER, RPC_PASS = "dostest", "dos-test-only"
REGTEST_MAGIC = bytes.fromhex("fabfb5da")
REGTEST_BITS = 0x207FFFFF
COIN = 100_000_000


def sha256d(data):
    return hashlib.sha256(hashlib.sha256(data).digest()).digest()


def compact_size(n):
    if n < 253:
        return bytes([n])
    if n <= 0xFFFF:
        return b"\xfd" + struct.pack("<H", n)
    return b"\xfe" + struct.pack("<I", n)


def rpc_at(port, method, *params):
    body = json.dumps({"jsonrpc": "1.0", "id": "t", "method": method, "params": list(params)}).encode()
    auth = base64.b64encode(f"{RPC_USER}:{RPC_PASS}".encode()).decode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}/", data=body,
                                 headers={"Authorization": f"Basic {auth}", "Content-Type": "application/json"})
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


def rpc(method, *params):
    return rpc_at(RPC_PORT, method, *params)


class Peer:
    """Minimal Bitcoin P2P client: handshake, send messages, ping round-trip."""

    def __init__(self):
        self.sock = socket.create_connection(("127.0.0.1", P2P_PORT), timeout=30)
        self.buf = b""

    def send(self, command, payload=b""):
        header = REGTEST_MAGIC + command.encode().ljust(12, b"\x00") + struct.pack("<I", len(payload)) + sha256d(payload)[:4]
        self.sock.sendall(header + payload)

    def _read(self, n, timeout):
        self.sock.settimeout(timeout)
        while len(self.buf) < n:
            chunk = self.sock.recv(1 << 16)
            if not chunk:
                raise ConnectionError("connection closed by the node")
            self.buf += chunk

    def recv(self, timeout=60):
        self._read(24, timeout)
        length = struct.unpack("<I", self.buf[16:20])[0]
        self._read(24 + length, timeout)
        command = self.buf[4:16].rstrip(b"\x00").decode()
        payload = self.buf[24:24 + length]
        self.buf = self.buf[24 + length:]
        if command == "ping":
            self.send("pong", payload)
        return command, payload

    def handshake(self):
        addr = struct.pack("<Q", 0) + b"\x00" * 10 + b"\xff\xff" + bytes([127, 0, 0, 1]) + struct.pack(">H", 0)
        version = (struct.pack("<iQq", 70016, 0, int(time.time())) + addr + addr
                   + struct.pack("<Q", random.getrandbits(64)) + b"\x00" + struct.pack("<i", 0) + b"\x00")
        self.send("version", version)
        got_version = got_verack = False
        while not (got_version and got_verack):
            command, _ = self.recv()
            if command == "version":
                got_version = True
                self.send("verack")
            elif command == "verack":
                got_verack = True

    def sync_ping(self, timeout=300):
        """Send a ping and wait for its pong: the node handles one peer's messages in order,
        so this returns once everything sent before it has been processed."""
        nonce = random.getrandbits(64)
        self.send("ping", struct.pack("<Q", nonce))
        while True:
            command, payload = self.recv(timeout)
            if command == "pong" and struct.unpack("<Q", payload)[0] == nonce:
                return


def check(cond, msg):
    if not cond:
        raise AssertionError(msg)
    print(f"  PASS  {msg}")


def log_text():
    with open(os.path.join(BASE, "regtest", "debug.log"), errors="replace") as f:
        return f.read()


def script_num(n):
    out = bytearray()
    while n:
        out.append(n & 0xFF)
        n >>= 8
    if out and out[-1] & 0x80:
        out.append(0)
    return bytes(out)


def coinbase_tx(height, value, tag):
    """Coinbase-only transaction with the BIP34 height push (height > 16) and one OP_TRUE output."""
    script_sig = bytes([len(script_num(height))]) + script_num(height) + bytes([len(tag)]) + tag
    return (struct.pack("<i", 2) + b"\x01" + b"\x00" * 32 + b"\xff\xff\xff\xff"
            + bytes([len(script_sig)]) + script_sig + b"\xff\xff\xff\xff"
            + b"\x01" + struct.pack("<q", value) + b"\x01\x51" + struct.pack("<I", 0))


def header_bytes(prev, merkle, ntime, nonce):
    prev_raw = bytes.fromhex(prev)[::-1] if isinstance(prev, str) else prev
    return struct.pack("<i", 0x20000000) + prev_raw + merkle + struct.pack("<III", ntime, REGTEST_BITS, nonce)


def block_bytes(prev, height, ntime, nonce, tag):
    cb = coinbase_tx(height, 5 * COIN, tag)
    return header_bytes(prev, sha256d(cb), ntime, nonce) + b"\x01" + cb


def find_bad_pow_header(prev_hex, merkle, ntime):
    """A header on prev_hex whose RandomX proof of work fails, found with submitheader
    (headers that pass become known headers; the next nonce is tried)."""
    for nonce in range(200):
        header = header_bytes(prev_hex, merkle, ntime, nonce)
        try:
            rpc("submitheader", header.hex())
        except RuntimeError as e:
            if "high-hash" in str(e):
                return header
            raise
    return None


def disconnected(peer):
    try:
        peer.sync_ping(timeout=30)
        return False
    except (ConnectionError, OSError):
        return True


def main():
    shutil.rmtree(BASE, ignore_errors=True)
    os.makedirs(BASE)
    with open(os.path.join(BASE, "cachecoin.conf"), "w") as f:
        f.write(f"rpcuser={RPC_USER}\nrpcpassword={RPC_PASS}\n")
    proc = subprocess.Popen([BITCOIND, "-regtest", f"-datadir={BASE}", f"-port={P2P_PORT}", f"-rpcport={RPC_PORT}",
                             "-listen=1", "-bind=127.0.0.1", "-connect=0", "-dnsseed=0", "-fixedseeds=0",
                             "-discover=0", "-natpmp=0", "-debug=net", "-printtoconsole=0"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        end = time.time() + 90
        while True:
            try:
                rpc("getblockcount")
                break
            except Exception:
                if proc.poll() is not None or time.time() > end:
                    raise RuntimeError("node did not start: " + proc.stderr.read().decode()[-2000:])
                time.sleep(0.25)
        descriptor = rpc("getdescriptorinfo", "raw(51)")["descriptor"]
        rpc("generatetodescriptor", 200, descriptor)
        hashes = [rpc("getblockhash", h) for h in range(0, 201)]
        headers = [bytes.fromhex(rpc("getblockheader", h, False)) for h in hashes[1:]]
        genesis = bytes.fromhex(rpc("getblock", hashes[0], 0))
        block10 = bytes.fromhex(rpc("getblock", hashes[10], 0))

        peer = Peer()
        peer.handshake()
        peer.sync_ping()

        print("[1] replayed known headers are cheap")
        payload = compact_size(len(headers)) + b"".join(h + b"\x00" for h in headers)
        t0 = time.time()
        for _ in range(3):
            peer.send("headers", payload)
        peer.sync_ping()
        elapsed = time.time() - t0
        check(elapsed < 3.0, f"600 known headers processed in {elapsed:.2f}s (one RandomX hash each would take ~15s)")

        print("[2] replayed known blocks are cheap")
        t0 = time.time()
        for _ in range(200):
            peer.send("block", genesis)
            peer.send("block", block10)
        peer.sync_ping()
        elapsed = time.time() - t0
        check(elapsed < 3.0, f"400 known blocks (genesis included) processed in {elapsed:.2f}s (one RandomX hash each would take ~10s)")

        print("[3] valid replays are not punished")
        check(len(rpc("getpeerinfo")) == 1, "the replaying peer is still connected")

        tip = rpc("getblockheader", hashes[-1])
        print("[4] unrequested blocks that would be rejected anyway are dropped before any RandomX hash")
        hashed_before = log_text().count("high-hash")
        # From v28 upstream removed DISCOURAGEMENT_THRESHOLD: Misbehaving() no longer
        # accumulates points, one call sets m_should_discourage and the peer is dropped
        # immediately. A block with an unknown parent is therefore enough on its own, and
        # the low-work case needs a fresh connection because the first one is gone.
        peer = Peer()
        peer.handshake()
        peer.send("block", block_bytes(os.urandom(32), 1000, int(time.time()), 0, b"orphan0"))
        check(disconnected(peer), "a block with an unknown parent is dropped as missing-prev")
        check("block with unknown parent" in log_text(), "and logged why")

        peer = Peer()
        peer.handshake()
        # Build the low-work block with a nonce whose RandomX proof of work fails,
        # found before the count below is taken. With a fixed nonce the header can
        # happen to pass the regtest target, and a hash-before-drop regression
        # would leave no high-hash line and pass vacuously. A guaranteed-bad
        # header makes the count meaningful in every run.
        cb_low = coinbase_tx(1, 5 * COIN, b"lowwork")
        bad_low = find_bad_pow_header(hashes[0], sha256d(cb_low), tip["time"] + 1)
        check(bad_low is not None, "found a low-work header whose RandomX proof of work fails")
        hashed_before = log_text().count("high-hash")
        low_work = bad_low + b"\x01" + cb_low  # forks off genesis: far below the anti-DoS work
        peer.send("block", low_work)
        peer.sync_ping()
        log = log_text()
        check("Ignoring low-work unrequested block" in log, "a low-work block forking off genesis is ignored")
        check(log.count("high-hash") == hashed_before, "none of them was RandomX-hashed")
        check(not disconnected(peer), "and the peer is not punished for that one")
        try:
            rpc("getblockheader", sha256d(low_work[:80])[::-1].hex())
            stored = True
        except RuntimeError:
            stored = False
        check(not stored, "the low-work block was not stored")

        print("[5] invalid proof of work gets the peer disconnected")
        bad = find_bad_pow_header(hashes[-1], os.urandom(32), tip["time"] + 1)
        check(bad is not None, "found a header whose RandomX proof of work fails (checked with submitheader)")
        peer.send("headers", compact_size(1) + bad + b"\x00")
        check(disconnected(peer), "headers message with it: the node disconnected the peer")
        check("header with invalid proof of work" in log_text(), "and logged why")

        print("[6] unrequested block with invalid proof of work (hashed outside cs_main)")
        cb = coinbase_tx(201, 5 * COIN, b"badblock")
        bad = find_bad_pow_header(hashes[-1], sha256d(cb), tip["time"] + 1)
        peer = Peer()
        peer.handshake()
        peer.send("block", bad + b"\x01" + cb)
        check(disconnected(peer), "block message with it: the node disconnected the peer")
        check("block with invalid proof of work" in log_text(), "and logged why")

        print("[7] compact block with invalid proof of work (hashed outside cs_main)")
        cb = coinbase_tx(201, 5 * COIN, b"badcmpct")
        bad = find_bad_pow_header(hashes[-1], sha256d(cb), tip["time"] + 1)
        peer = Peer()
        peer.handshake()
        # BIP152 cmpctblock: header, nonce, no short ids, one prefilled transaction (the coinbase)
        peer.send("cmpctblock", bad + struct.pack("<Q", 1) + compact_size(0) + compact_size(1) + compact_size(0) + cb)
        check(disconnected(peer), "cmpctblock with it: the node disconnected the peer")
        check("invalid header via cmpctblock" in log_text(), "and logged why")

        print("[8] unconnecting valid headers are not RandomX-hashed")
        # A second, isolated node mines an independent chain. Its headers connect
        # to nothing this node knows, so before the fix every one of them was
        # hashed and then discarded as an unconnecting announcement.
        base_b = BASE + "-b"
        shutil.rmtree(base_b, ignore_errors=True)
        os.makedirs(base_b)
        with open(os.path.join(base_b, "cachecoin.conf"), "w") as f:
            f.write(f"rpcuser={RPC_USER}\nrpcpassword={RPC_PASS}\n")
        proc_b = subprocess.Popen([BITCOIND, "-regtest", f"-datadir={base_b}",
                                   f"-port={P2P_PORT + 1}", f"-rpcport={RPC_PORT + 1}",
                                   "-listen=0", "-connect=0", "-dnsseed=0", "-fixedseeds=0",
                                   "-discover=0", "-natpmp=0", "-printtoconsole=0"],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            end_b = time.time() + 90
            while True:
                try:
                    rpc_at(RPC_PORT + 1, "getblockcount")
                    break
                except Exception:
                    if proc_b.poll() is not None or time.time() > end_b:
                        raise RuntimeError("node B did not start: " + proc_b.stderr.read().decode()[-2000:])
                    time.sleep(0.25)
            descriptor_b = rpc_at(RPC_PORT + 1, "getdescriptorinfo", "raw(51)")["descriptor"]
            rpc_at(RPC_PORT + 1, "generatetodescriptor", 200, descriptor_b)
            # Each CBlockHeader on the wire is the 80-byte header plus its tx
            # count (0) as a CompactSize, exactly as test [1] builds its payload.
            b_headers = b"".join(
                bytes.fromhex(rpc_at(RPC_PORT + 1, "getblockheader", rpc_at(RPC_PORT + 1, "getblockhash", h), False)) + b"\x00"
                for h in range(2, 201))
            peer = Peer()
            peer.handshake()
            t0 = time.time()
            peer.send("headers", compact_size(len(b_headers) // 81) + b_headers)
            peer.sync_ping(timeout=60)
            elapsed = time.time() - t0
            check(elapsed < 2.0, f"199 unconnecting valid headers processed in {elapsed:.2f}s without hashing")
            check(len(rpc("getpeerinfo")) >= 1, "the peer is still connected")
            last_hash = sha256d(b_headers[-81:-1])[::-1].hex()
            try:
                rpc("getblockheader", last_hash)
                stored = True
            except RuntimeError:
                stored = False
            check(not stored, "the unconnecting headers were not stored")
        finally:
            try:
                rpc_at(RPC_PORT + 1, "stop")
                proc_b.wait(timeout=60)
            except Exception:
                proc_b.kill()
            shutil.rmtree(base_b, ignore_errors=True)

        print("\nALL CHECKS PASSED")
        return 0
    except Exception as e:
        print(f"\nFAILED: {e}")
        return 1
    finally:
        try:
            rpc("stop")
            proc.wait(timeout=60)
        except Exception:
            proc.kill()


if __name__ == "__main__":
    sys.exit(main())
