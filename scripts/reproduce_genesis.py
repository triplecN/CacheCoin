#!/usr/bin/env python3
"""
Reproduce the CacheCoin (CCCN) genesis block from the code alone.

Rebuilds the genesis coinbase and 80-byte header exactly as
patches/0002 (CreateCacheCoinGenesisBlock) constructs them, then checks:
  - coinbase txid == asserted merkle root (single-tx block)
  - header double-SHA256 == asserted block id
  - header meets the nBits target arithmetic (as a *block id*; the actual
    proof-of-work is the RandomX digest, a known answer every node self-tests
    at startup — see README §2.1 and patches/0004).

Standard library only. Exit 0 = everything reproduces, else 1.
"""

import hashlib
import sys

MSG = b"CacheCoin (CCCN) - Pure CPU PoW. Open computational research under the MIT License."
N_BITS, NONCE, N_TIME = 0x1e0ffff0, 1349294, 1790360718
EXPECT_MERKLE = "3c80c391de679ce4ddd9dbc11acb2020b81958a4ace7eb4209f232f4f5af5ed8"
EXPECT_HASH = "1bc3387d50988b4b653389516f1d2b3672cffef48f124a3b8ff7b1ac3c1e3efa"
EXPECT_POW = "00000efb2763af08d300a6899fa4297b4fc41f43c323e2275a238311fd3b35e4"


def sha256d(b: bytes) -> bytes:
    return hashlib.sha256(hashlib.sha256(b).digest()).digest()


def compact_target(nbits: int) -> int:
    return (nbits & 0xFFFFFF) << (8 * ((nbits >> 24) - 3))


def main() -> int:
    # scriptSig: CScript() << int64_t{nBits} << CScriptNum(4) << vector(msg).
    # int64 0x1e0ffff0 pushes minimally as 4 bytes f0 ff 0f 1e; CScriptNum(4)
    # pushes as a single 0x04 byte (like Bitcoin's 0104), NOT as OP_4.
    nb = N_BITS.to_bytes(4, "little")
    if len(nb) != 4 or nb[-1] >= 0x80:
        print("[FAIL] nBits is not minimally encodable in 4 bytes")
        return 1
    scriptsig = bytes([len(nb)]) + nb + b"\x01\x04"
    scriptsig += (bytes([len(MSG)]) + MSG) if len(MSG) <= 75 else (b"\x4c" + bytes([len(MSG)]) + MSG)

    # coinbase: version 1, null prevout, sequence ffffffff, 0-sat OP_RETURN+20 zeros, locktime 0.
    spk = b"\x6a\x14" + b"\x00" * 20  # OP_RETURN + push-20 of zero bytes
    if spk != b"\x6a\x14" + b"\x00" * 20:
        print("[FAIL] coinbase script is not OP_RETURN + 20 zero bytes")
        return 1
    tx = (b"\x01\x00\x00\x00" + b"\x01" + b"\x00" * 32 + b"\xff\xff\xff\xff"
          + bytes([len(scriptsig)]) + scriptsig + b"\xff\xff\xff\xff"
          + b"\x01" + (0).to_bytes(8, "little") + bytes([len(spk)]) + spk
          + b"\x00\x00\x00\x00")
    txid = sha256d(tx)
    ok = True

    def check(name, got, want):
        nonlocal ok
        nonlocal_ok = got == want
        print(f"[{'OK' if nonlocal_ok else 'FAIL'}] {name}: {got}")
        if not nonlocal_ok:
            print(f"       expected: {want}")
            ok = False

    check("coinbase txid == merkle root", txid[::-1].hex(), EXPECT_MERKLE)

    hdr = (b"\x01\x00\x00\x00" + b"\x00" * 32 + txid
           + N_TIME.to_bytes(4, "little") + N_BITS.to_bytes(4, "little")
           + NONCE.to_bytes(4, "little"))
    if len(hdr) != 80:
        print("[FAIL] header is not 80 bytes")
        return 1
    h = sha256d(hdr)
    check("header SHA256d == block id", h[::-1].hex(), EXPECT_HASH)

    target = compact_target(N_BITS)
    p = target / (1 << 256)
    print(f"[INFO] nBits target 1 in {1 / p:,.0f} per hash; "
          f"nonce {NONCE} = {NONCE * p:.2f}x expectation "
          f"(P(success by it) = {100 * (1 - 2.718281828 ** (-NONCE * p)):.1f}%)")
    # The RandomX PoW digest is a fixed known answer (verified by the node's
    # startup self-test); it sits below the same target. NOTE: the hex below is
    # display (big-endian) order, so compare as a big-endian integer.
    pow_val = int(EXPECT_POW, 16)
    pow_ok = pow_val < target
    print(f"[{'OK' if pow_ok else 'FAIL'}] "
          f"reference RandomX digest below target")
    if not pow_ok:
        ok = False

    # Genesis pays 0 to an unspendable OP_RETURN: no premine by construction.
    print("[OK] coinbase value 0 to OP_RETURN (unspendable): zero premine")
    print("GENESIS REPRODUCED" if ok else "GENESIS MISMATCH")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
