#!/usr/bin/env bash
# CacheCoin (CCCN) Windows portable package builder.
#
# Assembles the portable package from a CI build of the node binaries and a
# Tor Expert Bundle: bin/, tor/, launcher/, tools/, docs/, the entry-point .cmd
# files, LICENSE, version.json and SHA256SUMS.windows.txt, then packs it into
# CacheCoin-Windows-<version>.zip.
#
# The repository is only read. Every write goes under --out.
#
# Usage:
#   bash windows/build_package.sh \
#     --bin-dir <dir with cachecoind.exe cachecoin-cli.exe> \
#     --tor-dir <dir with tor.exe + license files> \
#     --version <x.y.z> \
#     --out <dir> \
#     [--launcher-dir windows] [--docs-dir windows/docs]
#
# Exit status is non-zero if a required input is missing or the zip cannot be
# produced. Requires bash, coreutils (sha256sum, find, sort, date) and one zip
# backend: zip, python3/python, or powershell.exe (MSYS2 fallback, checked last).

set -euo pipefail

BITCOIN_PIN="9be056a8a72b624dae9623b2f7bded92c2a21c91"
RANDOMX_PIN="7607fb2faed24d5a679e139a9828d194bbc644a4"

die() {
    printf '[!] %s\n' "$*" >&2
    exit 1
}

note() {
    printf '[+] %s\n' "$*"
}

usage() {
    cat <<'EOF'
usage: bash windows/build_package.sh --bin-dir <dir> --tor-dir <dir> \
         --version <x.y.z> --out <dir> [--launcher-dir <dir>] [--docs-dir <dir>]

  --bin-dir       directory containing cachecoind.exe and cachecoin-cli.exe
  --tor-dir       directory containing tor.exe, or the extracted Tor Expert
                  Bundle root (which contains tor/, data/ and docs/)
  --version       package version, x.y.z (a leading "v" is accepted and stripped)
  --out           output directory; the package directory and zip are created here
  --launcher-dir  directory containing CacheCoin.cmd and launcher/CacheCoin.ps1
                  (default: the directory this script lives in)
  --docs-dir      directory with the package documentation
                  (default: <launcher-dir>/docs)

The script writes only under --out. version.json and SHA256SUMS.windows.txt
are written into the package root; SHA256SUMS.windows.txt.asc is produced
offline with the release GPG key, not here.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BIN_DIR=""
TOR_DIR=""
VERSION=""
OUT=""
LAUNCHER_DIR="$SCRIPT_DIR"
DOCS_DIR="$SCRIPT_DIR/docs"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --bin-dir)
            [ "$#" -ge 2 ] || die "--bin-dir needs a value"
            BIN_DIR="$2"
            shift 2
            ;;
        --tor-dir)
            [ "$#" -ge 2 ] || die "--tor-dir needs a value"
            TOR_DIR="$2"
            shift 2
            ;;
        --version)
            [ "$#" -ge 2 ] || die "--version needs a value"
            VERSION="$2"
            shift 2
            ;;
        --out)
            [ "$#" -ge 2 ] || die "--out needs a value"
            OUT="$2"
            shift 2
            ;;
        --launcher-dir)
            [ "$#" -ge 2 ] || die "--launcher-dir needs a value"
            LAUNCHER_DIR="$2"
            shift 2
            ;;
        --docs-dir)
            [ "$#" -ge 2 ] || die "--docs-dir needs a value"
            DOCS_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1 (try --help)"
            ;;
    esac
done

[ -n "$BIN_DIR" ] || die "--bin-dir is required (try --help)"
[ -n "$TOR_DIR" ] || die "--tor-dir is required (try --help)"
[ -n "$VERSION" ] || die "--version is required (try --help)"
[ -n "$OUT" ] || die "--out is required (try --help)"

for tool in sha256sum find sort sed awk tr date cat cp mkdir rm wc basename dirname; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

case "$VERSION" in
    v*) VERSION="${VERSION#v}" ;;
esac
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?$ ]]; then
    die "--version must look like x.y.z (optional leading v, optional suffix), got: ${VERSION:-<empty>}"
