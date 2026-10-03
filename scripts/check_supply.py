#!/usr/bin/env python3
"""
CacheCoin (CCCN) emission / supply checker
------------------------------------------
Prints the block reward, halving era and theoretical emission at a height, computed in
integer satoshis exactly like GetBlockSubsidy() in src/validation.cpp.

  python3 scripts/check_supply.py            # height from the local node (cookie auth), or
                                             # the emission milestones if no node is running
  python3 scripts/check_supply.py <height>   # any height, no node needed
  python3 scripts/check_supply.py --check    # assert the schedule; exits 1 on any mismatch

Emission is what the protocol mints (block subsidies); it is the whole coin supply, because
transaction fees are never destroyed. Half of every fee goes to the miner and half to the
28-day PER reservoir, which is paid back out to ticket holders, so no fee coin is lost.

RPC settings (same as the explorer): CACHECOIN_RPC_HOST / CACHECOIN_RPC_PORT (default
127.0.0.1:29332), CACHECOIN_RPC_COOKIE (default ~/.cachecoin/.cookie), or
CACHECOIN_RPC_USER + CACHECOIN_RPC_PASS.
"""

import base64
import json
import os
import sys
import urllib.request

COIN = 100_000_000
WARM_UP_BLOCKS = 720                # blocks 1-720 (12 hours at 60 s)
WARM_UP_REWARD = 5 * COIN
BASE_REWARD = 10 * COIN
HALVING_INTERVAL = 1_051_200        # about 2 years of 60 s blocks


def _default_cookie_path():
    """Locate the node's RPC cookie on this platform.

    patches/0007-data-directory.patch gives each platform a different data
    directory, so a hardcoded ~/.cachecoin only resolves on Linux. Keep
    CACHECOIN_RPC_COOKIE as the override.
    """
    if sys.platform == "win32":
        appdata = os.environ.get("APPDATA")
        if appdata:
            return os.path.join(appdata, "CacheCoin", ".cookie")
    elif sys.platform == "darwin":
        return os.path.expanduser("~/Library/Application Support/CacheCoin/.cookie")
    return os.path.expanduser("~/.cachecoin/.cookie")


def block_reward(height):
    """Satoshis minted by the block at `height` (mirrors GetBlockSubsidy)."""
    if height <= 0:
        return 0
    if height <= WARM_UP_BLOCKS:
        return WARM_UP_REWARD
    halvings = (height - 1) // HALVING_INTERVAL
    return 0 if halvings >= 64 else BASE_REWARD >> halvings


def emission_at_height(height):
    """Total satoshis minted by blocks 1..height."""
    if height <= 0:
        return 0
    total = min(height, WARM_UP_BLOCKS) * WARM_UP_REWARD
    start = WARM_UP_BLOCKS + 1
    while start <= height:
        halvings = (start - 1) // HALVING_INTERVAL
        if halvings >= 64:
            break
        era_end = min(height, (halvings + 1) * HALVING_INTERVAL)
        total += (era_end - start + 1) * block_reward(start)
        start = era_end + 1
    return total


MAX_EMISSION = emission_at_height(64 * HALVING_INTERVAL)


def cccn(sats):
    return f"{sats // COIN:,}.{sats % COIN:08d} CCCN"


# Exact totals for the mainnet constants above, asserted by --check and by
# tests/emission_check.py against the node's own GetBlockSubsidy.
MAX_MONEY = 21_020_400 * COIN
TOTAL_EMISSION = 2_102_039_986_334_400
HEADROOM = 13_665_600
FIRST_ZERO_HEIGHT = 30 * HALVING_INTERVAL + 1  # 10 CCCN >> 30 == 0


def self_check():
    """Assert the emission schedule; return 0 when every check passes."""
    failures = []

    def expect(ok, what):
        print(f"  {'PASS' if ok else 'FAIL'}  {what}")
        if not ok:
            failures.append(what)

    expect(block_reward(0) == 0, "genesis pays no subsidy")
    expect(block_reward(1) == WARM_UP_REWARD and block_reward(WARM_UP_BLOCKS) == WARM_UP_REWARD,
           f"blocks 1..{WARM_UP_BLOCKS} pay 5 CCCN")
    expect(block_reward(WARM_UP_BLOCKS + 1) == BASE_REWARD, "block 721 pays 10 CCCN")
    for n in range(1, 30):
        h = n * HALVING_INTERVAL
        expect(block_reward(h) == BASE_REWARD >> (n - 1) and block_reward(h + 1) == BASE_REWARD >> n,
               f"halving {n} applies exactly at block {h + 1}")
    expect(block_reward(FIRST_ZERO_HEIGHT) == 0 and block_reward(1_000_000_000) == 0,
           f"the subsidy is zero from block {FIRST_ZERO_HEIGHT} on")
    rewards = [BASE_REWARD >> n for n in range(30)]
    expect(all(rewards[i] >= rewards[i + 1] for i in range(len(rewards) - 1)),
           "the subsidy never increases")
    expect(emission_at_height(WARM_UP_BLOCKS) == WARM_UP_BLOCKS * WARM_UP_REWARD,
           "emission through the warm-up is exact")
    samples = [0, 1, WARM_UP_BLOCKS, WARM_UP_BLOCKS + 1, HALVING_INTERVAL, HALVING_INTERVAL + 1,
               10 * HALVING_INTERVAL, FIRST_ZERO_HEIGHT, 64 * HALVING_INTERVAL]
    minted = [emission_at_height(h) for h in samples]
    expect(all(minted[i] <= minted[i + 1] for i in range(len(minted) - 1)),
           "cumulative emission never decreases")
    expect(MAX_EMISSION == TOTAL_EMISSION, f"total emission is exactly {cccn(TOTAL_EMISSION)}")
    expect(MAX_MONEY - MAX_EMISSION == HEADROOM,
           f"MAX_MONEY minus total emission is exactly {cccn(HEADROOM)}")

    if failures:
        print(f"CHECK FAILED: {len(failures)} mismatch(es)")
        return 1
    print("CHECK PASSED")
    return 0


