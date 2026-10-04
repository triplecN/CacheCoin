function Get-PackageSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-PackageIntegrity {
    param([string]$Root)
    $versionFile = Join-Path $Root 'version.json'
    if (-not (Test-Path -LiteralPath $versionFile)) { return $false }
    $manifest = $null
    try { $manifest = Get-Content -LiteralPath $versionFile -Raw | ConvertFrom-Json } catch { return $false }
    if (-not $manifest.files) { return $false }
    $map = @{}
    foreach ($prop in $manifest.files.PSObject.Properties) {
        $map[($prop.Name -replace '\\', '/')] = [string]$prop.Value
    }
    foreach ($req in @('bin/cachecoind.exe', 'bin/cachecoin-cli.exe', 'launcher/CacheCoin.ps1', 'tools/CacheCoin-Keys.ps1', 'tools/CacheCoin-Status.ps1', 'tools/CacheCoin-Package.ps1')) {
        if (-not $map.ContainsKey($req)) { return $false }
    }
    foreach ($name in $map.Keys) {
        $rel = $name -replace '/', '\'
        $full = Join-Path $Root $rel
        if (-not (Test-Path -LiteralPath $full)) {
            if ($rel -match '^(bin|tor|tools|launcher)\\') { return $false }
            continue
        }
        if ((Get-PackageSha256 $full) -ne $map[$name].ToLowerInvariant()) { return $false }
    }
    return $true
}
