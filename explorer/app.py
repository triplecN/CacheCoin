#!/usr/bin/env python3
"""
CacheCoin (CCCN) lightweight block explorer
-------------------------------------------
- Standard library only (http.server + sqlite3 + urllib)
- Indexes the chain of a local cachecoind over JSON-RPC into explorer.db
  (a disposable cache: delete it and it is rebuilt from the node)
- Follows re-orgs, tracks spent outputs, serves /api/* and static/index.html

Configuration (environment variables):
  CACHECOIN_RPC_HOST / CACHECOIN_RPC_PORT   default 127.0.0.1:29332
  CACHECOIN_RPC_COOKIE                      default ~/.cachecoin/.cookie
  CACHECOIN_RPC_USER / CACHECOIN_RPC_PASS   used instead of the cookie if both set
  EXPLORER_BIND / EXPLORER_HTTP_PORT        default 127.0.0.1:8080 (local only)
"""

import base64
import contextlib
import ipaddress
import json
import os
import sqlite3
import sys
import threading
import time
import urllib.error
import urllib.request
from decimal import Decimal
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(BASE_DIR, "explorer.db")
SCHEMA_PATH = os.path.join(BASE_DIR, "schema.sql")
STATIC_DIR = os.path.join(BASE_DIR, "static")

def _default_cookie_path():
    """Locate the node's RPC cookie on this platform.

    The data directory is set by patches/0007-data-directory.patch and is not
    the same on all three platforms, so a hardcoded ~/.cachecoin only works on
    Linux. Keep CACHECOIN_RPC_COOKIE as the override.
    """
    if sys.platform == "win32":
        appdata = os.environ.get("APPDATA")
        if appdata:
            return os.path.join(appdata, "CacheCoin", ".cookie")
    elif sys.platform == "darwin":
        return os.path.expanduser("~/Library/Application Support/CacheCoin/.cookie")
    return os.path.expanduser("~/.cachecoin/.cookie")


RPC_HOST = os.environ.get("CACHECOIN_RPC_HOST", "127.0.0.1")
RPC_PORT = int(os.environ.get("CACHECOIN_RPC_PORT", 29332))
RPC_COOKIE = os.environ.get("CACHECOIN_RPC_COOKIE", _default_cookie_path())
RPC_USER = os.environ.get("CACHECOIN_RPC_USER")
RPC_PASS = os.environ.get("CACHECOIN_RPC_PASS")
HTTP_BIND = os.environ.get("EXPLORER_BIND", "127.0.0.1")
HTTP_PORT = int(os.environ.get("EXPLORER_HTTP_PORT", 8080))

COIN = 100_000_000

# Hosts the explorer answers to. Binding to loopback does not stop DNS rebinding:
# a browser resolves an attacker-controlled name to 127.0.0.1, treats the result
# as same-origin and applies no cross-origin protection, so every /api/ answer
# becomes readable from that page. Only literal loopback names and addresses are
# accepted; a name that merely starts with "127." (for example 127.0.0.1.nip.io)
# is not, and neither is any other name that resolves to 127.0.0.1.
ALLOWED_HOSTS = {"127.0.0.1", "localhost", "::1", "[::1]"}


def host_is_allowed(host_header):
    """Whether a Host header names an address this explorer may answer to."""
    raw = (host_header or "").strip()
    if not raw:
        return True
    if raw.startswith("["):                      # IPv6 literal, with or without :port
        host = raw.split("]", 1)[0] + "]" if "]" in raw else raw
    else:
        host = raw.split(":", 1)[0]              # host or IPv4, with or without :port
    host = host.strip("[]").lower()
    if not host or host in ALLOWED_HOSTS:
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


# 5s memo for /api/info: the frontend polls it every 5s, but its content only
# changes when a new block is indexed, so key on tip height.
_INFO_CACHE = {"height": None, "time": 0.0, "data": None}


def log(msg):
    print(f"[explorer] {msg}", file=sys.stderr, flush=True)