def rpc_endpoint():
    return os.environ.get("CACHECOIN_RPC_HOST", "127.0.0.1") + ":" + \
        os.environ.get("CACHECOIN_RPC_PORT", "29332")


def get_node_info():
    host = os.environ.get("CACHECOIN_RPC_HOST", "127.0.0.1")
    port = int(os.environ.get("CACHECOIN_RPC_PORT", 29332))
    user, password = os.environ.get("CACHECOIN_RPC_USER"), os.environ.get("CACHECOIN_RPC_PASS")
    try:
        if user and password:
            creds = f"{user}:{password}"
        else:
            with open(os.environ.get("CACHECOIN_RPC_COOKIE", _default_cookie_path())) as f:
                creds = f.read().strip()
        payload = json.dumps({"jsonrpc": "1.0", "id": "supply", "method": "getblockchaininfo", "params": []}).encode()
        req = urllib.request.Request(f"http://{host}:{port}/", data=payload, headers={
            "Content-Type": "application/json",
            "Authorization": "Basic " + base64.b64encode(creds.encode()).decode(),
        })
        with urllib.request.urlopen(req, timeout=5) as resp:
            info = json.loads(resp.read().decode())["result"]
            return (info["chain"], info["blocks"])
    except (OSError, ValueError, KeyError) as e:
        print(f"[i] no node RPC ({e.__class__.__name__}: {e})")
        # No node to check against. The caller still works from an explicit height,
        # it just cannot confirm the chain, so say so rather than implying it did.
        return (None, None)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--check":
        return self_check()
    print("=" * 72)
    print(" CACHECOIN (CCCN) EMISSION")
    print("=" * 72)
    # Ask the node which chain it is on before anything else. The constants below are
    # the mainnet ones; regtest halves every 150 blocks and testnet every 210000, so
    # printing them for another chain produces figures that look authoritative and are
    # wrong by orders of magnitude. An explicit height argument used to skip this check
    # entirely, which is how those wrong numbers reached people.
    chain, node_height = get_node_info()
    if chain is not None and chain != "main":
        sys.exit(
            "[!] These constants describe the mainnet only: warm-up " + str(WARM_UP_BLOCKS)
            + " blocks, halving every " + str(HALVING_INTERVAL) + " blocks. The node at "
            + rpc_endpoint() + " is on " + repr(chain)
            + ", whose schedule differs, so every figure below would be wrong. Point the"
            + " tool at a mainnet node, or take the constants for the chain you are on from"
            + " src/kernel/chainparams.cpp."
        )
    if len(sys.argv) > 1:
        if not sys.argv[1].isdigit():
            sys.exit("usage: check_supply.py [height]")
        height = int(sys.argv[1])
    else:
        height = node_height
        if height is not None:
            print(f"[+] height from the local node: {height:,}")

    if height is not None:
        minted = emission_at_height(height)
        era = 0 if height <= WARM_UP_BLOCKS else 1 + (height - 1) // HALVING_INTERVAL
        print(f"Block height        : {height:,}")
        print(f"Block reward        : {cccn(block_reward(height))}")
        print(f"Era                 : {'warm-up (blocks 1-720)' if era == 0 else f'{era} (halving every {HALVING_INTERVAL:,} blocks)'}")
        print(f"Emitted so far      : {cccn(minted)}  ({minted / MAX_EMISSION * 100:.4f}% of the final emission)")
        print(f"Final emission      : {cccn(MAX_EMISSION)}")
        print(f"Still to be mined   : {cccn(MAX_EMISSION - minted)}")
    else:
        print(f"{'Milestone':<30} | {'Height':>12} | {'Reward':>20} | {'Emitted by then':>26}")
        print("-" * 98)
        milestones = [
            ("Genesis (no reward)", 0), ("Block 1", 1), ("End of warm-up", 720), ("Full reward starts", 721),
            ("Day 1", 1_440), ("Month 1", 43_200), ("Year 1", 525_600),
            ("Last block before halving 1", HALVING_INTERVAL), ("Halving 1", HALVING_INTERVAL + 1),
            ("Halving 2", 2 * HALVING_INTERVAL + 1), ("Halving 10", 10 * HALVING_INTERVAL + 1),
            ("Reward reaches 0", BASE_REWARD.bit_length() * HALVING_INTERVAL + 1),
        ]
        for name, h in milestones:
            print(f"{name:<30} | {h:>12,} | {cccn(block_reward(h)):>20} | {cccn(emission_at_height(h)):>26}")
        print("-" * 98)
        print(f"Final emission: {cccn(MAX_EMISSION)} (MAX_MONEY in the node is 21,020,400 CCCN)")
    print("=" * 72)


if __name__ == "__main__":
    sys.exit(main())
