# CacheCoin Windows package - one-command verification.
# Checks version.json, every packaged file hash, the checksum list, and, when
# GnuPG and the detached signature are available, the release signature.
# Reads PROVENANCE.txt on request. Exit code 0 = hashes consistent, 1 = failed.
# No network access; read-only.
param([switch]$ShowProvenance)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$releaseKey = '7D85B6F364CC47BA9209BB54F750900C7C911728'
$script:fail = $false
$script:signature = 'not checked'
function Fail([string]$m) { Write-Host ("FAIL  " + $m) -ForegroundColor Red; $script:fail = $true }
function Ok([string]$m) { Write-Host ("ok    " + $m) -ForegroundColor Green }
function Note([string]$m) { Write-Host ("note  " + $m) -ForegroundColor Yellow }

Write-Host "CacheCoin package verification"
Write-Host ("Package root: " + $root)
Write-Host ""

$versionFile = Join-Path $root 'version.json'
if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) { Fail 'version.json is missing' }
if (-not $script:fail) {
    try { $manifest = Get-Content -LiteralPath $versionFile -Raw | ConvertFrom-Json } catch { Fail 'version.json is not valid JSON' }
}
if (-not $script:fail) {
    try {
        $manifestFiles = @($manifest.files.PSObject.Properties | ForEach-Object { ($_.Name -replace '\\', '/') })
    } catch { Fail 'version.json has no files list' }
    if (-not $manifestFiles -or $manifestFiles.Count -eq 0) { Fail 'version.json has no files list' }
}

if (-not $script:fail) {
    $pkgTool = Join-Path $PSScriptRoot 'CacheCoin-Package.ps1'
    if (-not (Test-Path -LiteralPath $pkgTool -PathType Leaf)) { Fail 'tools\CacheCoin-Package.ps1 is missing' }
}
if (-not $script:fail) {
    try {
        . $pkgTool
        if (Test-PackageIntegrity -Root $root) { Ok ("manifest and file hashes (" + $manifestFiles.Count + " files)") }
        else { Fail 'manifest check failed: a listed file is missing or modified, or a program file is not listed' }
    } catch { Fail ('manifest check raised: ' + $_.Exception.Message) }
}

$sums = Join-Path $root 'SHA256SUMS.windows.txt'
if (-not $script:fail) {
    if (-not (Test-Path -LiteralPath $sums -PathType Leaf)) { Fail 'SHA256SUMS.windows.txt is missing' }
    else {
        try { $sumLines = @(Get-Content -LiteralPath $sums) } catch { Fail ('cannot read SHA256SUMS.windows.txt: ' + $_.Exception.Message); $sumLines = @() }
        $bad = 0; $listed = @()
        foreach ($line in $sumLines) {
            if ($line -match '^([0-9a-fA-F]{64})  (.+)$') {
                $want = $matches[1].ToLowerInvariant(); $name = $matches[2]; $listed += $name
                try {
                    $full = Join-Path $root ($name -replace '/', '\')
                    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { Fail ("listed in SHA256SUMS but missing: " + $name); $bad++; continue }
                    $got = (Get-FileHash -LiteralPath $full -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                    if ($got -ne $want) { Fail ("hash mismatch: " + $name); $bad++ }
                } catch { Fail ("cannot hash " + $name + ": " + $_.Exception.Message); $bad++ }
            } elseif ($line.Trim().Length -gt 0) { Fail ("unreadable line in SHA256SUMS.windows.txt: " + $line); $bad++ }
        }
        if ($listed.Count -eq 0) { Fail 'SHA256SUMS.windows.txt has no readable entries' }
        elseif ($bad -eq 0) { Ok ("checksum list (" + $listed.Count + " entries)") }
        if ($listed.Count -gt 0) {
            $expected = @($manifestFiles + 'version.json')
            $diff = Compare-Object -ReferenceObject ($expected | Sort-Object) -DifferenceObject ($listed | Sort-Object)
            if ($diff) {
                Fail 'SHA256SUMS.windows.txt and version.json list different files'
                $diff | ForEach-Object { Write-Host ("      " + $_.SideIndicator + " " + $_.InputObject) }
            }
        }
    }
}

if (-not $script:fail) {
    $ascHere = Join-Path $root 'SHA256SUMS.windows.txt.asc'
    $ascAbove = Join-Path (Split-Path -Parent $root) 'SHA256SUMS.windows.txt.asc'
    $asc = $null
    if (Test-Path -LiteralPath $ascHere -PathType Leaf) { $asc = $ascHere }
    elseif (Test-Path -LiteralPath $ascAbove -PathType Leaf) { $asc = $ascAbove }
    if (-not $asc) {
        Note 'authenticity not checked: SHA256SUMS.windows.txt.asc was not found (looked in the package folder and its parent). Get it from the official release page; the ZIP hash and this signature are the trust anchors.'
    } else {
        $gpg = Get-Command gpg -ErrorAction SilentlyContinue
        if (-not $gpg) {
            Note ('authenticity not checked: GnuPG is not installed. Install Gpg4win and verify ' + $asc + ' yourself.')
        } else {
            $oldEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $out = (& $gpg.Source --status-fd 1 --verify $asc $sums 2>&1) | Out-String
                $rc = $LASTEXITCODE
            } finally { $ErrorActionPreference = $oldEap }
            $status = (($out -split "`n") | Where-Object { $_ -match '^\[GNUPG:\]' }) -join "`n"
            if ($rc -eq 0 -and $status -match ('(?m)^\[GNUPG:\] VALIDSIG ' + $releaseKey + '( |$)')) {
                if ($status -match '(?m)^\[GNUPG:\] (REVKEYSIG|EXPKEYSIG|BADSIG)') { Fail 'GPG signature is not acceptable (revoked, expired or bad)' }
                else { Ok 'GPG signature (release key ' + $releaseKey + ')'; $script:signature = 'verified' }
            } else {
                Fail 'GPG signature check failed: not signed by the CacheCoin release key, or the signature is invalid'
            }
        }
    }
}

Write-Host ""
if ($script:fail) { Write-Host "RESULT: FAIL - do not run this package; download a fresh copy from the official source." -ForegroundColor Red; exit 1 }
if ($script:signature -eq 'verified') {
    Write-Host "RESULT: PASS - file hashes are consistent and the GPG signature is verified." -ForegroundColor Green
} else {
    Write-Host "RESULT: PASS - file hashes are consistent. The GPG signature was NOT checked (see the note above); authenticity is not established by this run." -ForegroundColor Green
}

$prov = Join-Path $root 'PROVENANCE.txt'
if (Test-Path -LiteralPath $prov -PathType Leaf) {
    if ($ShowProvenance) { Write-Host ""; Get-Content -LiteralPath $prov }
    else { Write-Host ("Provenance: " + $prov + " (run tools\CacheCoin-Verify.ps1 -ShowProvenance to print it)") }
}
exit 0
