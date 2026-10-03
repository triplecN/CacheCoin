#!/usr/bin/env python3
"""
CacheCoin crash and data-integrity durability test (regtest, one cachecoind node).

Checks the failure assumptions the security policy leans on. Nothing here touches
mainnet; the datadir is throw-away and lives under /tmp.

  1. SIGKILL after mining: restart recovers the same tip, UTXO set and PER state
  2. -reindex rebuilds the same chain, UTXO set and PER state from the block files
  3. a lost block index is refused without -reindex, and -reindex recovers it
  4. a truncated block file is never served as if it were intact
  5. a bit-flipped block header is never served as valid
  6. a deleted chainstate directory is rebuilt from the block files

The test also gives the node a non-trivial PER state first (a mined ticket plus
epoch boundaries), so the PER commitment is part of what is checked after every
recovery. Block files are kept unobfuscated (-blocksxor=0) so the tests can find
and damage a known header.

Linux/WSL2 only (SIGKILL and the fixed /tmp paths). Standard library only.

Usage: python3 tests/durability_regtest.py [path/to/cachecoind]
"""

import os
import shutil
import signal
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import functional_regtest as ft  # noqa: E402

ft.BITCOIND = sys.argv[1] if len(sys.argv) > 1 else "cachecoind"
ft.BASE = "/tmp/cachecoin-durability"
BLOCK_BACKUP = "/tmp/cachecoin-durability-blocks"
XOR = ["-blocksxor=0"]
check, wait_for = ft.check, ft.wait_for
COIN = ft.COIN


def snapshot(node):
    """Everything a recovery has to reproduce: tip, supply, UTXO count, PER state."""
    utxo = node.rpc("gettxoutsetinfo")
    per = node.rpc("getperinfo")
    return {
        "best": node.rpc("getbestblockhash"),
        "height": node.rpc("getblockcount"),
        "minted": round(utxo["total_amount"] * COIN),
        "txouts": utxo["txouts"],
        "per": (per["pool"], per["tickets"], per["rate"], per["epoch"]),
    }


def matches(node, snap):
    return snapshot(node) == snap


def damaged_header(hdr):
    """The 80-byte header of the block, internal byte order."""
    return (struct.pack("<i", hdr["version"])
            + bytes.fromhex(hdr["previousblockhash"])[::-1]
            + bytes.fromhex(hdr["merkleroot"])[::-1]
            + struct.pack("<I", hdr["time"])
            + int(hdr["bits"], 16).to_bytes(4, "little")
            + struct.pack("<I", hdr["nonce"]))


def flip_tip_header(blocks_dir, hdr):
    """Flip one bit in the nonce of the given header, return True when found."""
    needle = damaged_header(hdr)
    for name in sorted(f for f in os.listdir(blocks_dir) if f.startswith("blk") and f.endswith(".dat")):
        path = os.path.join(blocks_dir, name)
        with open(path, "rb") as f:
            data = bytearray(f.read())
        off = bytes(data).find(needle)
        if off >= 0:
            data[off + 79] ^= 0x01
            with open(path, "wb") as f:
                f.write(data)
            return True
    return False


