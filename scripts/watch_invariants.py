#!/usr/bin/env python3
"""
CacheCoin PER invariant watcher (long-run monitoring).

Walks the chain block by block and re-derives the PER accounting and the supply
identity independently of the node, exactly like tests/per_invariants.py, but
incrementally and with checkpoints so it can run next to a live node for years.
On any mismatch it prints an ALARM and exits 2, so systemd or a monitoring
script can page someone. It never writes to the node.

State file (default ~/.cachecoin/watch_invariants.json, override with
WATCH_STATE) holds the last height/hash, the model, and a checkpoint every
CHECKPOINT_EVERY blocks. Ticket records older than one epoch are pruned, so the
state stays bounded (a few MB on mainnet) no matter how long it runs.

After a re-org the watcher restores the newest checkpoint whose hash is still on
the active chain and re-walks from there. A fork deeper than every checkpoint
means a full re-walk from genesis: slow on mainnet, but correct.

RPC settings (same as the explorer/check_supply): CACHECOIN_RPC_HOST /
CACHECOIN_RPC_PORT (default 127.0.0.1:29332), CACHECOIN_RPC_COOKIE (default
~/.cachecoin/.cookie), or CACHECOIN_RPC_USER + CACHECOIN_RPC_PASS.

Usage: python3 scripts/watch_invariants.py [--loop SECONDS] [--txout]
  --loop   keep running, checking for new blocks every SECONDS (default: once)
  --txout  also compare gettxoutsetinfo with the supply identity each pass
"""

import argparse
import base64
import copy
import hashlib
import json
import os
import struct
import sys
import time
import urllib.request

COIN = 100_000_000
CHECKPOINT_EVERY = 1000
# Chain-specific emission constants (src/kernel/chainparams.cpp).
CHAINS = {
    "main": {"warm_up": 720, "halving": 1_051_200, "base": 10 * COIN, "warm": 5 * COIN},
    "regtest": {"warm_up": 720, "halving": 150, "base": 10 * COIN, "warm": 5 * COIN},
}


def default_cookie_path():
    if sys.platform == "win32":
        appdata = os.environ.get("APPDATA")
        if appdata:
            return os.path.join(appdata, "CacheCoin", ".cookie")
    elif sys.platform == "darwin":
        return os.path.expanduser("~/Library/Application Support/CacheCoin/.cookie")
    return os.path.expanduser("~/.cachecoin/.cookie")


def rpc_call(method, params=None):
    host = os.environ.get("CACHECOIN_RPC_HOST", "127.0.0.1")
    port = int(os.environ.get("CACHECOIN_RPC_PORT", 29332))
    user, password = os.environ.get("CACHECOIN_RPC_USER"), os.environ.get("CACHECOIN_RPC_PASS")
    if user and password:
        creds = f"{user}:{password}"
    else:
        with open(os.environ.get("CACHECOIN_RPC_COOKIE", default_cookie_path())) as f:
            creds = f.read().strip()
    payload = json.dumps({"jsonrpc": "1.0", "id": "watch", "method": method, "params": params or []}).encode()
    req = urllib.request.Request(f"http://{host}:{port}/", data=payload, headers={
        "Content-Type": "application/json",
        "Authorization": "Basic " + base64.b64encode(creds.encode()).decode(),
    })
    with urllib.request.urlopen(req, timeout=120) as resp:
        data = json.loads(resp.read().decode())
    if data.get("error"):
        raise RuntimeError(f"{method}: {data['error']}")
    return data["result"]


def dsha256(b):
    return hashlib.sha256(hashlib.sha256(b).digest()).digest()


def compact_size(n):
    if n < 253:
        return bytes([n])
    if n <= 0xFFFF:
        return b"\xfd" + struct.pack("<H", n)
    return b"\xfe" + struct.pack("<I", n)


def subsidy(height, chain):
    c = CHAINS[chain]
    if height <= 0:
        return 0
    if height <= c["warm_up"]:
        return c["warm"]
    halvings = (height - 1) // c["halving"]
    return 0 if halvings >= 64 else c["base"] >> halvings


