[CmdletBinding()]
param(
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $PSScriptRoot
$script:WalletDir = Join-Path $script:Root 'Wallet'

# The package manifest is the trust anchor for this tool: refuse to run a copy that fails it,
# so a swapped tool or a tampered package is refused before any key is generated. The launcher's
# own hash check is the outer anchor; this check cannot prove itself.
. (Join-Path $PSScriptRoot 'CacheCoin-Package.ps1')
if (-not (Test-PackageIntegrity -Root $script:Root)) {
    Write-Host ''
    Write-Host 'The program files do not match version.json, or version.json is missing.'
    Write-Host 'Do not use this copy to create keys. Download the package again.'
    exit 1
}

# The key math is C# compiled once by Add-Type: secp256k1, RIPEMD-160, Base58Check and Bech32.
# It is the same algorithm as scripts/keygen.py in the repository (offline paper-wallet generator).
$source = @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Numerics;
using System.Security.Cryptography;
using System.Text;

namespace CacheCoin.Keygen
{
    public static class Keygen
    {
        static readonly BigInteger P = Hex("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F");
        static readonly BigInteger N = Hex("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141");
        static readonly BigInteger Gx = Hex("79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798");
        static readonly BigInteger Gy = Hex("483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8");

        static BigInteger Hex(string h)
        {
            BigInteger v;
            if (!BigInteger.TryParse("0" + h, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out v)) throw new FormatException("bad constant");
            return v;
        }
        static BigInteger Mod(BigInteger a, BigInteger m) { BigInteger r = a % m; return r.Sign < 0 ? r + m : r; }
        static BigInteger ParseBE(byte[] be, int off, int len)
        {
            byte[] le = new byte[len + 1];
            for (int i = 0; i < len; i++) le[i] = be[off + len - 1 - i];
            return new BigInteger(le);
        }
        static byte[] ToBE32(BigInteger v)
        {
            byte[] le = v.ToByteArray();
            byte[] be = new byte[32];
            for (int i = 0; i < 32 && i < le.Length; i++) be[31 - i] = le[i];
            return be;
        }
        static string ToHex(byte[] b) { StringBuilder s = new StringBuilder(b.Length * 2); foreach (byte x in b) s.Append(x.ToString("x2")); return s.ToString(); }
        static byte[] Sha256(byte[] b) { using (SHA256 s = SHA256.Create()) return s.ComputeHash(b); }
        static byte[] DSha256(byte[] b) { return Sha256(Sha256(b)); }

        sealed class Pt { public BigInteger X, Y; }
        static BigInteger ModInv(BigInteger a, BigInteger m)
        {
            BigInteger g = m, x = 0, x1 = 1, a1 = Mod(a, m);
            while (a1 != 0)
            {
                BigInteger q = g / a1, t = g - q * a1; g = a1; a1 = t;
                t = x - q * x1; x = x1; x1 = t;
            }
            if (g != 1) throw new ArithmeticException("no inverse");
            return Mod(x, m);
        }
        static Pt Add(Pt p1, Pt p2)
        {
            if (p1 == null) return p2;
            if (p2 == null) return p1;
            if (p1.X == p2.X && Mod(p1.Y + p2.Y, P).IsZero) return null;
            BigInteger lam;
            if (p1.X == p2.X && p1.Y == p2.Y) lam = Mod(3 * p1.X * p1.X * ModInv(2 * p1.Y, P), P);
            else lam = Mod((p2.Y - p1.Y) * ModInv(p2.X - p1.X, P), P);
            BigInteger x3 = Mod(lam * lam - p1.X - p2.X, P);
            return new Pt { X = x3, Y = Mod(lam * (p1.X - x3) - p1.Y, P) };
        }
        static Pt Mul(BigInteger k, Pt p)
        {
            Pt r = null, a = p;
            while (k > 0)
            {
                if (!(k & 1).IsZero) r = Add(r, a);
                a = Add(a, a);
                k >>= 1;
            }
            return r;
        }

        const string B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
        static string B58Encode(byte[] data)
        {
            int zeros = 0; while (zeros < data.Length && data[zeros] == 0) zeros++;
            BigInteger n = ParseBE(data, 0, data.Length);
            StringBuilder s = new StringBuilder();
            while (n > 0) { BigInteger r; n = BigInteger.DivRem(n, 58, out r); s.Insert(0, B58[(int)r]); }
            return new string('1', zeros) + s.ToString();
        }
        static string B58Check(byte[] data)
        {
            byte[] chk = DSha256(data);
            byte[] all = new byte[data.Length + 4];
            Array.Copy(data, all, data.Length);
            Array.Copy(chk, 0, all, data.Length, 4);
            return B58Encode(all);
        }

        const string B32 = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
        static int[] HrpExpand(string hrp)
        {
            int[] r = new int[hrp.Length * 2 + 1];
            for (int i = 0; i < hrp.Length; i++) r[i] = hrp[i] >> 5;
            r[hrp.Length] = 0;
            for (int i = 0; i < hrp.Length; i++) r[hrp.Length + 1 + i] = hrp[i] & 31;
            return r;
        }
        static uint Polymod(int[] values)
        {
            uint[] GEN = { 0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3 };
            uint chk = 1;
            foreach (int v in values)
            {
                uint b = chk >> 25;
                chk = ((chk & 0x1ffffff) << 5) ^ (uint)v;
                for (int i = 0; i < 5; i++) if (((b >> i) & 1) != 0) chk ^= GEN[i];
            }
            return chk;
        }
        static int[] ConvertBits(byte[] data, int from, int to)
        {
            List<int> ret = new List<int>();
            int acc = 0, bits = 0, maxv = (1 << to) - 1;
            foreach (byte value in data)
            {
                acc = (acc << from) | value;
                bits += from;
                while (bits >= to) { bits -= to; ret.Add((acc >> bits) & maxv); }
            }
            if (bits > 0) ret.Add((acc << (to - bits)) & maxv);
            return ret.ToArray();
        }
        static string Bech32(string hrp, int witver, byte[] prog)
        {
            List<int> data = new List<int>();
            data.Add(witver);
            data.AddRange(ConvertBits(prog, 8, 5));
            int[] hrpExp = HrpExpand(hrp);
            int[] values = new int[hrpExp.Length + data.Count + 6];
            Array.Copy(hrpExp, values, hrpExp.Length);
            for (int i = 0; i < data.Count; i++) values[hrpExp.Length + i] = data[i];
            uint polymod = Polymod(values) ^ 1;
            StringBuilder sb = new StringBuilder();
            sb.Append(hrp).Append('1');
            foreach (int d in data) sb.Append(B32[d]);
            for (int i = 0; i < 6; i++) sb.Append(B32[(int)((polymod >> (5 * (5 - i))) & 31)]);
            return sb.ToString();
        }

        // RIPEMD-160, ported from the repository keygen (Bitcoin Core test framework algorithm).
        static readonly int[] ML = { 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15, 7,4,13,1,10,6,15,3,12,0,9,5,2,14,11,8, 3,10,14,4,9,15,8,1,2,7,0,6,13,11,5,12, 1,9,11,10,0,8,12,4,13,3,7,15,14,5,6,2, 4,0,5,9,7,12,2,10,14,1,3,8,11,6,15,13 };
        static readonly int[] MR = { 5,14,7,0,9,2,11,4,13,6,15,8,1,10,3,12, 6,11,3,7,0,13,5,10,14,15,8,12,4,9,1,2, 15,5,1,3,7,14,6,9,11,8,12,2,10,0,4,13, 8,6,4,1,3,11,15,0,5,12,2,13,9,7,10,14, 12,15,10,4,1,5,8,7,6,2,13,14,0,3,9,11 };
        static readonly int[] RL = { 11,14,15,12,5,8,7,9,11,13,14,15,6,7,9,8, 7,6,8,13,11,9,7,15,7,12,15,9,11,7,13,12, 11,13,6,7,14,9,13,15,14,8,13,6,5,12,7,5, 11,12,14,15,14,15,9,8,9,14,5,6,8,6,5,12, 9,15,5,11,6,8,13,12,5,12,13,14,11,8,5,6 };
        static readonly int[] RR = { 8,9,9,11,13,15,15,5,7,7,8,11,14,14,12,6, 9,13,15,7,12,8,9,11,7,7,12,7,6,15,13,11, 9,7,15,11,8,6,6,14,12,13,5,14,13,13,7,5, 15,5,8,11,14,14,6,14,6,9,12,9,12,5,15,8, 8,5,12,9,12,5,14,6,8,13,6,5,15,13,11,11 };
        static readonly uint[] KL = { 0, 0x5a827999, 0x6ed9eba1, 0x8f1bbcdc, 0xa953fd4e };
        static readonly uint[] KR = { 0x50a28be6, 0x5c4dd124, 0x6d703ef3, 0x7a6d76e9, 0 };

        static uint F(uint x, uint y, uint z, int i)
        {
            if (i == 0) return x ^ y ^ z;
            if (i == 1) return (x & y) | (~x & z);
            if (i == 2) return (x | ~y) ^ z;
            if (i == 3) return (x & z) | (y & ~z);
            return x ^ (y | ~z);
        }
        static uint Rol(uint x, int i) { return (x << i) | (x >> (32 - i)); }
        static void Compress(uint[] h, byte[] block, int off)
        {
            uint al = h[0], bl = h[1], cl = h[2], dl = h[3], el = h[4];
            uint ar = h[0], br = h[1], cr = h[2], dr = h[3], er = h[4];
            uint[] x = new uint[16];
            for (int i = 0; i < 16; i++) x[i] = (uint)(block[off + 4 * i] | (block[off + 4 * i + 1] << 8) | (block[off + 4 * i + 2] << 16) | (block[off + 4 * i + 3] << 24));
            for (int j = 0; j < 80; j++)
            {
                int rnd = j >> 4;
                al = Rol(al + F(bl, cl, dl, rnd) + x[ML[j]] + KL[rnd], RL[j]) + el;
                uint t = al; al = el; el = dl; dl = Rol(cl, 10); cl = bl; bl = t;
                ar = Rol(ar + F(br, cr, dr, 4 - rnd) + x[MR[j]] + KR[rnd], RR[j]) + er;
                t = ar; ar = er; er = dr; dr = Rol(cr, 10); cr = br; br = t;
            }
            uint[] n = new uint[5];
            n[0] = h[1] + cl + dr; n[1] = h[2] + dl + er; n[2] = h[3] + el + ar; n[3] = h[4] + al + br; n[4] = h[0] + bl + cr;
            for (int i = 0; i < 5; i++) h[i] = n[i];
        }
        static byte[] Rmd160(byte[] data)
        {
            uint[] h = { 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0 };
            int full = data.Length >> 6;
            for (int b = 0; b < full; b++) Compress(h, data, b * 64);
            int rem = data.Length & 63;
            int padLen = ((119 - data.Length) & 63) + 1;
            int total = ((data.Length + padLen + 8 + 63) / 64) * 64;
            byte[] fin = new byte[total];
            Array.Copy(data, full * 64, fin, 0, rem);
            fin[rem] = 0x80;
            long bits = (long)data.Length * 8;
            for (int i = 0; i < 8; i++) fin[total - 8 + i] = (byte)(bits >> (8 * i));
            for (int b = 0; b < total / 64; b++) Compress(h, fin, b * 64);
            byte[] outp = new byte[20];
            for (int i = 0; i < 5; i++)
            {
                outp[4 * i] = (byte)h[i]; outp[4 * i + 1] = (byte)(h[i] >> 8); outp[4 * i + 2] = (byte)(h[i] >> 16); outp[4 * i + 3] = (byte)(h[i] >> 24);
            }
            return outp;
        }

        public static string[] Derive(byte[] priv)
        {
            BigInteger k = ParseBE(priv, 0, 32);
            if (k <= 0 || k >= N) throw new ArgumentException("private key out of range");
            Pt q = Mul(k, new Pt { X = Gx, Y = Gy });
            byte[] pub = new byte[33];
            pub[0] = q.Y.IsEven ? (byte)2 : (byte)3;
            Array.Copy(ToBE32(q.X), 0, pub, 1, 32);
            byte[] pkh = Rmd160(Sha256(pub));
            byte[] wifData = new byte[34];
            wifData[0] = 156; Array.Copy(priv, 0, wifData, 1, 32); wifData[33] = 1;
            byte[] legData = new byte[21];
            legData[0] = 28; Array.Copy(pkh, 0, legData, 1, 20);
            return new string[] { ToHex(priv), B58Check(wifData), ToHex(pub), B58Check(legData), Bech32("cccn", 0, pkh) };
        }

        public static string[] NewKeys()
        {
            byte[] priv = new byte[32];
            using (RNGCryptoServiceProvider rng = new RNGCryptoServiceProvider())
            {
                while (true)
                {
                    rng.GetBytes(priv);
                    BigInteger k = ParseBE(priv, 0, 32);
                    if (k > 0 && k < N) return Derive(priv);
                }
            }
        }
    }
}
'@

if (-not ('CacheCoin.Keygen.Keygen' -as [type])) {
    Add-Type -TypeDefinition $source -Language CSharp -ReferencedAssemblies 'System.Numerics.dll'
}

# Known-answer check, run before every key creation: if the curve math were corrupted, this
# refuses to generate anything rather than write a wallet for an unknown key.
function Assert-Keygen {
    $priv1 = New-Object byte[] 32
    $priv1[31] = 1
    $kat = [CacheCoin.Keygen.Keygen]::Derive($priv1)
    $ok = ($kat[0] -eq '0000000000000000000000000000000000000000000000000000000000000001') -and
          ($kat[1] -eq 'Q5TNCBDLJyvT1j4qGpaKC9kypnLmEHJQPvBLHs3mbea2w95p4ukR') -and
          ($kat[2] -eq '0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798') -and
          ($kat[3] -eq 'CT9A8CEgF7qJ3T6QuXSFQN31kEexxxa2oX') -and
          ($kat[4] -eq 'cccn1qw508d6qejxtdg4y5r3zarvary0c5xw7k39pcwe')
    if (-not $ok) {
        Write-Host ''
        Write-Host 'The key generator failed its self-check, so no key was created.'
        Write-Host 'Do not use this copy. Download the package again.'
        exit 1
    }
}

function New-KeyBlock {
    Assert-Keygen
    $k = [CacheCoin.Keygen.Keygen]::NewKeys()
    return [pscustomobject]@{
        Hex    = $k[0]
        Wif    = $k[1]
        Pub    = $k[2]
        Legacy = $k[3]
        Segwit = $k[4]
    }
}

function Show-Key {
    param($Key)
    Write-Host ''
    Write-Host 'Modern segwit address  : ' -NoNewline; Write-Host $Key.Segwit -ForegroundColor Cyan
    Write-Host 'Legacy address (C...)  : ' -NoNewline; Write-Host $Key.Legacy
    Write-Host 'Public key (compressed): ' -NoNewline; Write-Host $Key.Pub
    Write-Host 'Private key (hex)      : ' -NoNewline; Write-Host $Key.Hex -ForegroundColor Yellow
    Write-Host 'WIF private key        : ' -NoNewline; Write-Host $Key.Wif -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Anyone who has the private key or the WIF can take the coins.'
    Write-Host 'Write them on paper or keep them on an offline USB stick. Never share them.'
}

function Save-KeyFile {
    param($Key)
    if (-not (Test-Path -LiteralPath $script:WalletDir)) { New-Item -ItemType Directory -Path $script:WalletDir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $file = $null
    for ($n = 0; $n -lt 100; $n++) {
        $name = if ($n -eq 0) { "cachecoin-wallet-$stamp.txt" } else { "cachecoin-wallet-$stamp-$n.txt" }
        $cand = Join-Path $script:WalletDir $name
        if (-not (Test-Path -LiteralPath $cand)) { $file = $cand; break }
    }
    if (-not $file) { throw 'Could not find a free file name in the Wallet folder.' }
    $lines = @(
        'CACHECOIN WALLET (new, made offline)',
        '====================================',
        '',
        ('Created : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')),
        'Network : main',
        'Type    : single key (one address only)',
        '',
        ('Modern segwit address  : ' + $Key.Segwit),
        ('Legacy address (C...)  : ' + $Key.Legacy),
        ('Public key (compressed): ' + $Key.Pub),
        ('Private key (hex)      : ' + $Key.Hex),
        ('WIF private key        : ' + $Key.Wif),
        '',
        'HOW TO USE',
        '----------',
        '1. Receive or mine coins to the modern segwit address.',
        '2. To open this wallet in CacheCoin: first screen -> "Forgot your password?"',
        '   -> "From a private key" -> paste the WIF -> choose a password.',
        '3. One key restores one address only. Keep this file offline.',
        '',
        'WARNING',
        '-------',
        'Anyone who has this file can take the coins. Do not email it, do not put it',
        'in cloud storage, do not photograph it. There is no way to undo a leak.'
    )
    $text = ($lines -join "`r`n") + "`r`n"
    $enc = New-Object System.Text.UTF8Encoding($false)
    $fs = [System.IO.File]::Open($file, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try { $bytes = $enc.GetBytes($text); $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
    try {
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        & icacls.exe $file /inheritance:r /grant:r "${me}:(R,W)" | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host 'Note: the file could not be locked to your Windows account; keep it offline.' }
    } catch {
        Write-Host 'Note: the file could not be locked to your Windows account; keep it offline.'
    }
    Write-Host ''
    Write-Host 'Wallet saved:'
    Write-Host "  $file"
    Write-Host ''
    Write-Host 'Modern segwit address  : ' -NoNewline; Write-Host $Key.Segwit -ForegroundColor Cyan
    Write-Host 'Legacy address (C...)  : ' -NoNewline; Write-Host $Key.Legacy
    Write-Host ''
    Write-Host 'The private key is only in that file, not on this screen.'
    Write-Host 'Keep the file offline: anyone who has it can take the coins.'
    Write-Host 'Move this file out of the program folder (Documents or a USB stick): deleting or'
    Write-Host 'sharing this folder must never lose or publish your keys.'
}

if ($SelfTest) {
    Write-Host 'NOTE: this self-check prints a throwaway test key so you can compare it by hand.'
    Write-Host 'Never use these test values for real coins.'
    $script:KatFail = 0
    function KCheck {
        param([string]$Name, [bool]$Ok)
        if ($Ok) { Write-Host "OK   $Name" } else { Write-Host "FAIL $Name"; $script:KatFail++ }
    }
    # Known-answer test: private key 1 must derive the exact generator-point key set
    # (cross-checked against the repository's reference keygen).
    $priv1 = New-Object byte[] 32
    $priv1[31] = 1
    $kat = [CacheCoin.Keygen.Keygen]::Derive($priv1)
    KCheck 'keygen: private key 1 hex' ($kat[0] -eq '0000000000000000000000000000000000000000000000000000000000000001')
    KCheck 'keygen: private key 1 WIF' ($kat[1] -eq 'Q5TNCBDLJyvT1j4qGpaKC9kypnLmEHJQPvBLHs3mbea2w95p4ukR')
    KCheck 'keygen: private key 1 derives the generator point' ($kat[2] -eq '0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798')
    KCheck 'keygen: private key 1 legacy address' ($kat[3] -eq 'CT9A8CEgF7qJ3T6QuXSFQN31kEexxxa2oX')
    KCheck 'keygen: private key 1 segwit address' ($kat[4] -eq 'cccn1qw508d6qejxtdg4y5r3zarvary0c5xw7k39pcwe')
    $k = New-KeyBlock
    KCheck 'keygen: hex is 64 lowercase hex' ($k.Hex -match '^[0-9a-f]{64}$')
    KCheck 'keygen: WIF starts with Q' ($k.Wif.StartsWith('Q'))
    KCheck 'keygen: public key is compressed' ($k.Pub -match '^0[23][0-9a-f]{64}$')
    KCheck 'keygen: legacy address starts with C' ($k.Legacy.StartsWith('C'))
    KCheck 'keygen: segwit address is cccn1 bech32' ($k.Segwit -match '^cccn1[ac-hj-np-z02-9]{6,87}$')
    Write-Host ('hex=' + $k.Hex)
    Write-Host ('wif=' + $k.Wif)
    Write-Host ('pub=' + $k.Pub)
    Write-Host ('legacy=' + $k.Legacy)
    Write-Host ('segwit=' + $k.Segwit)
    if ($script:KatFail -gt 0) {
        Write-Host "Self-test FAILED ($script:KatFail check(s))."
        exit 1
    }
    Write-Host 'Self-test OK.'
    exit 0
}

Write-Host ''
Write-Host 'Create a new CacheCoin wallet'
Write-Host '============================='
Write-Host ''
Write-Host 'This makes a brand-new key offline (no node, no internet needed).'
Write-Host 'You get one modern segwit address (cccn1...) and its private key.'
Write-Host 'You can make as many wallets as you want.'
Write-Host ''

while ($true) {
    Write-Host 'What do you want to do?'
    Write-Host '  1) Create a wallet and save it to a .txt file in the Wallet folder'
    Write-Host '  2) Create a wallet and show it on screen (copy it down)'
    Write-Host '  3) Exit'
    $choice = (Read-Host 'Type 1, 2 or 3').Trim()
    if ($choice -eq '1') {
        Save-KeyFile (New-KeyBlock)
        $null = Read-Host 'Press Enter to continue'
        continue
    }
    if ($choice -eq '2') {
        while ($true) {
            Show-Key (New-KeyBlock)
            $again = (Read-Host 'Press Enter to create another wallet, or type Q to stop').Trim()
            if ($again -match '^[Qq]') { break }
        }
        continue
    }
    break
}

Write-Host ''
Write-Host 'Done.'
$null = Read-Host 'Press Enter to close this window'