fi

[ -d "$BIN_DIR" ] || die "--bin-dir not found: $BIN_DIR"
[ -d "$TOR_DIR" ] || die "--tor-dir not found: $TOR_DIR"
[ -d "$LAUNCHER_DIR" ] || die "--launcher-dir not found: $LAUNCHER_DIR"
[ -d "$DOCS_DIR" ] || die "--docs-dir not found: $DOCS_DIR"

[ -f "$REPO_ROOT/LICENSE" ] || die "LICENSE not found at $REPO_ROOT/LICENSE (run this script from a repository checkout)"
PATCHES=("$REPO_ROOT"/patches/*.patch)
[ -e "${PATCHES[0]}" ] || die "no patches/*.patch under $REPO_ROOT"

for f in cachecoind.exe cachecoin-cli.exe; do
    [ -f "$BIN_DIR/$f" ] || die "missing binary: $BIN_DIR/$f"
done
TOR_MODE=""
if [ -f "$TOR_DIR/tor.exe" ]; then
    TOR_MODE="flat"
elif [ -f "$TOR_DIR/tor/tor.exe" ]; then
    TOR_MODE="bundle"
else
    die "tor.exe not found: expected $TOR_DIR/tor.exe or $TOR_DIR/tor/tor.exe"
fi
[ -f "$LAUNCHER_DIR/launcher/CacheCoin.ps1" ] || die "missing launcher: $LAUNCHER_DIR/launcher/CacheCoin.ps1"
[ -f "$LAUNCHER_DIR/CacheCoin.cmd" ] || die "missing launcher shim: $LAUNCHER_DIR/CacheCoin.cmd"
[ -f "$LAUNCHER_DIR/tools/CacheCoin-Keys.ps1" ] || die "missing keys tool: $LAUNCHER_DIR/tools/CacheCoin-Keys.ps1"
[ -f "$LAUNCHER_DIR/tools/CacheCoin-Status.ps1" ] || die "missing status tool: $LAUNCHER_DIR/tools/CacheCoin-Status.ps1"
[ -f "$LAUNCHER_DIR/Start Node.cmd" ] || die "missing entry point: $LAUNCHER_DIR/Start Node.cmd"
[ -f "$LAUNCHER_DIR/Start Mining.cmd" ] || die "missing entry point: $LAUNCHER_DIR/Start Mining.cmd"
[ -f "$LAUNCHER_DIR/Check Status.cmd" ] || die "missing entry point: $LAUNCHER_DIR/Check Status.cmd"
[ -f "$LAUNCHER_DIR/My Keys and Backup.cmd" ] || die "missing entry point: $LAUNCHER_DIR/My Keys and Backup.cmd"

BIN_DIR="$(cd "$BIN_DIR" && pwd)"
TOR_DIR="$(cd "$TOR_DIR" && pwd)"
LAUNCHER_DIR="$(cd "$LAUNCHER_DIR" && pwd)"
DOCS_DIR="$(cd "$DOCS_DIR" && pwd)"
mkdir -p -- "$OUT" || die "cannot create --out: $OUT"
OUT="$(cd "$OUT" && pwd)"
[ "$OUT" != "/" ] || die "--out must not be the filesystem root"

PATCH_FP="$(cat -- "${PATCHES[@]}" | sha256sum | awk '{print $1}')"
BUILT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

PKG_NAME="CacheCoin-Windows-$VERSION"
PKG="$OUT/$PKG_NAME"
ZIP="$OUT/$PKG_NAME.zip"

rm -rf -- "$PKG"
rm -f -- "$ZIP"
mkdir -p -- "$PKG/bin" "$PKG/tor" "$PKG/launcher" "$PKG/docs"

cp -- "$BIN_DIR/cachecoind.exe" "$PKG/bin/cachecoind.exe"
cp -- "$BIN_DIR/cachecoin-cli.exe" "$PKG/bin/cachecoin-cli.exe"
# The CI bin directory also carries the MinGW runtime/library DLLs the
# executables load; ship them next to the exes. The artifact's own
# SHA256SUMS.txt is not part of the package.
for f in "$BIN_DIR"/*; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in
        cachecoind.exe|cachecoin-cli.exe|SHA256SUMS.txt) continue ;;
    esac
    cp -- "$f" "$PKG/bin/"
done

if [ "$TOR_MODE" = "bundle" ]; then
    cp -R -- "$TOR_DIR/tor"/. "$PKG/tor/"
    if [ -d "$TOR_DIR/data" ]; then cp -R -- "$TOR_DIR/data" "$PKG/tor/data"; fi
    if [ -d "$TOR_DIR/docs" ]; then cp -R -- "$TOR_DIR/docs" "$PKG/tor/docs"; fi
else
    cp -R -- "$TOR_DIR"/. "$PKG/tor/"
fi
if [ -z "$(find "$PKG/tor" -maxdepth 2 -type f \( -iname 'license*' -o -iname 'copying*' -o -iname 'tor.txt' \) -print -quit)" ]; then
    die "the copied Tor files contain no license file (tor.txt); check --tor-dir"
fi

cp -R -- "$LAUNCHER_DIR/launcher"/. "$PKG/launcher/"
for f in "$LAUNCHER_DIR"/*.cmd; do
    [ -f "$f" ] || continue
    cp -- "$f" "$PKG/$(basename "$f")"
done
mkdir -p -- "$PKG/tools"
cp -R -- "$LAUNCHER_DIR/tools"/. "$PKG/tools/"

cp -R -- "$DOCS_DIR"/. "$PKG/docs/"
for f in README.md SECURITY.md; do
    if [ -f "$REPO_ROOT/$f" ]; then
        cp -- "$REPO_ROOT/$f" "$PKG/docs/$f"
    fi
done
cp -- "$REPO_ROOT/LICENSE" "$PKG/LICENSE"

json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

package_files() {
    ( cd "$PKG" && find . -type f \
        ! -name 'version.json' \
        ! -name 'SHA256SUMS.windows.txt' \
        ! -name 'SHA256SUMS.windows.txt.asc' \
        | LC_ALL=C sort | sed 's|^\./||' )
}

file_hash() {
    sha256sum -- "$PKG/$1" | awk '{print $1}'
}

total="$(package_files | wc -l | tr -d ' ')"
[ "$total" -gt 0 ] || die "package has no files, something went wrong"

{
    printf '{\n'
    printf '  "package_version": "%s",\n' "$(json_escape "$VERSION")"
    printf '  "built_utc": "%s",\n' "$BUILT_UTC"
    printf '  "base_pins": {\n'
    printf '    "bitcoin": "%s",\n' "$BITCOIN_PIN"
    printf '    "randomx": "%s"\n' "$RANDOMX_PIN"
    printf '  },\n'
    printf '  "patch_fingerprint": "%s",\n' "$PATCH_FP"
    printf '  "files": {\n'
    n=0
    while IFS= read -r rel; do
        n=$((n + 1))
        if [ "$n" -lt "$total" ]; then
            comma=','
        else
            comma=''
        fi
        printf '    "%s": "%s"%s\n' "$(json_escape "$rel")" "$(file_hash "$rel")" "$comma"
    done < <(package_files)
    printf '  }\n'
    printf '}\n'
} > "$PKG/version.json"

SUM_FILES=()
while IFS= read -r rel; do
    SUM_FILES+=("$rel")
done < <( cd "$PKG" && find . -type f \
    ! -name 'SHA256SUMS.windows.txt' \
    ! -name 'SHA256SUMS.windows.txt.asc' \
    | LC_ALL=C sort | sed 's|^\./||' )

( cd "$PKG" && sha256sum -- "${SUM_FILES[@]}" > SHA256SUMS.windows.txt )
( cd "$PKG" && sha256sum --check --quiet SHA256SUMS.windows.txt ) \
    || die "SHA256SUMS.windows.txt self-check failed"

if command -v zip >/dev/null 2>&1; then
    ZIP_BACKEND="zip"
elif command -v python3 >/dev/null 2>&1; then
    ZIP_BACKEND="python3"
elif command -v python >/dev/null 2>&1; then
    ZIP_BACKEND="python"
elif command -v powershell.exe >/dev/null 2>&1; then
    ZIP_BACKEND="powershell"
else
    die "no zip backend found: install zip or python3, or run from MSYS2 with powershell.exe on PATH"
fi

case "$ZIP_BACKEND" in
    zip)
        ( cd "$OUT" && zip -r -q -X "$PKG_NAME.zip" "$PKG_NAME" )
        ;;
    python3|python)
        "$ZIP_BACKEND" - "$PKG" "$ZIP" <<'PYEOF'
import os
import sys
import zipfile

pkg = sys.argv[1]
dest = sys.argv[2]
base = os.path.dirname(pkg.rstrip("/\\"))

if os.path.exists(dest):
    os.remove(dest)

with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as zf:
    for root, dirs, files in os.walk(pkg):
        dirs.sort()
        for name in sorted(files):
            path = os.path.join(root, name)
            arc = os.path.relpath(path, base).replace(os.sep, "/")
            info = zipfile.ZipInfo(arc, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            with open(path, "rb") as fh:
                zf.writestr(info, fh.read())
PYEOF
        ;;
    powershell)
        TMP_PS1="$(mktemp --suffix=.ps1 "${TMPDIR:-/tmp}/cccn-zip.XXXXXX")"
        trap 'rm -f -- "$TMP_PS1"' EXIT
        cat > "$TMP_PS1" <<'PSEOF'
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$src = $env:CCCN_PKG
$dst = $env:CCCN_ZIP
$prefix = Split-Path -Leaf $src
if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Force }
$zip = [System.IO.Compression.ZipFile]::Open($dst, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    Get-ChildItem -LiteralPath $src -Recurse -File | Sort-Object FullName | ForEach-Object {
        $rel = $_.FullName.Substring($src.Length + 1).Replace('\', '/')
        $entry = $zip.CreateEntry("$prefix/$rel", [System.IO.Compression.CompressionLevel]::Optimal)
        $out = $entry.Open()
        $in = [System.IO.File]::OpenRead($_.FullName)
        try { $in.CopyTo($out) } finally { $in.Dispose(); $out.Dispose() }
    }
} finally {
    $zip.Dispose()
}
PSEOF
        ps1_w="$TMP_PS1"
        pkg_w="$PKG"
        zip_w="$ZIP"
        if command -v cygpath >/dev/null 2>&1; then
            ps1_w="$(cygpath -w "$TMP_PS1")"
            pkg_w="$(cygpath -w "$PKG")"
            zip_w="$(cygpath -w "$ZIP")"
        elif command -v wslpath >/dev/null 2>&1; then
            ps1_w="$(wslpath -w "$TMP_PS1")"
            pkg_w="$(wslpath -w "$PKG")"
            zip_w="$(wslpath -w "$ZIP")"
        fi
        CCCN_PKG="$pkg_w" CCCN_ZIP="$zip_w" WSLENV="CCCN_PKG:CCCN_ZIP" powershell.exe -NoProfile -NonInteractive \
            -ExecutionPolicy Bypass -File "$ps1_w"
        rm -f -- "$TMP_PS1"
        trap - EXIT
        ;;
esac

[ -f "$ZIP" ] || die "zip was not created: $ZIP"
ZIP_SHA="$(sha256sum -- "$ZIP" | awk '{print $1}')"
SUM_COUNT="$(wc -l < "$PKG/SHA256SUMS.windows.txt" | tr -d ' ')"

echo
note "package version:   $VERSION"
note "patch fingerprint: $PATCH_FP"
note "files checksummed: $SUM_COUNT"
note "package dir:       $PKG"
note "zip:               $ZIP"
note "zip sha256:        $ZIP_SHA"
echo
echo "Next: verify SHA256SUMS.windows.txt inside the package, sign it offline"
echo "with the release GPG key (doc/release.md), and keep the .asc next to the"
echo "zip. Publish with windows/release-notes-template.md; see windows/README.md."