def parse_commitment(script_hex):
    data = bytes.fromhex(script_hex)
    if len(data) != 30 or data[0] != 0x6A or data[1] != 0x1C or data[2:6] != b"PER\x01":
        return None
    p = data[6:]
    return {
        "pool": int.from_bytes(p[0:8], "little", signed=True),
        "tickets": int.from_bytes(p[8:12], "little"),
        "rate": int.from_bytes(p[12:20], "little", signed=True),
        "block_tickets": int.from_bytes(p[20:22], "little"),
        "payouts": int.from_bytes(p[22:24], "little"),
    }


def parse_ticket(script_hex):
    data = bytes.fromhex(script_hex)
    if len(data) < 2 or data[0] != 0x6A:
        return None
    if data[1] <= 75:  # direct push
        if len(data) < 2 + data[1]:
            return None
        body = data[2:2 + data[1]]
    elif data[1] == 0x4C:  # OP_PUSHDATA1
        if len(data) < 3 or len(data) < 3 + data[2]:
            return None
        body = data[3:3 + data[2]]
    elif data[1] == 0x4D:  # OP_PUSHDATA2: OpReturnData accepts it, so the watcher must too
        if len(data) < 4:
            return None
        n = int.from_bytes(data[2:4], "little")
        if len(data) < 4 + n:
            return None
        body = data[4:4 + n]
    else:
        return None
    if len(body) < 40 or body[:4] != b"PERT":
        return None
    anchor, payout, nonce = body[4:36], body[36:-4], body[-4:]
    return {"id": dsha256(anchor + compact_size(len(payout)) + payout + nonce).hex(),
            "payout": payout.hex()}


def fresh_state(chain, epoch):
    return {
        "chain": chain, "epoch": epoch, "height": -1, "hash": None,
        "pool": 0, "tickets": 0, "rate": 0,
        "fees_half": 0, "payouts": 0, "coinbase": 0, "fees": 0,
        "unclaimed": 0, "burns": 0,
        "debits": {}, "paid": {}, "block_tickets": {}, "window": [],
        "checkpoint": None,
    }


