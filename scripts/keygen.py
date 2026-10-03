#!/usr/bin/env python3
"""
===============================================================================
CacheCoin (CCCN) - Offline Private Key & Address Generator
===============================================================================
Generates cryptographically secure secp256k1 keypairs and CacheCoin addresses.
Zero external pip dependencies (Pure standard library Python 3).

SECURITY: run this script on an air-gapped (offline) machine. The point
multiplication below is not constant-time Python, so a local attacker on a
shared/online machine could theoretically observe timing. Never paste a
generated key into a website, chat, or shell on an online host.

Formats Produced:
1. Private Key (Hex & WIF Compressed)
2. Public Key (Compressed 33-byte Hex)
3. CacheCoin Legacy Address (P2PKH, starts with 'C')
4. CacheCoin Native SegWit Address (Bech32, starts with 'cccn1q...')

Spending with cachecoind: the node only has descriptor wallets (importprivkey does
not work). Import the key into a wallet with importdescriptors, for the SegWit address:
  cachecoin-cli getdescriptorinfo "wpkh(<WIF>)"        -> note the checksum
  cachecoin-cli importdescriptors '[{"desc": "wpkh(<WIF>)#<checksum>", "timestamp": "now"}]'
(use "pkh(<WIF>)" for the legacy address, and an earlier timestamp to rescan old blocks).
Typing the WIF on a command line stores it in the shell history (and it is
visible to other local users in `ps` output while running): prefer --save, use
HISTFILE=/dev/null or a cleared session, and clear history afterwards.
Worse, command-line arguments are visible to every local user in `ps` output
while the command runs: prefer `--save <file>` (prints addresses, keeps the key
in a 0600 file), never redirect full output to a log (default redirect creates
world-readable files), and on Windows tighten the save directory ACL with
`icacls <dir> /inheritance:r /grant:r %USERNAME%:F` (0600 is a no-op there).
===============================================================================""
"""

import os
import sys
import secrets
import hashlib
import binascii
import argparse
import json

# --- 1. secp256k1 Elliptic Curve Primitives ---
P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
A = 0
B = 7
Gx = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
Gy = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

def inv(a, n):
    return pow(a, n - 2, n)

def point_add(p1, p2):
    if p1 is None: return p2
    if p2 is None: return p1
    x1, y1 = p1
    x2, y2 = p2
    if x1 == x2 and y1 != y2: return None
    if x1 == x2:
        m = (3 * x1 * x1 + A) * inv(2 * y1, P) % P
    else:
        m = (y2 - y1) * inv(x2 - x1, P) % P
    x3 = (m * m - x1 - x2) % P
    y3 = (m * (x1 - x3) - y1) % P
    return (x3, y3)

def point_mul(k, p):
    res = None
    addend = p
    while k:
        if k & 1: res = point_add(res, addend)
        addend = point_add(addend, addend)
        k >>= 1
    return res

# --- 2. Cryptographic Hash Helpers ---
def sha256(data: bytes) -> bytes:
    return hashlib.sha256(data).digest()

# Pure-Python RIPEMD-160, used only when hashlib lacks it: OpenSSL 3.0.0-3.0.6 (for example
# Ubuntu 22.04) ships RIPEMD-160 only in its "legacy" provider. Same algorithm as Bitcoin
# Core's test_framework/crypto/ripemd160.py (MIT).
_RMD_ML = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
           7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8,
           3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12,
           1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2,
           4, 0, 5, 9, 7, 12, 2, 10, 14, 1, 3, 8, 11, 6, 15, 13]
_RMD_MR = [5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12,
           6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2,
           15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13,
           8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14,
           12, 15, 10, 4, 1, 5, 8, 7, 6, 2, 13, 14, 0, 3, 9, 11]
_RMD_RL = [11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8,
           7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12,
           11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5,
           11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12,
           9, 15, 5, 11, 6, 8, 13, 12, 5, 12, 13, 14, 11, 8, 5, 6]
_RMD_RR = [8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6,
           9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11,
           9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5,
           15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8,
           8, 5, 12, 9, 12, 5, 14, 6, 8, 13, 6, 5, 15, 13, 11, 11]
_RMD_KL = [0, 0x5a827999, 0x6ed9eba1, 0x8f1bbcdc, 0xa953fd4e]
_RMD_KR = [0x50a28be6, 0x5c4dd124, 0x6d703ef3, 0x7a6d76e9, 0]

