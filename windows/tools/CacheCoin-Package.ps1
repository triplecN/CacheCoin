function Get-PackageSha256 {
    param([string]$Path)
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() }
    catch { return '' }
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
    foreach ($req in @('bin/cachecoind.exe', 'bin/cachecoin-cli.exe', 'tor/tor.exe', 'launcher/CacheCoin.ps1', 'tools/CacheCoin-NewWallet.ps1', 'tools/CacheCoin-Status.ps1', 'tools/CacheCoin-Package.ps1')) {
        if (-not $map.ContainsKey($req)) { return $false }
    }
    foreach ($name in $map.Keys) {
        if ($name -match '(^|/)\.\.(/|$)' -or $name.StartsWith('/') -or $name.StartsWith('\') -or $name.Contains(':') -or ($name.TrimEnd(' ', '.') -ne $name)) { return $false }
        $rel = $name -replace '/', '\'
        $full = Join-Path $Root $rel
        if (-not (Test-Path -LiteralPath $full)) { return $false }
        if ((Get-PackageSha256 $full) -ne $map[$name].ToLowerInvariant()) { return $false }
    }
    # A program the manifest does not cover is a supply-chain hole, not a warning.
    $dangerous = @('.exe', '.cmd', '.bat', '.ps1', '.dll', '.com', '.scr', '.msi', '.vbs', '.vbe', '.js', '.jse', '.wsf', '.wsh', '.hta', '.cpl', '.ocx', '.lnk', '.chm', '.psm1', '.psd1', '.jar', '.config', '.manifest', '.scf', '.pif', '.inf', '.msc', '.reg', '.py', '.pyw', '.pyc', '.pyz', '.ps1xml', '.psc1', '.psc2', '.msix', '.msixbundle', '.appx', '.appxbundle', '.appinstaller', '.diagcab', '.gadget', '.url', '.website', '.appref-ms', '.xll', '.xla')
    $unlisted = @()
    $rootFull = $Root.TrimEnd('\')
    $rootOfRoot = ([System.IO.Path]::GetPathRoot($Root)).TrimEnd('\')
    if ($rootOfRoot -ieq $rootFull) { return $false }
    try {
        if (((Get-Item -LiteralPath $Root -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        $items = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction Stop)
        foreach ($it in $items) {
            if (($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            if ($it.PSIsContainer) { continue }
            $ext = [System.IO.Path]::GetExtension($it.Name.TrimEnd(' ', '.')).ToLowerInvariant()
            if ($dangerous -notcontains $ext) { continue }
            $rel = ($it.FullName.Substring($Root.Length).TrimStart('\') -replace '\\', '/')
            if (-not $map.ContainsKey($rel)) { $unlisted += $rel }
        }
    } catch { return $false }
    if ($unlisted.Count -gt 0) { return $false }
    return $true
}
