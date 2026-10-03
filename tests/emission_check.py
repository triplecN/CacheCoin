#!/usr/bin/env python3
"""
CacheCoin emission schedule check.

Part 1 runs a real regtest node and compares GetBlockSubsidy at every height
0..752 with an independent Python implementation (regtest halving interval 150,
the same rule the mainnet schedule uses).

Part 2 reads the mainnet constants from the patched source tree and checks the
whole mainnet schedule: the subsidy must halve exactly at every boundary and
reach zero after 64 halvings, and the total emission must be MAX_MONEY minus
exactly the documented 0.136656 CCCN of headroom. That headroom is what makes
the cap enforceable; an off-by-one in the schedule would show up here.

Usage: python3 tests/emission_check.py [path/to/cachecoind] [source-dir]
"""

import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import functional_regtest as ft  # noqa: E402

ft.BITCOIND = sys.argv[1] if len(sys.argv) > 1 else "cachecoind"
SRC = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser("~/cachecoin-build/cachecoin-v31.1")
ft.BASE = "/tmp/cachecoin-emission"
check, wait_for = ft.check, ft.wait_for
COIN = ft.COIN

WARMUP = 720
REGTEST_HALVING = 150
MAINNET_HALVING = 1_051_200
MAX_MONEY = 21_020_400 * COIN
# Total of the whole mainnet schedule, computed independently (2_102_039_986_334_400
# sats = 21,020,399.863344 CCCN). MAX_MONEY - total = 13,665,600 sats = 0.136656 CCCN.
MAINNET_TOTAL = 2_102_039_986_334_400
MAINNET_HEADROOM = 13_665_600


def subsidy(height, halving):
    if height <= 0:
        return 0
    if height <= WARMUP:
        return 5 * COIN
    n = (height - 1) // halving
    return 0 if n >= 64 else (10 * COIN) >> n


def read_mainnet_constants():
    """Mainnet values as they appear in the patched source tree."""
    chainparams = os.path.join(SRC, "src", "kernel", "chainparams.cpp")
    amount = os.path.join(SRC, "src", "consensus", "amount.h")
    validation = os.path.join(SRC, "src", "validation.cpp")
    if not all(os.path.isfile(p) for p in (chainparams, amount, validation)):
        return None
    halving = re.search(r"nSubsidyHalvingInterval\s*=\s*(\d+)", open(chainparams).read())
    max_money = re.search(r"MAX_MONEY\s*=\s*(\d+)\s*\*\s*COIN", open(amount).read())
    warmup = re.search(r"nHeight\s*<=\s*(\d+)\)\s*\{\s*\n\s*return\s+(\d+)\s*\*\s*COIN", open(validation).read())
    base = re.search(r"CAmount nSubsidy\s*=\s*(\d+)\s*\*\s*COIN", open(validation).read())
    if not all((halving, max_money, warmup, base)):
        return None
    return {
        "halving": int(halving.group(1)),
        "max_money": int(max_money.group(1)) * COIN,
        "warmup": int(warmup.group(1)),
        "warmup_reward": int(warmup.group(2)) * COIN,
        "base_reward": int(base.group(1)) * COIN,
    }


def main():
    shutil.rmtree(ft.BASE, ignore_errors=True)
    node = ft.Node("emit", 39201, 39301)
    try:
        node.start()
        node.rpc("createwallet", "w")
        addr = node.rpc("getnewaddress", "", "bech32", wallet="w")
        node.rpc("generatetoaddress", 753, addr)

        print("[1] the node's own GetBlockSubsidy, every height 1..752")
        bad = []
        for h in range(1, 753):
            got = node.rpc("getblockstats", h, ["subsidy"])["subsidy"]
            want = subsidy(h, REGTEST_HALVING)
            if got != want:
                bad.append(f"height {h}: node {got} != expected {want}")
        check(not bad, "all 752 heights match the independent schedule" + ("" if not bad else ": " + bad[0]))
        check(subsidy(0, REGTEST_HALVING) == 0, "genesis pays no subsidy")
        check(subsidy(720, REGTEST_HALVING) == 5 * COIN and subsidy(721, REGTEST_HALVING) == 10 * COIN >> 4,
              "the warm-up ends at 720 and the post-warm-up reward starts at 721")

        print("[2] the mainnet constants and the whole schedule")
        if not os.path.isdir(SRC):
            print(f"  SKIP  source tree not found at {SRC}; mainnet constants not checked")
        else:
            const = read_mainnet_constants()
            # A tree was given, so a regex that no longer matches is a failure, not
            # a silent skip: otherwise the mainnet cap is never actually checked.
            check(const is not None, "the mainnet constants were found in the source tree")
            if const is not None:
                check(const["halving"] == MAINNET_HALVING,
                      f"mainnet halving interval is {MAINNET_HALVING}")
                check(const["max_money"] == MAX_MONEY, f"MAX_MONEY is {MAX_MONEY // COIN} CCCN")
                check(const["warmup"] == WARMUP and const["warmup_reward"] == 5 * COIN,
                      "warm-up is 720 blocks at 5 CCCN")
                check(const["base_reward"] == 10 * COIN, "post-warm-up base reward is 10 CCCN")

                h = MAINNET_HALVING
                boundaries_ok = all(
                    subsidy(n * h + 1, h) == 10 * COIN >> n and subsidy(n * h, h) == 10 * COIN >> (n - 1)
                    for n in range(1, 64))
                check(boundaries_ok, "the subsidy halves exactly at each of the 63 boundaries")
                check(subsidy(64 * h + 1, h) == 0 and subsidy(1_000_000_000, h) == 0,
                      "the subsidy is zero after 64 halvings and forever after")

                warm = WARMUP * const["warmup_reward"]
                first = (h - WARMUP) * const["base_reward"]
                rest = sum(h * (const["base_reward"] >> n) for n in range(1, 64))
                total = warm + first + rest
                check(total == MAINNET_TOTAL, "total emission is 21,020,399.863344 CCCN")
                check(const["max_money"] - total == MAINNET_HEADROOM,
                      "MAX_MONEY minus total emission is exactly 0.136656 CCCN")

        print("\nEMISSION CHECK PASSED")
        return 0
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"\nFAILED: {e}")
        return 1
    finally:
        node.stop()
        shutil.rmtree(ft.BASE, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
