[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $PSScriptRoot
$script:DataDir = Join-Path $env:APPDATA 'CacheCoin'
$script:Cli = Join-Path $script:Root 'bin\cachecoin-cli.exe'
$script:Daemon = Join-Path $script:Root 'bin\cachecoind.exe'
$script:Conf = Join-Path $script:DataDir 'cachecoin.conf'
$script:StartedNode = $false
$script:NodeProcess = $null

. (Join-Path $PSScriptRoot 'CacheCoin-Package.ps1')

function Pause-Exit {
    Read-Host 'Press Enter to close this window' | Out-Null
}

function Invoke-Cli {
    param([string[]]$Arguments)
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & $script:Cli "-datadir=$($script:DataDir)" @Arguments 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $oldEap
    return [pscustomobject]@{ Code = $code; Out = (($out | Out-String).Trim()) }
}

function Test-Rpc {
    return ((Invoke-Cli @('getblockcount')).Code -eq 0)
}

function Get-NodeProcesses {
    return @(Get-CimInstance Win32_Process -Filter "Name='cachecoind.exe'" -ErrorAction SilentlyContinue |
        Where-Object { ([string]$_.CommandLine).IndexOf($script:DataDir, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 })
}

function Start-ToolNode {
    $out = Join-Path $env:TEMP 'cachecoin-keys-node-out.log'
    $err = Join-Path $env:TEMP 'cachecoin-keys-node-err.log'
    try {
        $script:NodeProcess = Start-Process -FilePath $script:Daemon -ArgumentList @("`"-datadir=$($script:DataDir)`"", "`"-conf=$($script:Conf)`"", '-printtoconsole=0') -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
        $null = $script:NodeProcess.Handle
        $script:StartedNode = $true
    } catch {
        return $false
    }
    for ($i = 0; $i -lt 120; $i++) {
        Start-Sleep -Seconds 1
        if (Test-Rpc) { return $true }
        if ($script:NodeProcess.HasExited) { return $false }
    }
    return $false
}

function Stop-ToolNode {
    if (-not $script:StartedNode) { return }
    $null = Invoke-Cli @('stop')
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 1
        if ($script:NodeProcess -and $script:NodeProcess.HasExited) { return }
    }
    try { Stop-Process -Id $script:NodeProcess.Id -Force -ErrorAction SilentlyContinue } catch { }
}

function Save-Backup {
    Write-Host ''
    $p = Read-Host 'Folder for the backup files (for example E:\cachecoin-backup)'
    if (-not $p) { return }
    $p = [Environment]::ExpandEnvironmentVariables($p.Trim().Trim('"'))
    $resolved = $null
    try { $resolved = (Resolve-Path -LiteralPath $p -ErrorAction Stop).Path } catch {
        try {
            New-Item -ItemType Directory -Path $p -Force | Out-Null
            $resolved = (Resolve-Path -LiteralPath $p).Path
        } catch {
            Write-Host 'That folder could not be used.'
            return
        }
    }
    if ($resolved -match '(?i)\\(OneDrive|Dropbox|Google ?Drive|My ?Drive|iCloud|MEGAsync|pCloud|Nextcloud|Syncthing|YandexDisk|Box|SharePoint|Creative Cloud Files)(\\|$)') {
        Write-Host 'Warning: that folder syncs to the cloud, so the backup would leave this computer.'
        $go = Read-Host 'Continue anyway? Type YES'
        if ($go -cne 'YES') { Write-Host 'Cancelled.'; return }
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $bak = Join-Path $resolved "cachecoin-main-wallet-$stamp.bak"
    $json = Join-Path $resolved "cachecoin-main-descriptors-$stamp.json"
    $b = Invoke-Cli @('-rpcwallet=main', 'backupwallet', $bak)
    if ($b.Code -ne 0) {
        Write-Host "The wallet backup failed: $($b.Out)"
        return
    }
    $d = Invoke-Cli @('-rpcwallet=main', 'listdescriptors', 'true')
    if ($d.Code -ne 0 -or -not $d.Out) {
        Write-Host 'The key export failed; the wallet file was saved, but make another backup later.'
        return
    }
    try { $null = $d.Out | ConvertFrom-Json } catch {
        Write-Host 'The key export was not valid JSON; nothing was saved.'
        return
    }
    try { [System.IO.File]::WriteAllText($json, $d.Out, (New-Object System.Text.UTF8Encoding($false))) } catch {
        Write-Host 'Could not write the key file.'
        return
    }
    $h1 = (Get-FileHash -LiteralPath $bak -Algorithm SHA256).Hash.ToLowerInvariant()
    $h2 = (Get-FileHash -LiteralPath $json -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Host ''
    Write-Host 'Backup saved:'
    Write-Host "  $bak"
    Write-Host "    sha256 $h1"
    Write-Host "  $json"
    Write-Host "    sha256 $h2"
    Write-Host ''
    Write-Host 'Keep these files offline. Anyone who has either file can take your coins.'
    Write-Host 'If this is a USB stick, unplug it and keep it somewhere safe.'
}

function Show-Keys {
    Write-Host ''
    Write-Host 'WARNING: the next step shows your private keys on this screen.'
    Write-Host 'Anyone who sees or photographs them can take all your coins.'
    Write-Host 'There is no seed phrase and no way to undo a leak.'
    Write-Host ''
    $net = Read-Host 'If your internet is still on, turn it off now (Wi-Fi or cable). Type YES to continue'
    if ($net -cne 'YES') { Write-Host 'Cancelled.'; return }
    $phrase = Read-Host 'Type exactly: I will keep them offline'
    if ($phrase -cne 'I will keep them offline') { Write-Host 'The phrase did not match. Cancelled.'; return }
    $d = Invoke-Cli @('-rpcwallet=main', 'listdescriptors', 'true')
    if ($d.Code -ne 0 -or -not $d.Out) {
        Write-Host 'The key export failed.'
        return
    }
    Write-Host ''
    Write-Host '=== YOUR PRIVATE KEYS (never share this screen or text) ==='
    Write-Host $d.Out
    Write-Host '=== END ==='
    Write-Host ''
    Write-Host 'The strings that start with xprv are your private keys.'
    Write-Host 'Copy them to paper or an offline USB stick only. Never email, chat,'
    Write-Host 'cloud-sync, screenshot or type them into a website.'
    Write-Host ''
    Read-Host 'Press Enter to clear the screen' | Out-Null
    Clear-Host
    Write-Host 'The screen was cleared. Close this window when you are done.'
}

Write-Host ''
Write-Host 'CacheCoin keys and wallet backup'
Write-Host '================================'
Write-Host ''
Write-Host 'This tool can:'
Write-Host '  1) save your wallet backup files to a folder or USB (recommended), or'
Write-Host '  2) show your private keys on screen (advanced).'
Write-Host ''
Write-Host 'Rules:'
Write-Host '- Anyone who has your keys or backup files can take your coins.'
Write-Host '- There is no seed phrase and no recovery service.'
Write-Host '- Save them offline: USB stick or paper. Never cloud, email, chat,'
Write-Host '  screenshots or screen sharing.'
Write-Host '- Do this only on a computer you trust; malware can steal keys.'
Write-Host ''

if (-not (Test-Path -LiteralPath $script:Cli) -or -not (Test-Path -LiteralPath $script:Daemon)) {
    Write-Host 'The CacheCoin programs were not found next to this script.'
    Write-Host 'Unpack the whole ZIP first, then run this file from the package folder.'
    Pause-Exit
    exit 1
}
if (-not (Test-PackageIntegrity -Root $script:Root)) {
    Write-Host 'This package does not match its version.json file.'
    Write-Host 'Do not trust it with your keys. Download the package again and verify'
    Write-Host 'it with docs\VERIFY.txt before running this tool.'
    Pause-Exit
    exit 1
}
if (-not (Test-Path -LiteralPath $script:Conf)) {
    Write-Host 'CacheCoin has not run on this computer yet.'
    Write-Host 'Start it once with "Start Node.cmd", then run this tool again.'
    Pause-Exit
    exit 1
}

try {
    if (-not (Test-Rpc)) {
        if ((Get-NodeProcesses).Count -gt 0) {
            for ($i = 0; $i -lt 120 -and -not (Test-Rpc); $i++) { Start-Sleep -Seconds 1 }
        } else {
            Write-Host 'Starting the node for this tool (no internet needed)...'
            $null = Start-ToolNode
        }
        if (-not (Test-Rpc)) {
            Write-Host 'The node did not answer. Start it with "Start Node.cmd" and try again.'
            Pause-Exit
            exit 1
        }
    }

    $w = Invoke-Cli @('listwallets')
    if (-not ($w.Code -eq 0 -and $w.Out -match '"main"')) {
        $lw = Invoke-Cli @('loadwallet', 'main')
        if ($lw.Code -ne 0) {
            Write-Host 'No wallet named "main" was found on this computer.'
            Write-Host 'Start mining once ("Start Mining.cmd") to create it, or restore a backup.'
            Write-Host 'The restore steps are in docs\BACKUP.txt.'
            Pause-Exit
            exit 1
        }
    }

    while ($true) {
        Write-Host ''
        Write-Host 'What do you want to do?'
        Write-Host '  1) Save my wallet backup files to a folder or USB (recommended)'
        Write-Host '  2) Show my private keys on screen (advanced)'
        Write-Host '  3) Exit'
        $choice = Read-Host 'Type 1, 2 or 3'
        if ($choice -eq '1') { Save-Backup }
        elseif ($choice -eq '2') { Show-Keys }
        else { break }
    }
} finally {
    Stop-ToolNode
}

Write-Host ''
Write-Host 'Done. Keep your backup files offline.'
Pause-Exit
