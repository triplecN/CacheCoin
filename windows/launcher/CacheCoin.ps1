[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$Silent,
    [ValidateSet('node', 'mining')][string]$Mode,
    [int]$RunSeconds = 0
)

$ErrorActionPreference = 'Stop'

$script:Root = Split-Path -Parent $PSScriptRoot
$script:DataDir = Join-Path $env:APPDATA 'CacheCoin'
$script:LogDir = Join-Path $script:DataDir 'logs'
$script:LogFile = Join-Path $script:LogDir 'launcher.log'
$script:ConfPath = Join-Path $script:DataDir 'cachecoin.conf'
$script:Daemon = Join-Path $script:Root 'bin\cachecoind.exe'
$script:Cli = Join-Path $script:Root 'bin\cachecoin-cli.exe'
$script:TorExe = Join-Path $script:Root 'tor\tor.exe'
$script:VersionFile = Join-Path $script:Root 'version.json'
$script:StateFile = Join-Path $script:LogDir 'launcher-state.json'
$script:Seed = 'ag7rydtma6dt5fonz76sdbecrbugq3uln7cc6ddvg2c2jngio4lw6mid.onion:29333'

$script:TorProcess = $null
$script:NodeProcess = $null
$script:NodeStartedByUs = $false
$script:AttachedToExisting = $false
$script:StartedTor = $false
$script:Mining = $false
$script:MiningGated = $false
$script:MiningJobs = @()
$script:StopRequested = $false
$script:Tray = $null
$script:ProxyPort = 0
$script:Address = ''
$script:Attempts = 0
$script:FoundBlocks = 0
$script:LastTipTime = 0
$script:LastMiningErrorLog = $null

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f ([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')), $Level, $Message
    try {
        if (-not (Test-Path -LiteralPath $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
        Add-Content -LiteralPath $script:LogFile -Value $line
    } catch { }
    if (-not $Silent) { Write-Host $line }
}

function Fail {
    param([string]$Message)
    Write-Log $Message 'ERROR'
    if (-not $Silent) {
        try {
            Add-Type -AssemblyName System.Windows.Forms | Out-Null
            [System.Windows.Forms.MessageBox]::Show($Message, 'CacheCoin') | Out-Null
        } catch { }
    }
    exit 1
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-PackageHashes {
    if (-not (Test-Path -LiteralPath $script:VersionFile)) {
        Write-Log 'No version.json found; file hashes are not being verified.' 'WARN'
        return
    }
    $manifest = $null
    try { $manifest = Get-Content -LiteralPath $script:VersionFile -Raw | ConvertFrom-Json } catch { Fail 'version.json is unreadable. Download the package again.' }
    if (-not $manifest.files) {
        Write-Log 'version.json lists no files; hashes are not being verified.' 'WARN'
        return
    }
    foreach ($prop in $manifest.files.PSObject.Properties) {
        $rel = $prop.Name -replace '/', '\'
        $full = Join-Path $script:Root $rel
        if (-not (Test-Path -LiteralPath $full)) {
            if ($rel -match '^(bin|tor)\\') {
                Fail "A program file listed in version.json is missing: $rel. Download the package again."
            }
            Write-Log "Packaged file is missing: $rel" 'WARN'
            continue
        }
        $actual = Get-Sha256 $full
        if ($actual -ne ([string]$prop.Value).ToLowerInvariant()) {
            Fail ("A file does not match the published hash: {0}`nExpected: {1}`nFound:    {2}`nDo not run this copy; download it again." -f $rel, $prop.Value, $actual)
        }
    }
    Write-Log 'Package files match version.json.'
}

function Test-TcpPort {
    param([string]$TargetHost, [int]$Port, [int]$TimeoutMs = 1500)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Wait-TcpPort {
    param([string]$TargetHost, [int]$Port, [int]$Seconds)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-TcpPort -TargetHost $TargetHost -Port $Port) { return $true }
        Start-Sleep -Milliseconds 1000
    }
    return $false
}

function Get-TorProxy {
    if (Test-TcpPort -TargetHost '127.0.0.1' -Port 9050) { return 9050 }
    if (Test-TcpPort -TargetHost '127.0.0.1' -Port 9150) { return 9150 }
    return 0
}

function Start-BundledTor {
    if (-not (Test-Path -LiteralPath $script:TorExe)) { return $false }
    $torDir = Join-Path $script:DataDir 'tor'
    if (-not (Test-Path -LiteralPath $torDir)) { New-Item -ItemType Directory -Path $torDir -Force | Out-Null }
    $torrc = Join-Path $torDir 'torrc'
    $lines = @(
        'SocksPort 127.0.0.1:9050',
        'ControlPort 127.0.0.1:9051',
        'CookieAuthentication 1',
        'ClientOnly 1',
        'SafeLogging 1'
    )
    Set-Content -LiteralPath $torrc -Value $lines -Encoding ASCII
    Write-Log 'Starting the bundled Tor...'
    $script:TorProcess = Start-Process -FilePath $script:TorExe -ArgumentList @('-f', "`"$torrc`"") -WindowStyle Hidden -PassThru
    $script:StartedTor = $true
    if (Wait-TcpPort -TargetHost '127.0.0.1' -Port 9050 -Seconds 90) { return $true }
    Write-Log 'The bundled Tor did not open port 9050 in time.' 'WARN'
    return $false
}

function Test-Preflight {
    try {
        $root = [System.IO.Path]::GetPathRoot($script:DataDir)
        $letter = $root.Substring(0, 1)
        $drive = Get-PSDrive -Name $letter -ErrorAction Stop
        if ($null -ne $drive.Free -and $drive.Free -lt 10GB) {
            Write-Log ('Low disk space: only {0:N1} GB free on {1}. The chain needs several GB.' -f ($drive.Free / 1GB), $root) 'WARN'
        }
    } catch { }
    try {
        $ram = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
        if ($ram -lt 4GB) { Write-Log 'Less than 4 GB of RAM detected; the node may be slow.' 'WARN' }
    } catch { }
    if ((Get-Date).Year -lt 2026) { Write-Log 'The system clock looks wrong. Fix the clock before mining.' 'WARN' }
}

function Initialize-Config {
    param([int]$ProxyPort, [bool]$Listen)
    if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
    $required = [ordered]@{
        'server'      = '1'
        'proxy'       = "127.0.0.1:$ProxyPort"
        'onlynet'     = 'onion'
        'dnsseed'     = '0'
        'discover'    = '0'
        'upnp'        = '0'
        'natpmp'      = '0'
        'addnode'     = $script:Seed
        'rpcbind'     = '127.0.0.1'
        'rpcallowip'  = '127.0.0.1'
        'fallbackfee' = '0.0001'
        'dbcache'     = '450'
        'maxmempool'  = '150'
        'rpcthreads'  = '8'
    }
    if ($Listen) {
        $required['listen'] = '1'
        $required['listenonion'] = '1'
        if ($ProxyPort -eq 9150) { $required['torcontrol'] = '127.0.0.1:9151' } else { $required['torcontrol'] = '127.0.0.1:9051' }
        if (-not $script:StartedTor) {
            Write-Log 'Incoming connections need a Tor with a control port; an external Tor without one will not create an onion service.' 'WARN'
        }
    } else {
        $required['listen'] = '0'
    }
    if (-not (Test-Path -LiteralPath $script:ConfPath)) {
        $content = @()
        foreach ($k in $required.Keys) { $content += "$k=$($required[$k])" }
        try { Set-Content -LiteralPath $script:ConfPath -Value $content -Encoding ASCII }
        catch { Fail "Could not write $($script:ConfPath): $($_.Exception.Message)" }
        Write-Log "Created $($script:ConfPath)"
        return
    }
    $raw = Get-Content -LiteralPath $script:ConfPath -Raw
    if ($null -eq $raw) { $raw = '' }
    $existing = $raw -split "`r?`n"
    $missing = @()
    foreach ($k in $required.Keys) {
        $found = $false
        foreach ($l in $existing) {
            if ($l -match ("^\s*" + [regex]::Escape($k) + "\s*=")) { $found = $true; break }
        }
        if (-not $found) { $missing += $k }
    }
    $proxyValue = [string]$required['proxy']
    $proxyChanged = $false
    $newLines = New-Object System.Collections.Generic.List[string]
    foreach ($l in $existing) {
        if ($l -match '^\s*proxy\s*=\s*127\.0\.0\.1:\d+\s*$' -and $l.Trim() -ne "proxy=$proxyValue") {
            $newLines.Add("proxy=$proxyValue")
            $proxyChanged = $true
            continue
        }
        $newLines.Add($l)
    }
    if ($missing.Count -gt 0) {
        foreach ($k in $missing) { $newLines.Add("$k=$($required[$k])") }
    }
    if ($missing.Count -gt 0 -or $proxyChanged) {
        try { Set-Content -LiteralPath $script:ConfPath -Value $newLines -Encoding ASCII }
        catch { Fail "Could not update $($script:ConfPath): $($_.Exception.Message)" }
        if ($missing.Count -gt 0) { Write-Log ('Added missing settings: ' + ($missing -join ', ')) }
        if ($proxyChanged) { Write-Log "Updated the local proxy setting to 127.0.0.1:$ProxyPort." }
    }
}

function Invoke-Rpc {
    param([string[]]$RpcArgs)
    try {
        $out = & $script:Cli "-datadir=$($script:DataDir)" @RpcArgs 2>&1
        if ($LASTEXITCODE -ne 0) { return $null }
        return ($out | Out-String).Trim()
    } catch {
        return $null
    }
}

function Wait-Rpc {
    param([int]$Seconds = 180)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (Invoke-Rpc @('getblockchaininfo')) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Start-Node {
    if (-not (Test-Path -LiteralPath $script:Daemon)) { Fail 'bin\cachecoind.exe is missing. Download the package again.' }
    if (-not (Test-Path -LiteralPath $script:Cli)) { Fail 'bin\cachecoin-cli.exe is missing. Download the package again.' }
    if (Invoke-Rpc @('getblockcount')) {
        Write-Log 'A CacheCoin node is already running; attaching to it.'
        $script:AttachedToExisting = $true
        return
    }
    Write-Log 'Starting the node...'
    try {
        $script:NodeProcess = Start-Process -FilePath $script:Daemon -ArgumentList @("`"-datadir=$($script:DataDir)`"", "`"-conf=$($script:ConfPath)`"") -WindowStyle Hidden -PassThru
    } catch {
        Fail "Could not start the node: $($_.Exception.Message)"
    }
    $script:NodeStartedByUs = $true
}

function Get-Status {
    $status = [ordered]@{
        Running  = $false
        Peers    = 0
        Height   = 0
        Headers  = 0
        IBD      = $true
        Balance  = 0.0
        Immature = 0.0
    }
    $c = Invoke-Rpc @('getconnectioncount')
    if ($null -eq $c) { return $status }
    $status.Running = $true
    try { $status.Peers = [int]$c } catch { }
    $b = Invoke-Rpc @('getblockchaininfo')
    if ($b) {
        try {
            $j = $b | ConvertFrom-Json
            $status.Height = [int]$j.blocks
            $status.Headers = [int]$j.headers
            $status.IBD = [bool]$j.initialblockdownload
        } catch { }
    }
    $bh = Invoke-Rpc @('getbestblockhash')
    if ($bh) {
        $hdr = Invoke-Rpc @('getblockheader', $bh.Trim())
        if ($hdr) {
            try { $script:LastTipTime = [long](($hdr | ConvertFrom-Json).time) } catch { }
        }
    }
    $bal = Invoke-Rpc @('-rpcwallet=main', 'getbalances')
    if ($bal) {
        try {
            $j2 = $bal | ConvertFrom-Json
            $status.Balance = [double]$j2.mine.trusted
            $status.Immature = [double]$j2.mine.immature
        } catch { }
    }
    return $status
}

function Write-StatusLine {
    param($Status)
    if (-not $Status) { $Status = Get-Status }
    $st = $Status
    if (-not $st.Running) {
        Write-Host 'The node is not answering. It may still be starting.'
        return
    }
    if ($st.IBD) {
        $pct = 100.0 * $st.Height / [Math]::Max(1, $st.Headers)
        Write-Host ('Syncing: block {0} of {1} ({2:N1}%). Peers: {3}.' -f $st.Height, $st.Headers, $pct, $st.Peers)
    } else {
        Write-Host ('Up to date at block {0}. Peers: {1}.' -f $st.Height, $st.Peers)
    }
    if ($script:Mining) {
        if ($script:MiningGated) {
            Write-Host 'Mining is paused (waiting for peers or a sane network clock).'
        } else {
            Write-Host ('Mining: {0} worker(s). Blocks found: {1}. Estimated attempts: {2}.' -f $script:MiningJobs.Count, $script:FoundBlocks, $script:Attempts)
        }
    }
    Write-Host ('Balance: {0} CCCN trusted, {1} CCCN immature (spendable after 100 blocks).' -f $st.Balance, $st.Immature)
}

function Get-MiningWorkerCount {
    $cores = [Environment]::ProcessorCount
    return [Math]::Min(4, [Math]::Max(1, $cores - 1))
}

function Start-MiningWorker {
    $job = Start-Job -ScriptBlock {
        param($CliPath, $DataDir, $Addr)
        $out = & $CliPath "-datadir=$DataDir" '-rpcwallet=main' '-rpcclienttimeout=0' 'generatetoaddress' '1' $Addr '500' 2>&1
        [pscustomobject]@{ Output = (($out | Out-String).Trim()); ExitCode = $LASTEXITCODE }
    } -ArgumentList $script:Cli, $script:DataDir, $script:Address
    $script:MiningJobs += $job
}

function Start-Mining {
    if ($script:Mining) { return }
    if (-not $script:Address) { Write-Log 'No mining address; not starting.' 'WARN'; return }
    $script:Mining = $true
    $script:MiningGated = $false
    $n = Get-MiningWorkerCount
    for ($i = 0; $i -lt $n; $i++) { Start-MiningWorker }
    Write-Log "Mining started with $n worker(s). Solo mining is a lottery; no reward is guaranteed."
}

function Stop-Mining {
    if (-not $script:Mining) { return }
    $script:Mining = $false
    foreach ($j in $script:MiningJobs) {
        Stop-Job -Job $j -ErrorAction SilentlyContinue
        Remove-Job -Job $j -Force -ErrorAction SilentlyContinue
    }
    $script:MiningJobs = @()
    Write-Log 'Mining paused.'
}

function Update-Mining {
    if (-not $script:Mining -or $script:MiningGated) { return }
    $finished = @($script:MiningJobs | Where-Object { $_.State -ne 'Running' -and $_.State -ne 'NotStarted' })
    foreach ($j in $finished) {
        $result = $null
        try { $result = Receive-Job -Job $j } catch { }
        Remove-Job -Job $j -Force -ErrorAction SilentlyContinue
        $script:MiningJobs = @($script:MiningJobs | Where-Object { $_.Id -ne $j.Id })
        $script:Attempts += 500
        if ($result -and $result.ExitCode -eq 0 -and $result.Output -match '[0-9a-f]{64}') {
            $script:FoundBlocks++
            $height = 0
            $h = Invoke-Rpc @('getblockcount')
            if ($h) { try { $height = [int]$h } catch { } }
            $reward = 5
            if ($height -gt 720) { $reward = 10 }
            Write-Log ('Block found! +{0} CCCN at height {1}. Spendable after 100 more blocks.' -f $reward, $height)
        } elseif ($result -and $result.ExitCode -ne 0) {
            if (-not $script:LastMiningErrorLog -or ((Get-Date) - $script:LastMiningErrorLog).TotalSeconds -ge 60) {
                $firstLine = ($result.Output -split "`r?`n")[0]
                Write-Log "A mining worker returned an error and will be retried: $firstLine" 'WARN'
                $script:LastMiningErrorLog = Get-Date
            }
        }
    }
    $target = Get-MiningWorkerCount
    while ($script:Mining -and -not $script:MiningGated -and $script:MiningJobs.Count -lt $target) { Start-MiningWorker }
}

function Update-MiningGate {
    if (-not $script:Mining) { return }
    $st = Get-Status
    if (-not $st.Running) { return }
    $reason = ''
    if ($st.Peers -eq 0) {
        $reason = 'No peers yet; mining will resume when the node connects.'
    } elseif ($script:LastTipTime -gt ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 300)) {
        $reason = 'The network clock is ahead of this computer; mining is paused.'
    }
    if ($reason -ne '') {
        if (-not $script:MiningGated) {
            $script:MiningGated = $true
            foreach ($j in $script:MiningJobs) {
                Stop-Job -Job $j -ErrorAction SilentlyContinue
                Remove-Job -Job $j -Force -ErrorAction SilentlyContinue
            }
            $script:MiningJobs = @()
            Write-Log $reason 'WARN'
        }
        return
    }
    if ($script:MiningGated) {
        $script:MiningGated = $false
        Write-Log 'Mining resumed.'
    }
}

function Get-OrCreateWallet {
    if (Invoke-Rpc @('-rpcwallet=main', 'getwalletinfo')) { return $true }
    # A wallet on disk is not loaded automatically by a fresh daemon, so try to
    # load the existing wallet before creating a new one (createwallet would
    # fail with "Database already exists" otherwise).
    if (Invoke-Rpc @('loadwallet', 'main')) {
        Start-Sleep -Seconds 2
        if (Invoke-Rpc @('-rpcwallet=main', 'getwalletinfo')) { return $true }
    }
    Write-Log 'Creating the mining wallet...'
    if (-not (Invoke-Rpc @('createwallet', 'main'))) { return $false }
    Start-Sleep -Seconds 2
    return [bool](Invoke-Rpc @('-rpcwallet=main', 'getwalletinfo'))
}

function Get-MiningAddress {
    $addr = Invoke-Rpc @('-rpcwallet=main', 'getnewaddress')
    if (-not $addr) { return '' }
    return $addr.Trim()
}

function Invoke-BackupGate {
    Write-Host ''
    Write-Host 'A backup is required before mining starts.'
    Write-Host 'Choose a folder OUTSIDE this app: a USB drive, or another disk.'
    Write-Host 'The wallet is not encrypted; the backup files are the only way to recover your coins.'
    $folder = Read-Host 'Backup folder'
    if (-not $folder) { return $false }
    $folder = $folder.Trim().Trim('"')
    if ($folder.StartsWith('\\') -or $folder.StartsWith('//')) {
        Write-Host 'Network paths are not allowed. Use a local folder or a USB drive.'
        return $false
    }
    $resolved = $null
    try { $resolved = (Resolve-Path -LiteralPath $folder).Path } catch { }
    if (-not $resolved) {
        Write-Host 'That folder does not exist.'
        return $false
    }
    $dataDirWithSlash = $script:DataDir.TrimEnd('\') + '\'
    if (($resolved.TrimEnd('\') + '\').StartsWith($dataDirWithSlash, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host 'Choose a folder outside the CacheCoin data directory.'
        return $false
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $walletBak = Join-Path $resolved "cachecoin-main-wallet-$stamp.bak"
    $descFile = Join-Path $resolved "cachecoin-main-descriptors-$stamp.json"
    if ($null -eq (Invoke-Rpc @('-rpcwallet=main', 'backupwallet', $walletBak))) {
        Write-Host 'The wallet backup failed.'
        return $false
    }
    $descriptors = Invoke-Rpc @('-rpcwallet=main', 'listdescriptors', 'true')
    if (-not $descriptors) {
        Write-Host 'The descriptor export failed.'
        return $false
    }
    Set-Content -LiteralPath $descFile -Value $descriptors -Encoding UTF8
    $h1 = Get-Sha256 $walletBak
    $h2 = Get-Sha256 $descFile
    Write-Host ''
    Write-Host "Saved: $walletBak"
    Write-Host "SHA-256: $h1"
    Write-Host "Saved: $descFile"
    Write-Host "SHA-256: $h2"
    Write-Host ''
    Write-Host 'These two files can spend your coins. Keep them offline. There is no recovery service.'
    $confirm = Read-Host 'Type exactly: I SAVED THE BACKUP'
    if ($confirm -ne 'I SAVED THE BACKUP') {
        Write-Host 'Backup not confirmed.'
        return $false
    }
    return $true
}

function Read-State {
    if (Test-Path -LiteralPath $script:StateFile) {
        try { return (Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json) } catch { return $null }
    }
    return $null
}

function Write-State {
    param($State)
    try { ($State | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $script:StateFile -Encoding UTF8 } catch { }
}

function Enable-Autostart {
    try {
        $cmd = Join-Path $script:Root 'CacheCoin.cmd'
        $action = New-ScheduledTaskAction -Execute $cmd -Argument '/silent'
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        Register-ScheduledTask -TaskName 'CacheCoin Node' -Action $action -Trigger $trigger -Force | Out-Null
        Write-Log 'Autostart enabled.'
    } catch {
        Write-Log "Could not enable autostart: $($_.Exception.Message)" 'ERROR'
    }
}

function Disable-Autostart {
    try {
        Unregister-ScheduledTask -TaskName 'CacheCoin Node' -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log 'Autostart disabled.'
    } catch {
        Write-Log "Could not disable autostart: $($_.Exception.Message)" 'ERROR'
    }
}

function Show-StatusDialog {
    $st = Get-Status
    $text = "CacheCoin`n`nPeers: $($st.Peers)`nBlock: $($st.Height) of $($st.Headers)`nMining: $($script:Mining)`nBalance: $($st.Balance) CCCN trusted`nImmature: $($st.Immature) CCCN"
    try { [System.Windows.Forms.MessageBox]::Show($text, 'CacheCoin status') | Out-Null } catch { }
}

function Initialize-Tray {
    try {
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        Add-Type -AssemblyName System.Drawing | Out-Null
    } catch {
        return $false
    }
    $tray = New-Object System.Windows.Forms.NotifyIcon
    $tray.Icon = [System.Drawing.SystemIcons]::Application
    $tray.Text = 'CacheCoin'
    $tray.Visible = $true
    $menu = New-Object System.Windows.Forms.ContextMenu
    $miStatus = New-Object System.Windows.Forms.MenuItem -ArgumentList 'Show status'
    $miStatus.Add_Click({ Show-StatusDialog })
    $miMining = New-Object System.Windows.Forms.MenuItem -ArgumentList 'Pause/Resume mining'
    $miMining.Add_Click({ if ($script:Mining) { Stop-Mining } else { Start-Mining } })
    $miFolder = New-Object System.Windows.Forms.MenuItem -ArgumentList 'Open data folder'
    $miFolder.Add_Click({ Start-Process -FilePath $script:DataDir })
    $miStop = New-Object System.Windows.Forms.MenuItem -ArgumentList 'Stop CacheCoin'
    $miStop.Add_Click({ $script:StopRequested = $true })
    [void]$menu.MenuItems.Add($miStatus)
    [void]$menu.MenuItems.Add($miMining)
    [void]$menu.MenuItems.Add($miFolder)
    [void]$menu.MenuItems.Add($miStop)
    $tray.ContextMenu = $menu
    $script:Tray = $tray
    return $true
}

if ($SelfTest) {
    Write-Host 'CacheCoin launcher'
    Write-Host 'Usage: CacheCoin.cmd [-Silent] [-Mode node|mining] [-RunSeconds N]'
    Write-Host '  -Silent      run without prompts (used by autostart)'
    Write-Host '  -Mode        force node-only or node+mining'
    Write-Host '  -RunSeconds  stop cleanly after N seconds (testing)'
    Write-Host 'Self-test OK.'
    exit 0
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\CacheCoinLauncher')
if (-not $mutex.WaitOne(0)) {
    Write-Host 'CacheCoin is already running.'
    exit 0
}

try {
    Write-Log 'CacheCoin launcher starting.'
    Test-PackageHashes
    Test-Preflight

    $state = Read-State
    $chosen = $Mode
    if (-not $chosen -and $state -and $state.mode) { $chosen = [string]$state.mode }
    if (-not $chosen) {
        if ($Silent) {
            $chosen = 'node'
        } else {
            Write-Host ''
            Write-Host 'How should CacheCoin run?'
            Write-Host '  1) Node only (recommended)'
            Write-Host '  2) Node + mining (solo; a lottery, no guaranteed reward)'
            $answer = Read-Host 'Choose 1 or 2 (default 1)'
            if ($answer -eq '2') { $chosen = 'mining' } else { $chosen = 'node' }
        }
    }

    $proxy = Get-TorProxy
    if ($proxy -eq 0) {
        Write-Log 'Tor was not found on port 9050 or 9150. Trying the bundled Tor...'
        if (Start-BundledTor) {
            $proxy = 9050
        } else {
            Fail 'Tor is not running and no bundled Tor was found. Install Tor, or use the full package. Without Tor the node cannot connect.'
        }
    } else {
        Write-Log "Using Tor on port $proxy."
    }
    $script:ProxyPort = $proxy

    $listen = $false
    if (-not $Silent -and -not $state) {
        $a = Read-Host 'Help other nodes connect by accepting incoming Tor connections? (y/N)'
        if ($a -match '^[Yy]') { $listen = $true }
    }
    Initialize-Config -ProxyPort $proxy -Listen $listen

    Start-Node
    if (-not (Wait-Rpc -Seconds 180)) {
        Fail "The node did not answer within 3 minutes. See the log: $($script:LogFile)"
    }
    Write-Log 'The node is running.'

    $st = Get-Status
    if ($st.Peers -eq 0) {
        Write-Host 'Waiting for peers over Tor (this can take a few minutes)...'
        $deadline = (Get-Date).AddMinutes(5)
        while ((Get-Date) -lt $deadline -and -not $script:StopRequested) {
            Start-Sleep -Seconds 5
            $st = Get-Status
            if ($st.Peers -gt 0) { break }
        }
    }

    $backupConfirmed = $false
    if ($state -and $state.backupConfirmed) { $backupConfirmed = $true }
    if ($chosen -eq 'mining') {
        if (-not (Get-OrCreateWallet)) { Fail 'Could not open or create the wallet.' }
        $script:Address = Get-MiningAddress
        if (-not $script:Address) { Fail 'Could not get a mining address.' }
        Write-Log "Mining address: $($script:Address)"
        if (-not $backupConfirmed) {
            if ($Silent) {
                Write-Log 'Mining is configured but no backup has been confirmed on this computer yet. Run CacheCoin.cmd once without -Silent, save the backup, and mining will start.' 'WARN'
            } elseif (Invoke-BackupGate) {
                $backupConfirmed = $true
            } else {
                Write-Host 'Mining was not started because the backup was not confirmed.'
            }
        }
        if ($backupConfirmed) { Start-Mining }
    }

    if (-not $Silent -and -not $state) {
        $a = Read-Host 'Start CacheCoin automatically when you log in? (y/N)'
        if ($a -match '^[Yy]') { Enable-Autostart } else { Disable-Autostart }
    }

    Write-State ([ordered]@{ mode = $chosen; backupConfirmed = $backupConfirmed; version = 1 })

    $interactive = -not $Silent
    if ($interactive) {
        if (-not (Initialize-Tray)) { $interactive = $false }
    }

    Write-Host ''
    Write-Host 'CacheCoin is running.'
    Write-Host "Data folder: $($script:DataDir)"
    Write-Host "Log file:    $($script:LogFile)"
    if ($interactive) {
        Write-Host 'Use the tray icon to pause mining or stop. Closing this window stops the launcher.'
    } else {
        Write-Host 'Running silently (autostart).'
    }
    Write-Host ''

    $lastStatus = (Get-Date).AddSeconds(-15)
    $restarts = 0
    $nodeStartedAt = Get-Date
    $deadline = $null
    if ($RunSeconds -gt 0) { $deadline = (Get-Date).AddSeconds($RunSeconds) }
    while (-not $script:StopRequested) {
        if ($deadline -and (Get-Date) -ge $deadline) { break }
        if ($script:Tray) { [System.Windows.Forms.Application]::DoEvents() }
        Update-MiningGate
        Update-Mining
        if (((Get-Date) - $lastStatus).TotalSeconds -ge 15) {
            $st = Get-Status
            Write-StatusLine -Status $st
            $lastStatus = Get-Date
            if ($script:Tray) {
                $tip = "CacheCoin - $($st.Peers) peers, block $($st.Height)"
                if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
                $script:Tray.Text = $tip
            }
        }
        if ($script:NodeProcess -and $script:NodeProcess.HasExited) {
            if (((Get-Date) - $nodeStartedAt).TotalMinutes -ge 10) { $restarts = 0 }
            $restarts++
            if ($restarts -le 3) {
                Write-Log 'The node stopped unexpectedly; restarting it.' 'WARN'
                Start-Sleep -Seconds 10
                Start-Node
                $nodeStartedAt = Get-Date
                if (-not (Wait-Rpc -Seconds 180)) {
                    Write-Log 'The node did not come back.' 'ERROR'
                } elseif ($script:Mining) {
                    if (Get-OrCreateWallet) {
                        $script:Address = Get-MiningAddress
                    } else {
                        Stop-Mining
                        Write-Log 'The wallet could not be reopened after the restart; mining is paused. Use the tray menu to resume once the node is healthy.' 'WARN'
                    }
                }
            } else {
                Write-Log 'The node keeps stopping; giving up. See the log.' 'ERROR'
                $script:StopRequested = $true
            }
        }
        if ($interactive) { Start-Sleep -Seconds 2 } else { Start-Sleep -Seconds 3 }
    }
} finally {
    try {
        Stop-Mining
        if ($script:NodeStartedByUs -and $script:NodeProcess -and -not $script:NodeProcess.HasExited) {
            Write-Log 'Stopping the node...'
            Invoke-Rpc @('stop') | Out-Null
            if (-not $script:NodeProcess.WaitForExit(90000)) {
                Stop-Process -Id $script:NodeProcess.Id -Force -ErrorAction SilentlyContinue
            }
        } elseif ($script:AttachedToExisting) {
            Write-Log 'Leaving the pre-existing node running.'
        }
        if ($script:StartedTor -and $script:TorProcess -and -not $script:TorProcess.HasExited) {
            Stop-Process -Id $script:TorProcess.Id -Force -ErrorAction SilentlyContinue
        }
        if ($script:Tray) {
            $script:Tray.Visible = $false
            $script:Tray.Dispose()
        }
    } catch { }
    try { $mutex.ReleaseMutex() } catch { }
    Write-Log 'Launcher stopped. Your coins are safe.'
}