def sats(value):
    if value is None:
        return 0
    # Exact decimal math: node values have at most 8 places, so str() is exact
    # and float rounding can never flip a satoshi (2.1e15 < 2^53 held anyway).
    sat = int(Decimal(str(value)) * COIN)
    # Range guard: a malformed block fails loudly at index time (and is recorded
    # in sync_state) instead of silently poisoning balances.
    if not 0 <= sat <= 21020400 * COIN:
        raise ValueError(f"satoshi value out of range: {value!r}")
    return sat


class Database:
    @staticmethod
    @contextlib.contextmanager
    def get_conn():
        conn = sqlite3.connect(DB_PATH, timeout=30.0)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL;")
        conn.execute("PRAGMA synchronous=NORMAL;")
        conn.execute("PRAGMA busy_timeout=30000;")  # same 30 s as the connect() timeout
        try:
            yield conn
        finally:
            conn.close()

    @staticmethod
    def init():
        with open(SCHEMA_PATH, "r") as f:
            schema = f.read()
        with Database.get_conn() as conn:
            conn.executescript(schema)
            conn.commit()


class NodeRPC:
    def __init__(self):
        self.url = f"http://{RPC_HOST}:{RPC_PORT}/"

    def _auth_header(self):
        if RPC_USER and RPC_PASS:
            creds = f"{RPC_USER}:{RPC_PASS}"
        else:
            # The cookie changes every time the node restarts, so read it per call.
            with open(RPC_COOKIE, "r") as f:
                creds = f.read().strip()
        return "Basic " + base64.b64encode(creds.encode()).decode()

    def call(self, method, params=None):
        payload = {"jsonrpc": "1.0", "id": "explorer", "method": method, "params": params or []}
        req = urllib.request.Request(self.url, data=json.dumps(payload).encode(), headers={
            "Content-Type": "application/json",
            "Authorization": self._auth_header(),
        })
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            # The node answers RPC errors with HTTP 500/404 and a JSON body; only a body
            # without a JSON error (e.g. 401 wrong credentials) is a transport problem.
            try:
                data = json.loads(e.read().decode())
            except ValueError:
                raise e from None
            if not isinstance(data, dict) or not data.get("error"):
                raise
        if data.get("error"):
            raise RuntimeError(f"{method}: {data['error']}")
        return data["result"]


def index_block(conn, block):
    height = block["height"]
    total_fees = sum(sats(tx.get("fee") or 0) for tx in block["tx"][1:])
    coinbase_value = sum(sats(v.get("value") or 0) for v in block["tx"][0]["vout"])
    conn.execute("""
        INSERT OR REPLACE INTO blocks
        (height, hash, prev_hash, merkle_root, timestamp, bits, nonce, difficulty, tx_count, size, total_fees, coinbase_value)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (height, block["hash"], block.get("previousblockhash", "0" * 64), block["merkleroot"],
          block["time"], block["bits"], block["nonce"], block.get("difficulty", 0), len(block["tx"]),
          block["size"], total_fees, coinbase_value))

    for tx in block["tx"]:
        is_coinbase = 1 if "coinbase" in tx["vin"][0] else 0
        conn.execute("""
            INSERT OR REPLACE INTO transactions
            (txid, block_height, block_hash, version, size, locktime, is_coinbase, total_output)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, (tx["txid"], height, block["hash"], tx["version"], tx["size"], tx["locktime"],
              is_coinbase, sum(sats(v.get("value") or 0) for v in tx["vout"])))

        if not is_coinbase:
            for vin in tx["vin"]:
                conn.execute("UPDATE tx_outputs SET spent_txid = ? WHERE txid = ? AND vout_index = ?",
                             (tx["txid"], vin["txid"], vin["vout"]))

        for vout in tx["vout"]:
            spk = vout.get("scriptPubKey", {})
            if "address" in spk:
                addr = spk["address"]
            elif spk.get("type") == "nulldata":
                addr = "OP_RETURN"
            else:
                addr = None
            conn.execute("""
                INSERT OR REPLACE INTO tx_outputs
                (txid, vout_index, value, script_pubkey, address, block_height, spent_txid)
                VALUES (?, ?, ?, ?, ?, ?, NULL)
            """, (tx["txid"], vout["n"], sats(vout.get("value") or 0), spk.get("hex", ""), addr, height))


