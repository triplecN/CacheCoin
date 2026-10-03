#!/usr/bin/env python3
"""
CacheCoin Shunko Protocol test (regtest, four real cachecoind nodes).

  1. nodes offer BIP324 encrypted transport (v2) by default
  2. a wallet builds and signs a payment without broadcasting it (send add_to_wallet=false)
  3. shunkobroadcast hands it to another node over a one-shot connection:
     the sending node never has it in its own mempool and never announces it,
     the receiving node relays it onward like any other transaction,
     and the one-shot connection is gone afterwards
  4. the payment comes back to the sender through normal relay (its wallet sees it)
  5. invalid transactions and unreachable targets are refused without sending anything
  6. auto-selected targets never include a connected peer, and rotate between calls
  7. a configured (-connect/-addnode/seed) node is never auto-selected, even
     while it is down, but an explicitly named one is still used

Standard library only. Uses throw-away datadirs under /tmp and non-default ports, never
touches ~/.cachecoin, and never runs mainnet.

Usage: python3 tests/shunko_regtest.py [path/to/cachecoind]
"""

import hashlib
import os
import shutil
import socket
import struct
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import functional_regtest as ft  # noqa: E402

ft.BITCOIND = sys.argv[1] if len(sys.argv) > 1 else "cachecoind"
ft.BASE = "/tmp/cachecoin-shunko"
check, wait_for, connect, synced = ft.check, ft.wait_for, ft.connect, ft.synced

SOCKS_PORT = 39299
# Valid v3 onion names (pubkey = sha256(seed), checksum = sha3_256(".onion checksum" | pubkey | 0x03)[:2]).
# Core validates both, so arbitrary 56-character strings are rejected before the proxy is used.
ONION_C = "bvtlknhnxfhjri54gljw6xytegnu6g5kqub6zgngshrjzrm5gx7eyqad.onion"
ONION_D = "ti4mkwg5cci6yp5izgxhqzwgx7m5hwtvyqakkv35ysli36uhed6co4qd.onion"
# Valid v3 onion that the SOCKS forwarder does not map and that nothing listens on:
# the configured target that stays in addrman while it is down.
ONION_DOWN = "pg6mmjiyjmcrsslvykfwnntlaru7p5svn6y2ymmju6nubxndf4pscryd.onion"
DEAD_ONION_PORT = 39998