def main():
    shutil.rmtree(ft.BASE, ignore_errors=True)
    node = ft.Node("dur", 39171, 39271)
    try:
        node.start(extra_args=XOR)
        node.rpc("createwallet", "w")
        addr = node.rpc("getnewaddress", "", "bech32", wallet="w")
        node.rpc("generatetoaddress", 120, addr)
        # A pooled ticket plus two epoch boundaries (regtest epochs are 20 blocks)
        # make the PER commitment non-trivial.
        check(node.rpc("generateperticket", addr)["found"], "mined a PER ticket")
        node.rpc("generatetoaddress", 25, addr)
        snap = snapshot(node)
        check(snap["height"] == 145, f"chain at height {snap['height']} with a non-trivial PER state")

        print("[1] SIGKILL and restart")
        if os.name != "posix":
            print("  SKIP  SIGKILL is Linux-only")
        else:
            node.proc.send_signal(signal.SIGKILL)
            node.proc.wait(timeout=60)
            node.proc = None
            node.start(extra_args=XOR)
            wait_for(lambda: matches(node, snap), 120,
                     "the node recovers the same tip, UTXO set and PER state after SIGKILL")
            check(True, "SIGKILL: same tip, UTXO set and PER state after restart")

        print("[2] -reindex")
        node.stop()
        node.start(extra_args=["-reindex"] + XOR)
        wait_for(lambda: matches(node, snap), 300, "reindex rebuilds the same chain")
        check(True, "-reindex: same tip, UTXO set and PER state from the block files")

        print("[3] lost block index")
        node.stop()
        index_dir = os.path.join(node.datadir, "regtest", "blocks", "index")
        check(os.path.isdir(index_dir), "block index directory exists before the test")
        shutil.rmtree(index_dir)
        try:
            node.start(extra_args=XOR)
            started = True
        except Exception:
            started = False
            if node.proc and node.proc.poll() is None:
                node.proc.kill()
            node.proc = None
        if started:
            # Accepting the start is fine only if the node does not claim the chain
            # it can no longer prove.
            check(node.rpc("getblockcount") < snap["height"],
                  "without -reindex the node does not claim the lost chain")
            node.stop()
        else:
            check(True, "a missing block index is refused without -reindex")
        node.start(extra_args=["-reindex"] + XOR)
        wait_for(lambda: matches(node, snap), 300, "reindex recovers the chain after index loss")
        check(True, "-reindex recovered the same tip after the block index was deleted")

        print("[4] truncated block file")
        node.stop()
        blocks_dir = os.path.join(node.datadir, "regtest", "blocks")
        shutil.rmtree(BLOCK_BACKUP, ignore_errors=True)
        shutil.copytree(blocks_dir, BLOCK_BACKUP)
        files = sorted(f for f in os.listdir(blocks_dir) if f.startswith("blk") and f.endswith(".dat"))
        check(bool(files), "block files exist")
        newest = os.path.join(blocks_dir, files[-1])
        check(os.path.getsize(newest) > 0, "newest block file has data")
        # Block files are pre-allocated in 16 MiB chunks, so removing the tail only
        # removes zero padding. Empty the file: the tip lives in it, so its bytes
        # are gone.
        with open(newest, "r+b") as f:
            f.truncate(0)
        try:
            node.start(extra_args=XOR)
            started = True
        except Exception:
            started = False
            if node.proc and node.proc.poll() is None:
                node.proc.kill()
            node.proc = None
        if started:
            # The index may still claim the old height, but the node must not be
            # able to serve the block whose bytes are gone.
            try:
                node.rpc("getblock", snap["best"])
                readable = True
            except RuntimeError:
                readable = False
            check(node.rpc("getblockcount") < snap["height"] or not readable,
                  "a truncated block file is not served as if it were intact")
            node.stop()
        else:
            check(True, "a truncated block file is refused without -reindex")
        shutil.rmtree(blocks_dir)
        shutil.copytree(BLOCK_BACKUP, blocks_dir)
        node.start(extra_args=["-reindex"] + XOR)
        wait_for(lambda: matches(node, snap), 300, "reindex recovers the restored block files")
        check(True, "restored block files + -reindex recover the same tip")

        print("[5] bit-flipped block header")
        hdr = node.rpc("getblockheader", snap["best"])
        node.stop()
        blocks_dir = os.path.join(node.datadir, "regtest", "blocks")
        shutil.rmtree(BLOCK_BACKUP, ignore_errors=True)
        shutil.copytree(blocks_dir, BLOCK_BACKUP)
        check(flip_tip_header(blocks_dir, hdr), "found and flipped the tip header in a block file")
        try:
            node.start(extra_args=XOR)
            started = True
        except Exception:
            started = False
            if node.proc and node.proc.poll() is None:
                node.proc.kill()
            node.proc = None
        if started:
            try:
                node.rpc("getblock", snap["best"])
                readable = True
            except RuntimeError:
                readable = False
            check(not readable, "a bit-flipped block header is not served as valid")
            node.stop()
        else:
            check(True, "a bit-flipped block header is refused without -reindex")
        shutil.rmtree(blocks_dir)
        shutil.copytree(BLOCK_BACKUP, blocks_dir)
        node.start(extra_args=["-reindex"] + XOR)
        wait_for(lambda: matches(node, snap), 300, "reindex recovers the restored block files")
        check(True, "restored block files + -reindex recover the same tip after the bit flip")

        print("[6] deleted chainstate")
        # A power cut can leave the chainstate directory missing or unreadable while
        # the block files are fine. The node must rebuild the UTXO set from the block
        # index and block files by itself, without -reindex.
        node.stop()
        cs_dir = os.path.join(node.datadir, "regtest", "chainstate")
        check(os.path.isdir(cs_dir), "chainstate directory exists before the test")
        shutil.rmtree(cs_dir)
        node.start(extra_args=XOR)
        wait_for(lambda: matches(node, snap), 600, "the node rebuilds a deleted chainstate from the block files")
        check(True, "deleted chainstate: same tip, UTXO set and PER state after rebuilding")

        print("\nDURABILITY CHECKS PASSED")
        return 0
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"\nFAILED: {e}")
        return 1
    finally:
        node.stop()
        shutil.rmtree(ft.BASE, ignore_errors=True)
        shutil.rmtree(BLOCK_BACKUP, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