def rollback_to(conn, fork_height):
    """Remove everything above fork_height and un-spend the outputs those blocks spent."""
    conn.execute("""
        UPDATE tx_outputs SET spent_txid = NULL
        WHERE spent_txid IN (SELECT txid FROM transactions WHERE block_height > ?)
    """, (fork_height,))
    conn.execute("DELETE FROM tx_outputs WHERE block_height > ?", (fork_height,))
    conn.execute("DELETE FROM transactions WHERE block_height > ?", (fork_height,))
    conn.execute("DELETE FROM blocks WHERE height > ?", (fork_height,))


def common_height(rpc, conn, stored_tip):
    """Highest height where the explorer and the node agree on the block hash (-1 if none).
    The stored blocks always form one linked chain (sync_worker only appends a block whose
    previousblockhash is the stored tip), so everything below that height agrees as well."""
    # Walk cap: a fork deeper than this cannot be a real re-org (consensus allows ~40
    # at most via the heal rule), so stop and let the per-block previousblockhash check
    # below catch up instead of hammering RPC — and never wipe on mere RPC errors.
    MAX_WALK = 512
    h = stored_tip
    while h >= 0:
        row = conn.execute("SELECT hash FROM blocks WHERE height = ?", (h,)).fetchone()
        try:
            node_hash = rpc.call("getblockhash", [h])
        except RuntimeError:
            node_hash = None  # node's chain is shorter than ours
        if row and node_hash == row["hash"]:
            return h
        h -= 1
        if stored_tip - h > MAX_WALK:
            # A genuinely deeper fork needs a full resync (delete explorer.db);
            # say so loudly instead of serving stale data forever.
            log(f"common_height walked {MAX_WALK} without agreement: possible deep fork, needs manual resync")
            conn.execute("INSERT OR REPLACE INTO sync_state (key, value) VALUES ('index_error', ?)",
                         ("deep-fork suspected: delete explorer.db to resync",))
            conn.commit()
            return stored_tip
    return -1


def sync_worker():
    """Continuously mirror the node's active chain into explorer.db."""
    rpc = NodeRPC()
    fail_streak = 0  # consecutive failed passes; backs off to avoid hot RPC loops
    while True:
        try:
            info = rpc.call("getblockchaininfo")
            best = info["blocks"]
            with Database.get_conn() as conn:
                conn.execute("INSERT OR REPLACE INTO sync_state (key, value) VALUES ('chain', ?)", (info["chain"],))
                # A pass that gets this far talked to the node fine: clear any
                # previously recorded indexing error (a later failure re-records it).
                conn.execute("DELETE FROM sync_state WHERE key = 'index_error'")
                conn.commit()
                row = conn.execute("SELECT MAX(height) AS h FROM blocks").fetchone()
                stored_tip = row["h"] if row["h"] is not None else -1
                if stored_tip >= 0:
                    agreed = common_height(rpc, conn, stored_tip)
                    if agreed < stored_tip:
                        log(f"re-org: rolling back from height {stored_tip} to {agreed}")
                        rollback_to(conn, agreed)
                        conn.commit()
                        stored_tip = agreed
                row = conn.execute("SELECT hash FROM blocks WHERE height = ?", (stored_tip,)).fetchone()
                prev_hash = row["hash"] if row else None
                for h in range(stored_tip + 1, best + 1):
                    block = rpc.call("getblock", [rpc.call("getblockhash", [h]), 2])
                    if h > 0 and block.get("previousblockhash") != prev_hash:
                        # The node re-orged while we were indexing: stop here, and let the next
                        # pass find the fork (common_height) and roll back cleanly.
                        log(f"re-org during sync at height {h}; restarting the pass")
                        break
                    index_block(conn, block)
                    conn.commit()
                    prev_hash = block["hash"]
        except (urllib.error.URLError, ConnectionError, OSError) as e:
            log(f"node not reachable ({e}); retrying")
        except Exception as e:  # keep the explorer alive, but never hide the reason
            log(f"sync error: {e}")
            try:
                with Database.get_conn() as conn2:
                    conn2.execute("INSERT OR REPLACE INTO sync_state (key, value) VALUES ('index_error', ?)",
                                  (type(e).__name__[:80],))
                    conn2.commit()
            except Exception:
                pass
            fail_streak += 1
        else:
            # A deep-fork warning means this pass did not recover; back off instead
            # of hammering the node with 512 getblockhash calls every few seconds.
            with Database.get_conn() as conn3:
                deep_fork = conn3.execute(
                    "SELECT value FROM sync_state WHERE key = 'index_error'").fetchone()
            fail_streak = fail_streak + 1 if deep_fork else 0
        time.sleep(min(3 * 2 ** min(fail_streak, 5), 180))