class SocksForwarder:
    """Minimal SOCKS5 server that maps fake .onion names to real loopback nodes.

    The node's onion path (a proxy is required, connections are one-shot) is part
    of Shunko, so the test drives it without Tor: the node dials the fake onion
    through this proxy, and the proxy forwards to the regtest node. It accepts the
    username/password auth that Tor stream isolation sends.
    """

    def __init__(self, port, mapping):
        self.mapping = mapping
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", port))
        self.sock.listen(16)
        self.running = True
        threading.Thread(target=self._accept_loop, daemon=True).start()

    def stop(self):
        self.running = False
        try:
            self.sock.close()
        except OSError:
            pass

    def _accept_loop(self):
        while self.running:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    @staticmethod
    def _read_exact(sock, n):
        data = b""
        while len(data) < n:
            chunk = sock.recv(n - len(data))
            if not chunk:
                raise ConnectionError("socks: short read")
            data += chunk
        return data

    def _handle(self, conn):
        upstream = None
        try:
            conn.settimeout(30)
            _, nmethods = self._read_exact(conn, 2)
            methods = self._read_exact(conn, nmethods)
            if b"\x02" in methods:  # stream isolation offers username/password
                conn.sendall(b"\x05\x02")
                _, ulen = self._read_exact(conn, 2)
                self._read_exact(conn, ulen)
                plen = self._read_exact(conn, 1)[0]
                self._read_exact(conn, plen)
                conn.sendall(b"\x01\x00")
            else:
                conn.sendall(b"\x05\x00")
            _, cmd, _, atyp = self._read_exact(conn, 4)
            if cmd != 1:
                raise ConnectionError("socks: only CONNECT is supported")
            if atyp == 3:
                host = self._read_exact(conn, self._read_exact(conn, 1)[0]).decode()
            elif atyp == 1:
                host = socket.inet_ntoa(self._read_exact(conn, 4))
            else:
                host = socket.inet_ntop(socket.AF_INET6, self._read_exact(conn, 16))
            port = struct.unpack("!H", self._read_exact(conn, 2))[0]
            upstream = socket.create_connection(self.mapping.get(host, ("127.0.0.1", port)), timeout=30)
            conn.sendall(b"\x05\x00\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack("!H", 0))
            conn.settimeout(None)
            upstream.settimeout(None)
            threading.Thread(target=self._pipe, args=(conn, upstream), daemon=True).start()
            self._pipe(upstream, conn)
        except Exception:
            for s in (conn, upstream):
                if s is not None:
                    try:
                        s.close()
                    except OSError:
                        pass

    @staticmethod
    def _pipe(src, dst):
        try:
            while True:
                data = src.recv(65536)
                if not data:
                    break
                dst.sendall(data)
        except OSError:
            pass
        finally:
            try:
                dst.shutdown(socket.SHUT_WR)
            except OSError:
                pass


class FakeReceiver:
    """Accepts one Shunko hand-over: completes version/verack, reads the tx, then
    closes without answering the ping, so the sender cannot know whether the node
    processed it."""

    def __init__(self, port):
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", port))
        self.sock.listen(1)
        self.sock.settimeout(60)
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self):
        try:
            conn, _ = self.sock.accept()
            conn.settimeout(30)
            self._read_msg(conn)  # the sender's version
            conn.sendall(self._frame("version", self._version_payload()))
            conn.sendall(self._frame("verack"))
            while True:
                command, _ = self._read_msg(conn)
                if command == "tx":
                    conn.close()  # withhold the pong
                    return
        except Exception as e:
            print(f"[fake-receiver] {e!r}", file=sys.stderr)

    @staticmethod
    def _frame(command, payload=b""):
        return (b"\xfa\xbf\xb5\xda" + command.encode().ljust(12, b"\x00")
                + struct.pack("<I", len(payload))
                + hashlib.sha256(hashlib.sha256(payload).digest()).digest()[:4] + payload)

    @staticmethod
    def _version_payload():
        return (struct.pack("<iQq", 70016, 0, 0) + b"\x00" * 26 + b"\x00" * 26
                + struct.pack("<Q", 1) + b"\x00" + struct.pack("<i", 0) + b"\x00")

    @staticmethod
    def _read_msg(conn):
        header = b""
        while len(header) < 24:
            header += conn.recv(24 - len(header))
        length = struct.unpack("<I", header[16:20])[0]
        payload = b""
        while len(payload) < length:
            payload += conn.recv(length - len(payload))
        return header[4:16].rstrip(b"\x00").decode(), payload

    def stop(self):
        try:
            self.sock.close()
        except OSError:
            pass


