# Sets the product metadata on a Windows CacheCoin executable: the VERSIONINFO strings
# (FileDescription, ProductName, CompanyName, ...) and the icon, so Task Manager and Explorer
# show the project's name and icon. Resource-only: no code is touched. Run after the build (CI)
# or on an existing artifact; the package manifest must be regenerated and re-signed afterwards.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\brand_windows_exe.ps1 `
#       -Exe <path to exe> -Icon assets\logo.ico `
#       -FileDescription "CacheCoin node (cachecoind)" -OriginalFilename "cachecoind.exe"
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [string]$Icon,
    [string]$FileDescription,
    [string]$ProductName = 'CacheCoin',
    [string]$CompanyName = 'CacheCoin contributors',
    [string]$OriginalFilename,
    [string]$InternalName,
    [string]$LegalCopyright = 'CacheCoin contributors. MIT License.'
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Exe)) { throw "not found: $Exe" }
$exePath = (Resolve-Path -LiteralPath $Exe).Path
$iconPath = ''
if ($Icon) {
    if (-not (Test-Path -LiteralPath $Icon)) { throw "icon not found: $Icon" }
    $iconPath = (Resolve-Path -LiteralPath $Icon).Path
}

$source = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class CacheCoinBrand
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr BeginUpdateResource(string fileName, bool deleteExisting);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool UpdateResource(IntPtr hUpdate, IntPtr type, IntPtr name, ushort language, byte[] data, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool EndUpdateResource(IntPtr hUpdate, bool discard);

    private static readonly IntPtr RT_ICON = new IntPtr(3);
    private static readonly IntPtr RT_GROUP_ICON = new IntPtr(14);
    private static readonly IntPtr RT_VERSION = new IntPtr(16);
    private const ushort Lang = 0x0409;

    public static string Brand(string exePath, string iconPath, string fileDescription, string productName,
        string companyName, string originalFilename, string internalName, string legalCopyright)
    {
        FileVersionInfo old = FileVersionInfo.GetVersionInfo(exePath);
        ushort[] fv = Parse4(old.FileVersion);
        ushort[] pv = Parse4(old.ProductVersion);
        string fvStr = Format4(fv);
        string pvStr = Format4(pv);
        if (fileDescription == null || fileDescription.Length == 0) fileDescription = old.FileDescription;
        if (productName == null || productName.Length == 0) productName = old.ProductName;
        if (companyName == null || companyName.Length == 0) companyName = old.CompanyName;
        if (originalFilename == null || originalFilename.Length == 0) originalFilename = old.OriginalFilename;
        if (internalName == null || internalName.Length == 0) internalName = Path.GetFileNameWithoutExtension(exePath);
        if (legalCopyright == null || legalCopyright.Length == 0) legalCopyright = old.LegalCopyright;

        byte[] version = BuildVersion(fv, pv, fvStr, pvStr, fileDescription, productName, companyName,
            originalFilename, internalName, legalCopyright);

        IntPtr h = BeginUpdateResource(exePath, false);
        if (h == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "BeginUpdateResource failed");
        try
        {
            if (!UpdateResource(h, RT_VERSION, new IntPtr(1), Lang, version, (uint)version.Length))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "UpdateResource VERSIONINFO failed");

            int icons = 0;
            if (iconPath != null && iconPath.Length > 0 && File.Exists(iconPath))
                icons = SetIcon(h, File.ReadAllBytes(iconPath));

            if (!EndUpdateResource(h, false)) throw new Win32Exception(Marshal.GetLastWin32Error(), "EndUpdateResource failed");
            h = IntPtr.Zero;
            return "branded " + exePath + " (version strings, " + icons + " icon size(s))";
        }
        finally
        {
            if (h != IntPtr.Zero) EndUpdateResource(h, true);
        }
    }

    private static ushort[] Parse4(string v)
    {
        ushort[] r = new ushort[] { 0, 0, 0, 0 };
        if (v == null || v.Length == 0) return r;
        string[] parts = v.Split('.');
        for (int i = 0; i < 4 && i < parts.Length; i++)
        {
            int n;
            if (int.TryParse(parts[i], out n) && n >= 0 && n <= 65535) r[i] = (ushort)n;
        }
        return r;
    }

    private static string Format4(ushort[] v)
    {
        return v[0] + "." + v[1] + "." + v[2] + "." + v[3];
    }

    private static void W2(List<byte> b, ushort v) { b.Add((byte)(v & 0xFF)); b.Add((byte)(v >> 8)); }
    private static void W4(List<byte> b, uint v) { W2(b, (ushort)(v & 0xFFFF)); W2(b, (ushort)(v >> 16)); }
    private static void StrZ(List<byte> b, string s) { b.AddRange(Encoding.Unicode.GetBytes(s)); b.Add(0); b.Add(0); }
    private static void Pad4(List<byte> b) { while ((b.Count & 3) != 0) b.Add(0); }
    private static void SetLen(List<byte> b) { ushort n = (ushort)b.Count; b[0] = (byte)(n & 0xFF); b[1] = (byte)(n >> 8); }

    private static byte[] Str(string key, string value)
    {
        List<byte> b = new List<byte>();
        W2(b, 0); W2(b, (ushort)(value.Length + 1)); W2(b, 1);
        StrZ(b, key); Pad4(b); StrZ(b, value); Pad4(b);
        SetLen(b);
        return b.ToArray();
    }

    private static byte[] Table(string langCp, byte[][] entries)
    {
        List<byte> b = new List<byte>();
        W2(b, 0); W2(b, 0); W2(b, 1); StrZ(b, langCp); Pad4(b);
        foreach (byte[] e in entries) b.AddRange(e);
        SetLen(b);
        return b.ToArray();
    }

    private static byte[] StringFileInfo(byte[][] tables)
    {
        List<byte> b = new List<byte>();
        W2(b, 0); W2(b, 0); W2(b, 1); StrZ(b, "StringFileInfo"); Pad4(b);
        foreach (byte[] t in tables) b.AddRange(t);
        SetLen(b);
        return b.ToArray();
    }

    private static byte[] VarFileInfo()
    {
        List<byte> b = new List<byte>();
        W2(b, 0); W2(b, 0); W2(b, 1); StrZ(b, "VarFileInfo"); Pad4(b);
        List<byte> t = new List<byte>();
        W2(t, 0); W2(t, 4); W2(t, 0); StrZ(t, "Translation"); Pad4(t);
        W4(t, (uint)(Lang | (1200 << 16)));
        SetLen(t);
        b.AddRange(t);
        SetLen(b);
        return b.ToArray();
    }

    private static byte[] Fixed(ushort[] fv, ushort[] pv)
    {
        List<byte> b = new List<byte>();
        W4(b, 0xFEEF04BD); W4(b, 0x00010000);
        W4(b, (uint)((fv[0] << 16) | fv[1])); W4(b, (uint)((fv[2] << 16) | fv[3]));
        W4(b, (uint)((pv[0] << 16) | pv[1])); W4(b, (uint)((pv[2] << 16) | pv[3]));
        W4(b, 0x3F); W4(b, 0); W4(b, 0x00040004); W4(b, 1); W4(b, 0); W4(b, 0); W4(b, 0);
        return b.ToArray();
    }

    private static byte[] BuildVersion(ushort[] fv, ushort[] pv, string fvStr, string pvStr, string desc,
        string product, string company, string orig, string internalName, string copyright)
    {
        List<byte[]> strs = new List<byte[]>();
        strs.Add(Str("CompanyName", company));
        strs.Add(Str("FileDescription", desc));
        strs.Add(Str("FileVersion", fvStr));
        strs.Add(Str("InternalName", internalName));
        strs.Add(Str("LegalCopyright", copyright));
        strs.Add(Str("OriginalFilename", orig));
        strs.Add(Str("ProductName", product));
        strs.Add(Str("ProductVersion", pvStr));

        byte[] sfi = StringFileInfo(new byte[][] { Table("040904B0", strs.ToArray()) });
        byte[] vfi = VarFileInfo();

        List<byte> b = new List<byte>();
        W2(b, 0); W2(b, 52); W2(b, 0); StrZ(b, "VS_VERSION_INFO"); Pad4(b);
        b.AddRange(Fixed(fv, pv)); Pad4(b);
        b.AddRange(sfi); Pad4(b);
        b.AddRange(vfi); Pad4(b);
        SetLen(b);
        return b.ToArray();
    }

    private static int SetIcon(IntPtr h, byte[] ico)
    {
        if (ico.Length < 6) return 0;
        int count = ico[4] | (ico[5] << 8);
        if (count <= 0 || 6 + count * 16 > ico.Length) return 0;

        byte[][] images = new byte[count][];
        List<byte[]> metas = new List<byte[]>();
        for (int i = 0; i < count; i++)
        {
            int off = 6 + i * 16;
            int w = ico[off], hh = ico[off + 1], colors = ico[off + 2];
            ushort planes = (ushort)(ico[off + 4] | (ico[off + 5] << 8));
            ushort bpp = (ushort)(ico[off + 6] | (ico[off + 7] << 8));
            int size = BitConverter.ToInt32(ico, off + 8);
            int dataOff = BitConverter.ToInt32(ico, off + 12);
            if (size <= 0 || dataOff < 0 || dataOff + size > ico.Length) return 0;
            byte[] img = new byte[size];
            Array.Copy(ico, dataOff, img, 0, size);
            images[i] = img;

            List<byte> m = new List<byte>();
            m.Add((byte)w); m.Add((byte)hh); m.Add((byte)colors); m.Add(0);
            W2(m, planes); W2(m, bpp); W4(m, (uint)size); W2(m, (ushort)(i + 1));
            metas.Add(m.ToArray());
        }

        // The upstream MinGW build ships no icon resources at all, and deleting resources with a
        // NULL update poisons the update handle (ERROR_INTERNAL_ERROR), so nothing is deleted:
        // our icon ids 1..n and group 1 are added in the standard en-US resource language.
        for (int i = 0; i < count; i++)
        {
            if (!UpdateResource(h, RT_ICON, new IntPtr(i + 1), Lang, images[i], (uint)images[i].Length))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "UpdateResource RT_ICON failed");
        }
        List<byte> g = new List<byte>();
        W2(g, 0); W2(g, 1); W2(g, (ushort)count);
        foreach (byte[] m in metas) g.AddRange(m);
        byte[] group = g.ToArray();
        if (!UpdateResource(h, RT_GROUP_ICON, new IntPtr(1), Lang, group, (uint)group.Length))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "UpdateResource RT_GROUP_ICON failed");
        return count;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
$result = [CacheCoinBrand]::Brand($exePath, $iconPath, $FileDescription, $ProductName, $CompanyName, $OriginalFilename, $InternalName, $LegalCopyright)
Write-Output $result
$v = (Get-Item -LiteralPath $exePath).VersionInfo
Write-Output ("  FileDescription : " + $v.FileDescription)
Write-Output ("  ProductName     : " + $v.ProductName)
Write-Output ("  CompanyName     : " + $v.CompanyName)
Write-Output ("  OriginalFilename: " + $v.OriginalFilename)
Write-Output ("  FileVersion     : " + $v.FileVersion)