def check_block(state, h, blk):
    """Return a list of alarm strings for one block (empty = healthy)."""
    chain, epoch = state["chain"], state["epoch"]
    bad = []
    fees = sum(round(t["fee"] * COIN) for t in blk["tx"][1:])
    state["fees"] += fees
    vout_values = [round(o["value"] * COIN) for o in blk["tx"][0]["vout"]]
    # Value sent to an unspendable output (leading OP_RETURN, or a script over
    # 10000 bytes) never enters the UTXO set and is not part of a fee either.
    for t in blk["tx"]:
        for o in t["vout"]:
            spk = o["scriptPubKey"]["hex"]
            if spk.startswith("6a") or len(spk) // 2 > 10000:
                state["burns"] = state.get("burns", 0) + round(o["value"] * COIN)
    if h == 0:
        return bad
    state["coinbase"] += sum(vout_values)

    cb = blk["tx"][0]
    comm = None
    for i, o in enumerate(cb["vout"]):
        c = parse_commitment(o["scriptPubKey"]["hex"])
        if c is not None:
            if i != 1:
                bad.append(f"height {h}: commitment at vout {i}, not 1")
            comm = c
            break
    if comm is None:
        return bad + [f"height {h}: no PER commitment"]

    if h > 1 and (h - 1) % epoch == 0:
        e = (h - 1) // epoch - 1
        new_rate = state["pool"] // state["tickets"] if state["tickets"] else 0
        debit = new_rate * state["tickets"]
        state["debits"][str(e)] = debit
        state["pool"] -= debit
        state["tickets"] = 0
        state["rate"] = new_rate
    state["pool"] += fees // 2
    state["tickets"] += comm["block_tickets"]
    if (comm["pool"], comm["tickets"], comm["rate"]) != (state["pool"], state["tickets"], state["rate"]):
        bad.append(f"height {h}: committed {comm['pool']},{comm['tickets']},{comm['rate']} "
                   f"!= expected {state['pool']},{state['tickets']},{state['rate']}")

    recs = []
    for i in range(2, 2 + comm["block_tickets"]):
        t = parse_ticket(cb["vout"][i]["scriptPubKey"]["hex"])
        if t is None:
            bad.append(f"height {h}: ticket record {i} does not parse")
            continue
        recs.append(t)
    state["block_tickets"][str(h)] = recs
    ids = [t["id"] for t in recs]
    if any(ids[i - 1] >= ids[i] for i in range(1, len(ids))):
        bad.append(f"height {h}: ticket ids are not strictly sorted")
    for prev_h, prev_ids in state["window"]:
        if h - prev_h <= 10 and set(ids) & set(prev_ids):
            bad.append(f"height {h}: ticket repeated from {prev_h} inside the window")
    state["window"].append((h, ids))
    state["window"] = [(hh, ii) for hh, ii in state["window"] if h - hh < 10]

    src_h = h - epoch
    src = state["block_tickets"].get(str(src_h), [])
    expected = len(src) if (src_h >= 1 and state["rate"] > 0) else 0
    if comm["payouts"] != expected:
        bad.append(f"height {h}: payout count {comm['payouts']} != expected {expected}")
    paid = 0
    for i in range(expected):
        o = cb["vout"][2 + comm["block_tickets"] + i]
        if round(o["value"] * COIN) != state["rate"]:
            bad.append(f"height {h}: payout {i} amount != rate {state['rate']}")
        if o["scriptPubKey"]["hex"] != src[i]["payout"]:
            bad.append(f"height {h}: payout {i} script != source ticket")
        paid += state["rate"]
    state["payouts"] += paid
    if src_h >= 1:
        e = str((src_h - 1) // epoch)
        state["paid"][e] = state["paid"].get(e, 0) + paid
        if state["paid"][e] > state["debits"].get(e, 0):
            bad.append(f"height {h}: payouts for epoch {e} exceed its debit")

    # Consensus rejects only overpayment: a miner may claim less than it is
    # allowed to. Underpayment is not an invariant violation; it is tracked as
    # "unclaimed" so it does not raise a permanent false alarm.
    expected_total = subsidy(h, chain) + fees - fees // 2 + paid
    if sum(vout_values) > expected_total:
        bad.append(f"height {h}: coinbase total {sum(vout_values)} > {expected_total}")
    state["unclaimed"] = state.get("unclaimed", 0) + (expected_total - sum(vout_values))

    state["fees_half"] += fees // 2
    if state["pool"] != state["fees_half"] - sum(state["debits"].values()):
        bad.append(f"height {h}: pool {state['pool']} != fee/2 - debits")

    for e, debit in state["debits"].items():
        if h >= (int(e) + 2) * epoch and state["paid"].get(e, 0) != debit:
            bad.append(f"height {h}: epoch {e} paid {state['paid'].get(e, 0)} != debited {debit}")
    return bad


def walk(state, target):
    bad = []
    for h in range(state["height"] + 1, target + 1):
        bh = rpc_call("getblockhash", [h])
        blk = rpc_call("getblock", [bh, 2])
        bad += check_block(state, h, blk)
        state["height"], state["hash"] = h, bh
        # Payouts at h+epoch are the last use of the records from h; keeping one
        # epoch of history is enough for any future block and for a checkpoint.
        state["block_tickets"].pop(str(h - state["epoch"]), None)
        if h % CHECKPOINT_EVERY == 0:
            state["checkpoint"] = json.loads(json.dumps(
                {k: state[k] for k in ("height", "hash", "pool", "tickets", "rate",
                                       "fees_half", "payouts", "coinbase", "fees",
                                       "unclaimed", "burns",
                                       "debits", "paid", "block_tickets", "window")}))
        if bad:
            break
    return bad


def rewind(state, chain, epoch):
    """After a re-org, restore the checkpoint if it is still on the active chain.

    Returns "checkpoint" or "genesis" so the caller can say what happened. A
    checkpoint from the abandoned branch must never be trusted: restoring it
    would re-walk a different chain and raise a false alarm.
    """
    cp = state.get("checkpoint")
    if cp and cp["height"] <= state["height"]:
        try:
            if rpc_call("getblockhash", [cp["height"]]) == cp["hash"]:
                # Deep-copy: a shallow assignment aliases the checkpoint's dicts
                # and lists, and the walk that follows mutates them in place, so a
                # second re-org in the same window would restore corrupted state
                # and raise a false alarm.
                for k, v in cp.items():
                    state[k] = copy.deepcopy(v)
                state["checkpoint"] = cp
                return "checkpoint"
        except Exception:
            pass
    state.update(fresh_state(chain, epoch))
    return "genesis"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--loop", type=int, default=0, metavar="SECONDS")
    parser.add_argument("--txout", action="store_true")
    args = parser.parse_args()

    state_path = os.environ.get("WATCH_STATE", os.path.join(
        os.path.dirname(os.path.abspath(default_cookie_path())), "watch_invariants.json"))
    state = None
    saved = None
    if os.path.exists(state_path):
        try:
            state = json.load(open(state_path))
            saved = (state["height"], state["hash"])
        except (OSError, ValueError, KeyError) as e:
            print(f"[!] state file unreadable ({e.__class__.__name__}: {e}); "
                  f"starting from genesis", file=sys.stderr)
            state = None

    while True:
        try:
            info = rpc_call("getblockchaininfo")
            chain, tip = info["chain"], info["blocks"]
            if chain not in CHAINS:
                print(f"[!] unknown chain {chain!r}; refusing", file=sys.stderr)
                return 1
            if state is None or state.get("chain") != chain:
                state = fresh_state(chain, rpc_call("getperinfo")["epoch_blocks"])
                print(f"[i] {chain}: starting from genesis (first run)")

            reorg = False
            if state["height"] > tip:
                reorg = True
            elif state["height"] >= 0 and rpc_call("getblockhash", [state["height"]]) != state["hash"]:
                reorg = True
            if reorg:
                detected = state["height"]
                where = rewind(state, chain, state["epoch"])
                print(f"[i] re-org detected at height {detected}; rewinding to {where}")

            bad = walk(state, tip)
            if bad:
                print("ALARM: PER invariant violation", file=sys.stderr)
                for b in bad[:20]:
                    print("  " + b, file=sys.stderr)
                return 2

            if args.txout:
                utxo = round(rpc_call("gettxoutsetinfo")["total_amount"] * COIN)
                burns = state.get("burns", 0)
                if state["coinbase"] - state["fees"] - burns != utxo:
                    print(f"ALARM: supply identity coinbase {state['coinbase']} - fees "
                          f"{state['fees']} - burns {burns} != utxo {utxo}", file=sys.stderr)
                    return 2

            # Save atomically, and only when the chain position changed: a
            # truncated write on a kill would otherwise look like a first run.
            if (state["height"], state["hash"]) != saved:
                os.makedirs(os.path.dirname(state_path), exist_ok=True)
                tmp = state_path + ".tmp"
                with open(tmp, "w") as f:
                    json.dump(state, f)
                    f.flush()
                    os.fsync(f.fileno())
                os.replace(tmp, state_path)
                saved = (state["height"], state["hash"])
            print(f"[ok] height {state['height']}, pool {state['pool']}, tickets "
                  f"{state['tickets']}, rate {state['rate']}")
        except Exception as e:
            print(f"[!] {e.__class__.__name__}: {e}", file=sys.stderr)
            if not args.loop:
                return 1
        if not args.loop:
            return 0
        time.sleep(args.loop)


if __name__ == "__main__":
    sys.exit(main())