def _rmd_f(x, y, z, i):
    if i == 0: return x ^ y ^ z
    if i == 1: return (x & y) | (~x & z)
    if i == 2: return (x | ~y) ^ z
    if i == 3: return (x & z) | (y & ~z)
    return x ^ (y | ~z)

def _rmd_rol(x, i):
    return ((x << i) | ((x & 0xffffffff) >> (32 - i))) & 0xffffffff

def _rmd_compress(h0, h1, h2, h3, h4, block):
    al, bl, cl, dl, el = h0, h1, h2, h3, h4
    ar, br, cr, dr, er = h0, h1, h2, h3, h4
    x = [int.from_bytes(block[4 * i:4 * (i + 1)], 'little') for i in range(16)]
    for j in range(80):
        rnd = j >> 4
        al = _rmd_rol(al + _rmd_f(bl, cl, dl, rnd) + x[_RMD_ML[j]] + _RMD_KL[rnd], _RMD_RL[j]) + el
        al, bl, cl, dl, el = el, al, bl, _rmd_rol(cl, 10), dl
        ar = _rmd_rol(ar + _rmd_f(br, cr, dr, 4 - rnd) + x[_RMD_MR[j]] + _RMD_KR[rnd], _RMD_RR[j]) + er
        ar, br, cr, dr, er = er, ar, br, _rmd_rol(cr, 10), dr
    return h1 + cl + dr, h2 + dl + er, h3 + el + ar, h4 + al + br, h0 + bl + cr

def _ripemd160_py(data: bytes) -> bytes:
    state = (0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0)
    for b in range(len(data) >> 6):
        state = _rmd_compress(*state, data[64 * b:64 * (b + 1)])
    pad = b"\x80" + b"\x00" * ((119 - len(data)) & 63)
    fin = data[len(data) & ~63:] + pad + (8 * len(data)).to_bytes(8, 'little')
    for b in range(len(fin) >> 6):
        state = _rmd_compress(*state, fin[64 * b:64 * (b + 1)])
    return b"".join((h & 0xffffffff).to_bytes(4, 'little') for h in state)

def ripemd160(data: bytes) -> bytes:
    try:
        h = hashlib.new('ripemd160')
    except ValueError:
        return _ripemd160_py(data)
    h.update(data)
    return h.digest()

def hash160(data: bytes) -> bytes:
    return ripemd160(sha256(data))

def dsha256(data: bytes) -> bytes:
    return sha256(sha256(data))

# --- 3. Base58Check Encoding ---
B58_ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'

def b58encode(b: bytes) -> str:
    n = int.from_bytes(b, 'big')
    res = []
    while n > 0:
        n, r = divmod(n, 58)
        res.append(B58_ALPHABET[r])
    res = ''.join(reversed(res))
    pad = 0
    for byte in b:
        if byte == 0: pad += 1
        else: break
    return ('1' * pad) + res

def b58check_encode(prefix: int, payload: bytes) -> str:
    data = bytes([prefix]) + payload
    checksum = dsha256(data)[:4]
    return b58encode(data + checksum)

# --- 4. Bech32 Native SegWit Encoding (BIP173) ---
CHARSET = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l'

def bech32_polymod(values):
    GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
    chk = 1
    for v in values:
        b = chk >> 25
        chk = ((chk & 0x1ffffff) << 5) ^ v
        for i in range(5):
            chk ^= GEN[i] if ((b >> i) & 1) else 0
    return chk

def bech32_hrp_expand(hrp):
    return [ord(x) >> 5 for x in hrp] + [0] + [ord(x) & 31 for x in hrp]

def bech32_create_checksum(hrp, data):
    values = bech32_hrp_expand(hrp) + data
    polymod = bech32_polymod(values + [0, 0, 0, 0, 0, 0]) ^ 1
    return [(polymod >> 5 * (5 - i)) & 31 for i in range(6)]

def convertbits(data, frombits, tobits, pad=True):
    acc = 0
    bits = 0
    ret = []
    maxv = (1 << tobits) - 1
    for value in data:
        acc = (acc << frombits) | value
        bits += frombits
        while bits >= tobits:
            bits -= tobits
            ret.append((acc >> bits) & maxv)
    if pad:
        if bits:
            ret.append((acc << (tobits - bits)) & maxv)
    return ret

def segwit_addr_encode(hrp: str, witver: int, witprog: bytes) -> str:
    data = [witver] + convertbits(witprog, 8, 5)
    checksum = bech32_create_checksum(hrp, data)
    return hrp + '1' + ''.join([CHARSET[d] for d in data + checksum])