def main():
    shutil.rmtree(ft.BASE, ignore_errors=True)
    a = ft.Node("sender", 39141, 39241)
    b = ft.Node("relay_b", 39142, 39242)
    c = ft.Node("relay_c", 39143, 39243)
    d = ft.Node("relay_d", 39144, 39244)
    cfg = ft.Node("configured", 39145, 39245)
    socks = SocksForwarder(SOCKS_PORT, {ONION_C: ("127.0.0.1", c.p2p_port),
                                        ONION_D: ("127.0.0.1", d.p2p_port)})
    a_args = ["-debug=net", "-debug=mempool", f"-onion=127.0.0.1:{SOCKS_PORT}"]
    try:
        a.start(extra_args=a_args)
        for n in (b, c):
            n.start(extra_args=["-debug=net", "-debug=mempool"])
        a.rpc("createwallet", "w")
        b.rpc("createwallet", "w")
        addr_a = a.rpc("getnewaddress", "", "bech32", wallet="w")
        addr_b = b.rpc("getnewaddress", "", "bech32", wallet="w")
        a.rpc("generatetoaddress", 110, addr_a)
        connect(a, b)
        connect(b, c)
        wait_for(lambda: synced(a, b, c), 120, "all nodes synced")

        print("[1] encrypted transport")
        check("P2P_V2" in c.rpc("getnetworkinfo")["localservicesnames"],
              "nodes offer BIP324 v2 encrypted transport by default (used with peers learned from the network)")

        print("[2] build and sign without broadcasting")
        for p in a.rpc("getpeerinfo"):  # isolate the sender only; B and C stay connected
            a.rpc("disconnectnode", "", p["id"])
        wait_for(lambda: a.rpc("getconnectioncount") == 0 and b.rpc("getconnectioncount") == 1, 30, "sender isolated")
        check(True, "the sender has no peers now; B and C are still connected")
        res = a.rpc("send", {addr_b: 1.25}, None, "unset", None, {"add_to_wallet": False, "lock_unspents": True}, wallet="w")
        check(res["complete"] and "hex" in res, "wallet signed the payment but did not broadcast it")
        txid = a.rpc("decoderawtransaction", res["hex"])["txid"]

        print("[3] shunkobroadcast: one-shot hand-over")
        out = a.rpc("shunkobroadcast", res["hex"], 1, [f"127.0.0.1:{b.p2p_port}"])
        check(out["txid"] == txid and out["delivered"] == 1, "node B processed it over a one-shot connection")
        check(txid not in a.rpc("getrawmempool"), "the sender never put it in its own mempool (it never announced it)")
        check(txid in b.rpc("getrawmempool"), "node B has it in its mempool")
        wait_for(lambda: txid in c.rpc("getrawmempool"), 60, "B relays to C")
        check(True, "node B relayed it to node C as an ordinary transaction")
        wait_for(lambda: len(b.rpc("getpeerinfo")) == 1, 30, "one-shot connection closed")
        check(True, "the one-shot connection to B is closed; B's only peer is C")

        print("[3a] a public clearnet target is refused, even with a proxy configured")
        # A configured proxy is not the same thing as a private target. -proxy applies
        # to every network, so an IPv4 address used to pass the privacy check and the
        # hand-over left through a Tor exit, which is an observer with no reason to
        # protect the sender. Loopback stays exempt because regtest has no onion
        # services to hand over to; a public address is refused on every chain.
        res_priv = a.rpc("send", {addr_b: 0.75}, None, "unset", None, {"add_to_wallet": False, "lock_unspents": True}, wallet="w")
        for bad in ["1.2.3.4:29333", "8.8.8.8:29333", "203.0.113.5:29333"]:
            try:
                a.rpc("shunkobroadcast", res_priv["hex"], 1, [bad])
                refused = False
            except RuntimeError as e:
                # Mainnet says "Shunko needs Tor"; regtest has no onion services to
                # point at, so it reports that no usable target survived the filter.
                refused = "needs Tor" in str(e) or "No known nodes" in str(e)
            check(refused, f"clearnet target {bad} is refused before anything is sent")
        print("[4] the payment reaches the sender's wallet through the chain")
        connect(a, b)
        b.rpc("generatetoaddress", 1, addr_b)
        wait_for(lambda: synced(a, b, c), 60, "block synced")

        def confirmed():
            try:
                return a.rpc("gettransaction", txid, wallet="w")["confirmations"] >= 1
            except RuntimeError:
                return False
        wait_for(confirmed, 60, "confirmed in the sender's wallet")
        check(True, "the next block confirms it and the sender's wallet records its own payment")
        check(b.rpc("getreceivedbyaddress", addr_b) == 1.25, "the receiver got exactly 1.25")

        print("[5] refusals send nothing")
        try:
            a.rpc("shunkobroadcast", res["hex"], 1, [f"127.0.0.1:{b.p2p_port}"])
            refused = False
        except RuntimeError as e:
            refused = "already" in str(e) or "missing" in str(e) or "spent" in str(e)
        check(refused, "an already-confirmed (double-spending) transaction is refused")
        res2 = a.rpc("send", {addr_b: 0.5}, None, "unset", None, {"add_to_wallet": False, "lock_unspents": True}, wallet="w")
        try:
            a.rpc("shunkobroadcast", res2["hex"], 1, ["127.0.0.1:1"])  # nothing listens there
            refused = False
        except RuntimeError as e:
            refused = "could not" in str(e).lower() or "not sent" in str(e)
        check(refused, "an unreachable target makes the RPC fail: the transaction was not sent")
        time.sleep(1)
        txid2 = a.rpc("decoderawtransaction", res2["hex"])["txid"]
        check(all(txid2 not in n.rpc("getrawmempool") for n in (a, b, c)), "and no node has that transaction")

        print("[5b] a receiver that withholds the pong reports a possible delivery")
        fake = FakeReceiver(39255)
        try:
            res3 = a.rpc("send", {addr_b: 0.15}, None, "unset", None,
                         {"add_to_wallet": False, "lock_unspents": True}, wallet="w")
            try:
                a.rpc("shunkobroadcast", res3["hex"], 1, ["127.0.0.1:39255"])
                message = ""
            except RuntimeError as e:
                message = str(e)
            check("may have been delivered" in message,
                  f"the RPC says the transaction may have been delivered ({message})")
            check("was not sent" not in message, "and it does not claim the transaction was not sent")
        finally:
            fake.stop()

        print("[6] auto-selected targets exclude connected peers and rotate")
        # The node's onion path (a proxy is required, connections are one-shot) is
        # exercised through the local SOCKS forwarder: fake .onion names map to C and
        # D, and the test-only addpeeraddress RPC seeds addrman with both. C stays
        # connected, D does not. Auto-selection must never pick C while that
        # connection is up. Two calls prove it: without the exclusion the rotation
        # would have to pick C on the second call (D cannot repeat), so C would show
        # up in the attempts.
        d.start(extra_args=["-debug=net", "-debug=mempool"])
        connect(b, d)
        wait_for(lambda: synced(b, d), 120, "D synced from B")
        addr_c = f"{ONION_C}:{c.p2p_port}"
        addr_d = f"{ONION_D}:{d.p2p_port}"
        # tried=false on purpose: addpeeraddress with tried=true calls AddrMan::Good,
        # which can fail on a tried-bucket collision (the bucket key is a random
        # per-datadir nKey), making the RPC's success flag flaky. The test only
        # needs the entries to be known to addrman, and Select() draws from the new
        # table as well.
        res = a.rpc("addpeeraddress", ONION_C, c.p2p_port, False)
        check(res["success"], "addrman accepted the onion target as a known address")
        a.rpc("addnode", addr_c, "onetry")
        wait_for(lambda: any(p["addr"] == addr_c for p in a.rpc("getpeerinfo")), 30,
                 "A connected to C through the proxy")
        check(any(p["addr"] == addr_c for p in a.rpc("getpeerinfo")),
              "the sender stays connected to C while testing")
        # The same onion service on another port is the same connected peer, so
        # exclusion must compare the network address, not IP:port. With the old
        # equality this entry would be selected and the proxy would hand the
        # transaction back to C, the peer the sender is connected to.
        res = a.rpc("addpeeraddress", ONION_C, 39999, False)
        check(res["success"], "addrman accepted a second port for the connected onion")
        r6 = a.rpc("send", {addr_b: 0.2}, None, "unset", None,
                   {"add_to_wallet": False, "lock_unspents": True}, wallet="w")
        try:
            a.rpc("shunkobroadcast", r6["hex"], 1)
            refused = False
        except RuntimeError as e:
            refused = "no proxy-reachable peer" in str(e) or "No known nodes" in str(e)
        check(refused, "another port of the connected onion is not a usable target")
        res = a.rpc("addpeeraddress", ONION_D, d.p2p_port, False)
        check(res["success"], "addrman accepted the second onion target")

        def auto_handover(amount):
            r = a.rpc("send", {addr_b: amount}, None, "unset", None,
                      {"add_to_wallet": False, "lock_unspents": True}, wallet="w")
            out = a.rpc("shunkobroadcast", r["hex"], 1)
            return out, [x["target"] for x in out["attempts"]]

        first, first_targets = auto_handover(0.4)
        second, second_targets = auto_handover(0.3)
        check(first["delivered"] == 1 and second["delivered"] == 1,
              "auto-selected onion hand-overs were delivered through the proxy")
        check(addr_c not in first_targets and addr_c not in second_targets,
              "auto-selection never hands to the connected onion peer")

        # Rotation needs two fresh targets, so drop the C connection and restart the
        # sender: addrman persists both, the in-memory recent list is empty again,
        # and the second call must then pick the target the first one did not use.
        a.stop()
        a.start(extra_args=a_args)
        a.rpc("loadwallet", "w")
        third, third_targets = auto_handover(0.4)
        fourth, fourth_targets = auto_handover(0.3)
        check(third["delivered"] == 1 and fourth["delivered"] == 1,
              "both auto-selected hand-overs were delivered")
        check(not (set(third_targets) & set(fourth_targets)),
              "rotation: the second call did not reuse the first call's target")

        print("[6b] a configured node that is down is not auto-selected")
        # F-13: -connect/-addnode/seed targets that are not currently connected stay
        # in addrman, and the automatic path could otherwise hand the transaction to
        # the home VPS and tie the one-shot connection to this node's identity.
        # This node has the dead onion as its configured target and as the only
        # addrman entry, and it has no chain, so a call can only end in "No known
        # nodes" if the configured address (the only candidate) was excluded:
        # without the exclusion the tx reaches mempool validation and fails for a
        # different reason, or delivery is attempted. The explicit path must still
        # accept the same address the user named.
        down_addr = f"{ONION_DOWN}:{DEAD_ONION_PORT}"
        cfg.start(extra_args=a_args + [f"-connect={down_addr}"])
        res = cfg.rpc("addpeeraddress", ONION_DOWN, DEAD_ONION_PORT, False)
        check(res["success"], "addrman accepted the down configured onion as a known address")
        try:
            cfg.rpc("shunkobroadcast", r6["hex"], 1)
            message = ""
        except RuntimeError as ex:
            message = str(ex)
        check("No known nodes" in message,
              f"auto-selection skipped the only candidate, the configured node ({message})")
        try:
            cfg.rpc("shunkobroadcast", r6["hex"], 1, [down_addr])
            explicit_message = ""
        except RuntimeError as ex:
            explicit_message = str(ex)
        check("No known nodes" not in explicit_message and explicit_message != "",
              f"an explicitly named configured target is still accepted for delivery ({explicit_message})")

        # The exclusion must also cover a node added at runtime with the addnode
        # RPC while it is down. GetAddedNodeInfo leaves resolvedAddress empty for
        # a disconnected node, so the configured string itself has to be
        # excluded, not only the resolved address (patch 0020).
        cfg.stop()
        cfg.start(extra_args=a_args)
        cfg.rpc("addnode", down_addr, "add")
        try:
            cfg.rpc("shunkobroadcast", r6["hex"], 1)
            runtime_message = ""
        except RuntimeError as ex:
            runtime_message = str(ex)
        check("No known nodes" in runtime_message,
              f"a runtime addnode target is excluded while down too ({runtime_message})")

        print("\nALL CHECKS PASSED")
        return 0
    except Exception as exc:
        print(f"\nFAILED: {exc}")
        return 1
    finally:
        for n in (a, b, c, d, cfg):
            n.stop()
        socks.stop()


if __name__ == "__main__":
    sys.exit(main())