class ExplorerHandler(SimpleHTTPRequestHandler):
    # Don't advertise the Python version, and don't let a slow client pin a
    # handler thread forever (localhost default; still set a bound).
    server_version = "CacheCoinExplorer"
    sys_version = ""
    timeout = 20

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=STATIC_DIR, **kwargs)

    def log_message(self, format, *args):
        # Access logging is opt-in (env) so default runs stay quiet.
        if os.environ.get("EXPLORER_ACCESS_LOG"):
            super().log_message(format, *args)

    def end_headers(self):
        # Also covers static files served by send_head, not just send_json.
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Frame-Options", "DENY")
        super().end_headers()

    STATIC_FILES = {"/index.html", "/logo.svg"}

    def _host_allowed(self):
        """Reject a Host we would not have bound to (see host_is_allowed)."""
        if host_is_allowed(self.headers.get("Host")):
            return True
        if self.command == "HEAD":
            # A HEAD response carries no body; answer with headers only.
            self.send_response(421)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", "0")
            self.end_headers()
        else:
            self.send_json({"error": "host not allowed"}, 421)
        return False

    def do_GET(self):
        if not self._host_allowed():
            return
        if self.path.startswith("/api/"):
            self.handle_api()
        else:
            # Serve only the explorer's own files; every other path gets the page itself
            # (it routes on the client side), without probing the filesystem.
            if urlparse(self.path).path not in self.STATIC_FILES:
                self.path = "/index.html"
            super().do_GET()

    def do_HEAD(self):
        if not self._host_allowed():
            return
        if urlparse(self.path).path not in self.STATIC_FILES:
            self.path = "/index.html"
        super().do_HEAD()

    def send_json(self, data, code=200):
        body = json.dumps(data).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Security-Policy", "default-src 'none'")
        self.send_header("Connection", "close")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_api(self):
        # Corrupt/missing DB (disk full, killed mid-write) must answer 500, not
        # RST the socket. Rebuild once, then serve or fail loudly.
        try:
            return self._handle_api_inner()
        except sqlite3.Error:
            try:
                Database.init()
                return self._handle_api_inner()
            except Exception:
                return self.send_json({"error": "index temporarily unavailable"}, 500)

    def _handle_api_inner(self):
        path = urlparse(self.path).path
        with Database.get_conn() as conn:
            cur = conn.cursor()

            if path == "/api/info":
                now = time.monotonic()
                tip_h = cur.execute("SELECT MAX(height) AS h FROM blocks").fetchone()["h"]
                cached = _INFO_CACHE
                if (cached["data"] is not None and cached["height"] == tip_h
                        and now - cached["time"] < 5.0):
                    return self.send_json(cached["data"])
                # One scan of blocks: the reservoir SUM used to be a second query over
                # the same table, so every cache miss re-read the whole history twice.
                b = cur.execute("""
                    SELECT MAX(height) AS height, COUNT(*) AS n,
                           -- the genesis coinbase is never spendable, so it is not supply
                           COALESCE(SUM(CASE WHEN height > 0 THEN coinbase_value ELSE 0 END), 0) AS minted,
                           COALESCE(SUM(total_fees), 0) AS fees,
                           -- Integer math: total_fees are sats, and the consensus reservoir
                           -- share is floor(fees/2) per block, not floor(sum(fees)/2).
                           -- Both operands are SQLite INTEGERs, so total_fees / 2 is
                           -- integer division; summing the per-block halves matches the node.
                           COALESCE(SUM(total_fees / 2), 0) AS reservoir
                    FROM blocks""").fetchone()
                tx_count = cur.execute("SELECT COUNT(*) AS n FROM transactions").fetchone()["n"]
                chain_row = cur.execute("SELECT value FROM sync_state WHERE key = 'chain'").fetchone()
                err_row = cur.execute("SELECT value FROM sync_state WHERE key = 'index_error'").fetchone()
                # Coins in the UTXO set = coinbase outputs so far - all fees. Fees do not change
                # the supply: the miner's half returns immediately and the reservoir half returns
                # later as PER payout outputs (both counted in coinbase_value). Between a fee being
                # paid and its reservoir half being paid out, that half is out of the UTXO set, so
                # this equals gettxoutsetinfo's total. Nothing is burned (no coin is ever destroyed).
                circulating = max(0, b["minted"] - b["fees"])
                reservoir = b["reservoir"]
                data = {
                    "network": chain_row["value"] if chain_row else "main",
                    "ticker": "CCCN",
                    "best_height": b["height"] or 0,
                    "total_blocks": b["n"] or 0,
                    "total_transactions": tx_count,
                    "circulating_supply_cccn": circulating / COIN,
                    "cumulative_fees_to_reservoir_cccn": reservoir / COIN,
                    "supply_note": "approximate: index may lag the node during sync or re-orgs",
                    "target_spacing": 60,
                    "pow_algo": "RandomX (CPU)",
                    "max_reorg_depth": 5,
                    "index_error": err_row["value"] if err_row else None,
                }
                _INFO_CACHE.update({"height": b["height"], "time": time.monotonic(), "data": data})
                return self.send_json(data)

            elif path == "/api/blocks":
                rows = cur.execute("SELECT * FROM blocks ORDER BY height DESC LIMIT 15").fetchall()
                self.send_json([dict(r) for r in rows])

            elif path.startswith("/api/block/"):
                param = unquote(path[len("/api/block/"):].strip().rstrip("/"))
                if not param:
                    return self.send_json({"error": "Block parameter required"}, 400)
                if len(param) > 128:
                    # Hashes are 64 hex chars, heights <= 10 digits: anything
                    # longer is junk (a 1MB bind times 32 threads otherwise).
                    return self.send_json({"error": "Block not found"}, 404)
                if param.isascii() and param.isdigit():
                    # Length guard before int(): longer digit strings cannot be a
                    # height and fall through to the hash/tx/address lookups.
                    # (isdigit() alone is True for some non-ASCII numerals that
                    # int() rejects, so require ASCII first.)
                    if len(param) > 10:
                        return self.send_json({"error": "Block not found"}, 404)
                    row = cur.execute("SELECT * FROM blocks WHERE height = ?", (int(param),)).fetchone()
                else:
                    row = cur.execute("SELECT * FROM blocks WHERE hash = ?", (param,)).fetchone()
                if not row:
                    return self.send_json({"error": "Block not found"}, 404)
                block = dict(row)
                # Bounded: a full block holds tens of thousands of transactions, so an
                # unbounded query answers a short request with several megabytes. The
                # neighbouring transaction queries are already limited; this one was not.
                block["transactions"] = [dict(t) for t in cur.execute(
                    "SELECT * FROM transactions WHERE block_height = ? ORDER BY is_coinbase DESC LIMIT 2000",
                    (block["height"],))]
                block["transactions_truncated"] = cur.execute(
                    "SELECT COUNT(*) FROM transactions WHERE block_height = ?", (block["height"],)
                ).fetchone()[0] > 2000
                self.send_json(block)

            elif path.startswith("/api/tx/"):
                txid = unquote(path[len("/api/tx/"):].strip().rstrip("/"))
                if len(txid) > 128:
                    return self.send_json({"error": "Transaction not found"}, 404)
                row = cur.execute("SELECT * FROM transactions WHERE txid = ?", (txid,)).fetchone()
                if not row:
                    return self.send_json({"error": "Transaction not found"}, 404)
                tx = dict(row)
                # Bounded like /api/address: a max-weight tx could otherwise
                # materialize tens of MB of JSON per request.
                tx["outputs"] = [dict(o) for o in cur.execute(
                    "SELECT * FROM tx_outputs WHERE txid = ? ORDER BY vout_index LIMIT 20000", (txid,))]
                self.send_json(tx)

            elif path.startswith("/api/address/"):
                addr = unquote(path[len("/api/address/"):].strip().rstrip("/"))
                if not addr:
                    return self.send_json({"error": "Address parameter required"}, 400)
                if len(addr) > 128:
                    return self.send_json({"error": "Address not found"}, 404)
                # Bounded: never SELECT * without LIMIT (an address with many
                # outputs could OOM the explorer). Totals come from COUNT(*)/SUM
                # so output_count stays exact even when the list is truncated.
                # One snapshot for all three reads (BEGIN … ROLLBACK): with WAL
                # concurrent syncs would otherwise make them disagree.
                conn.execute("BEGIN")
                try:
                    total = cur.execute(
                        "SELECT COUNT(*) AS n FROM tx_outputs WHERE address = ?", (addr,)).fetchone()["n"]
                    agg = cur.execute(
                        "SELECT COUNT(*) AS n, COALESCE(SUM(value), 0) AS bal FROM tx_outputs "
                        "WHERE address = ? AND spent_txid IS NULL", (addr,)).fetchone()
                    outs = [dict(o) for o in cur.execute(
                        "SELECT * FROM tx_outputs WHERE address = ? ORDER BY block_height DESC, txid, vout_index LIMIT 1000", (addr,))]
                finally:
                    conn.rollback()
                balance = agg["bal"]
                self.send_json({
                    "address": addr,
                    "balance_sats": balance,
                    "balance_cccn": balance / COIN,
                    "output_count": total,
                    "unspent_count": agg["n"],
                    "outputs": outs,
                })

            elif path == "/api/search":
                query = parse_qs(urlparse(self.path).query).get("q", [""])[0].strip()
                if len(query) > 128:
                    return self.send_json({"type": "none"}, 404)
                if query.isascii() and query.isdigit() and len(query) <= 10:
                    # Length guard before int(): longer digit strings cannot be a
                    # height and fall through to the hash/tx/address lookups.
                    row = cur.execute("SELECT height FROM blocks WHERE height = ?", (int(query),)).fetchone()
                    if row:
                        return self.send_json({"type": "block", "id": row["height"]})
                row = cur.execute("SELECT height FROM blocks WHERE hash = ?", (query,)).fetchone()
                if row:
                    return self.send_json({"type": "block", "id": row["height"]})
                row = cur.execute("SELECT txid FROM transactions WHERE txid = ?", (query,)).fetchone()
                if row:
                    return self.send_json({"type": "tx", "id": row["txid"]})
                row = cur.execute("SELECT address FROM tx_outputs WHERE address = ? LIMIT 1", (query,)).fetchone()
                if row:
                    return self.send_json({"type": "address", "id": row["address"]})
                self.send_json({"type": "none"}, 404)

            else:
                self.send_json({"error": "Endpoint not recognized"}, 404)


class BoundedServer(ThreadingHTTPServer):
    # ThreadingHTTPServer spawns one thread per connection with no cap: a
    # slowloris trickle pins a thread+fd each. Refuse past 32 concurrent.
    _sema = threading.Semaphore(32)

    def process_request(self, request, client_address):
        if not type(self)._sema.acquire(blocking=False):
            try:
                request.close()
            except OSError:
                pass
            return
        super().process_request(request, client_address)

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            type(self)._sema.release()


def run_server():
    Database.init()
    threading.Thread(target=sync_worker, daemon=True).start()
    server = BoundedServer((HTTP_BIND, HTTP_PORT), ExplorerHandler)
    log(f"CacheCoin block explorer at http://{HTTP_BIND}:{HTTP_PORT}  (node RPC {RPC_HOST}:{RPC_PORT})")
    server.serve_forever()


if __name__ == "__main__":
    run_server()