# --- 5. Key Generation Pipeline ---
def generate_cachecoin_keypair():
    # 1. Cryptographically secure 256-bit scalar
    privkey_int = secrets.randbelow(N - 1) + 1
    privkey_bytes = privkey_int.to_bytes(32, 'big')

    # 2. Derive secp256k1 public point
    pub_point = point_mul(privkey_int, (Gx, Gy))
    pub_prefix = b'\x02' if pub_point[1] % 2 == 0 else b'\x03'
    pubkey_comp = pub_prefix + pub_point[0].to_bytes(32, 'big')

    # 3. Derive WIF Private Key (Prefix 156 / 0x9c or 0x80)
    # Compressed WIF: [Prefix] + [32 bytes privkey] + [0x01] + [4 bytes Checksum]
    wif_payload = bytes([156]) + privkey_bytes + b'\x01'
    wif_checksum = dsha256(wif_payload)[:4]
    wif_privkey = b58encode(wif_payload + wif_checksum)

    # 4. Derive Public Key Hash (Hash160)
    pkh = hash160(pubkey_comp)

    # 5. Legacy Address (P2PKH, Base58 prefix 28 = 'C')
    legacy_addr = b58check_encode(28, pkh)

    # 6. Modern Native SegWit Address (Bech32, HRP 'cccn', starts with 'cccn1q...')
    segwit_addr = segwit_addr_encode('cccn', 0, pkh)

    return {
        "private_key_hex": privkey_bytes.hex(),
        "wif_private_key": wif_privkey,
        "public_key_hex": pubkey_comp.hex(),
        "legacy_address": legacy_addr,
        "segwit_address": segwit_addr
    }

def main():
    parser = argparse.ArgumentParser(description="CacheCoin (CCCN) Offline Key & Address Generator")
    parser.add_argument("--save", type=str, help="Save generated credentials to a JSON file")
    parser.add_argument("--reveal", action="store_true",
                        help="REQUIRED to print the private key and WIF to stdout")
    args = parser.parse_args()

    if not args.save and not args.reveal:
        sys.exit(
            "[!] Refusing to print a private key implicitly. A WIF left in a\n"
            "    terminal scrollback, a `script` log or CI output is compromised.\n"
            "    Use --save <file> to write it to a 0600 file that is never printed,\n"
            "    or --reveal if you accept having it on stdout.")
    keys = generate_cachecoin_keypair()

    if args.save:
        # Readable by the owner only, and never overwrite an existing key file.
        # The secret itself goes ONLY into that file: with --save the terminal
        # shows addresses, never the key (no scrollback / log / ps exposure).
        try:
            fd = os.open(args.save, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            sys.exit(f"[!] {args.save} already exists; refusing to overwrite a key file.")
        with os.fdopen(fd, "w") as f:
            json.dump(keys, f, indent=2)
        print("=" * 78)
        print(" CACHECOIN (CCCN) SECURE OFFLINE KEYPAIR GENERATOR")
        print("=" * 78)
        print(f"[*] Modern SegWit Address    : {keys['segwit_address']}")
        print(f"[*] Legacy Address (Prefix C): {keys['legacy_address']}")
        print("=" * 78)
        print(f"[+] Full credentials saved to {args.save} (permissions 0600 on Linux/macOS)")
        print("[!] The private key was NOT printed: read it only from that file, offline.")
        print("=" * 78)
        return

    print("=" * 78)
    print(" CACHECOIN (CCCN) SECURE OFFLINE KEYPAIR GENERATOR")
    print("=" * 78)
    print(f"[*] Private Key (Hex)        : {keys['private_key_hex']}")
    print(f"[*] WIF Private Key          : {keys['wif_private_key']}")
    print(f"[*] Public Key (Compressed)  : {keys['public_key_hex']}")
    print("-" * 78)
    print(f"[*] Modern SegWit Address    : {keys['segwit_address']}")
    print(f"[*] Legacy Address (Prefix C): {keys['legacy_address']}")
    print("=" * 78)
    print("[!] OPSEC WARNING: NEVER share your WIF Private Key or Hex Key with anyone!")
    print("[!] Store this offline. Anyone with this key controls your mined CCCN coins.")
    print("[!] Do not redirect this output to a file (redirects are usually world-readable).")
    print("=" * 78)

    # Keep window open if double clicked
    if sys.stdout.isatty():
        input("\nPress ENTER to exit...")

if __name__ == "__main__":
    main()
