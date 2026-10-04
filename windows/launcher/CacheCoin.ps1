[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$Silent,
    [ValidateSet('node', 'mining')][string]$Mode,
    [int]$RunSeconds = 0,
    [switch]$Stop,
    [switch]$DisableAutostart,
    [switch]$EnableAutostart
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
$script:BackupConfirmed = $false
$script:WorkerRuns = 0
$script:MiningNextRefill = (Get-Date)
$script:LogWriteCount = 0
$script:LastTipRefresh = [DateTime]::MinValue
$script:TimeOffset = 0
$script:NodeOutLog = Join-Path $script:LogDir 'node-out.log'
$script:NodeErrLog = Join-Path $script:LogDir 'node-err.log'
$script:LockStream = $null
$script:MiningFailStreak = 0
$script:AttachedMissCount = 0
$script:WalletFingerprint = ''

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f ([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')), $Level, $Message
    try {
        if (-not (Test-Path -LiteralPath $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
        $script:LogWriteCount++
        if ($script:LogWriteCount % 200 -eq 0) {
            $fi = Get-Item -LiteralPath $script:LogFile -ErrorAction SilentlyContinue
            if ($fi -and $fi.Length -gt 1MB) {
                Move-Item -LiteralPath $script:LogFile -Destination "$($script:LogFile).1" -Force
            }
        }
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
        Fail 'version.json lists no files; refusing to run a package that cannot be verified.'
    }
    $map = @{}
    foreach ($prop in $manifest.files.PSObject.Properties) {
        $map[($prop.Name -replace '\\', '/')] = [string]$prop.Value
    }
    foreach ($req in @('bin/cachecoind.exe', 'bin/cachecoin-cli.exe', 'tor/tor.exe', 'launcher/CacheCoin.ps1')) {
        if (-not $map.ContainsKey($req)) {
            Fail "version.json does not list the required file $req. Download the package again."
        }
    }
    $checked = 0
    foreach ($name in $map.Keys) {
        $rel = $name -replace '/', '\'
        $full = Join-Path $script:Root $rel
        if (-not (Test-Path -LiteralPath $full)) {
            if ($rel -match '^(bin|tor)\\') {
                Fail "A program file listed in version.json is missing: $rel. Download the package again."
            }
            Write-Log "Packaged file is missing: $rel" 'WARN'
            continue
        }
        $actual = Get-Sha256 $full
        if ($actual -ne $map[$name].ToLowerInvariant()) {
            Fail ("A file does not match the published hash: {0}`nExpected: {1}`nFound:    {2}`nDo not run this copy; download it again." -f $rel, $map[$name], $actual)
        }
        $checked++
    }
    Write-Log "Package files match version.json ($checked files checked)."
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
    $bindLines = @()
    if ($Listen) { $bindLines = @('bind=127.0.0.1:29333', 'bind=127.0.0.1:29334=onion') }
    if (-not (Test-Path -LiteralPath $script:ConfPath)) {
        $content = @()
        foreach ($k in $required.Keys) { $content += "$k=$($required[$k])" }
        foreach ($b in $bindLines) { $content += $b }
        try { [System.IO.File]::WriteAllLines($script:ConfPath, $content, (New-Object System.Text.UTF8Encoding($false))) }
        catch { Fail "Could not write $($script:ConfPath): $($_.Exception.Message)" }
        Write-Log "Created $($script:ConfPath)"
        return
    }
    $rawBytes = $null
    try { $rawBytes = [System.IO.File]::ReadAllBytes($script:ConfPath) } catch { Fail "Could not read $($script:ConfPath): $($_.Exception.Message)" }
    $confEncoding = [System.Text.Encoding]::Default
    $confText = $null
    $converted = $false
    if ($rawBytes.Length -ge 2 -and $rawBytes[0] -eq 0xFF -and $rawBytes[1] -eq 0xFE) {
        $confText = [System.Text.Encoding]::Unicode.GetString($rawBytes, 2, $rawBytes.Length - 2)
        $confEncoding = New-Object System.Text.UTF8Encoding($false)
        $converted = $true
    } elseif ($rawBytes.Length -ge 2 -and $rawBytes[0] -eq 0xFE -and $rawBytes[1] -eq 0xFF) {
        $confText = [System.Text.Encoding]::BigEndianUnicode.GetString($rawBytes, 2, $rawBytes.Length - 2)
        $confEncoding = New-Object System.Text.UTF8Encoding($false)
        $converted = $true
    } elseif ($rawBytes.Length -ge 3 -and $rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF) {
        $confText = [System.Text.Encoding]::UTF8.GetString($rawBytes, 3, $rawBytes.Length - 3)
        $confEncoding = New-Object System.Text.UTF8Encoding($false)
        $converted = $true
    } else {
        try {
            $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
            $confText = $strictUtf8.GetString($rawBytes)
            $confEncoding = New-Object System.Text.UTF8Encoding($false)
        } catch {
            $confText = [System.Text.Encoding]::Default.GetString($rawBytes)
            $confEncoding = [System.Text.Encoding]::Default
        }
    }
    if ($confText.Length -gt 0 -and $confText[0] -eq [char]0xFEFF) { $confText = $confText.Substring(1) }
    $existing = New-Object System.Collections.Generic.List[string]
    $reader = New-Object System.IO.StringReader($confText)
    while ($null -ne ($line = $reader.ReadLine())) { $existing.Add($line) }
    $reader.Close()
    $proxyValue = [string]$required['proxy']
    $torcontrolValue = ''
    if ($Listen) {
        if ($ProxyPort -eq 9150) { $torcontrolValue = '127.0.0.1:9151' } else { $torcontrolValue = '127.0.0.1:9051' }
    }
    $proxyChanged = $false
    $torcontrolChanged = $false
    $customProxy = $false
    $localProxyEmitted = $false
    $newLines = New-Object System.Collections.Generic.List[string]
    $section = ''
    foreach ($l in $existing) {
        if ($l -match '^\s*\[([^\]]+)\]') {
            $section = $Matches[1].Trim().ToLowerInvariant()
            $newLines.Add($l)
            continue
        }
        $inScope = ($section -eq '' -or $section -eq 'main')
        if ($inScope -and $l -match '(?i)^\s*proxy\s*=') {
            if ($l -match '(?i)^\s*proxy\s*=\s*127\.0\.0\.1:\d+\s*(#.*)?$') {
                if (-not $localProxyEmitted) {
                    $newLines.Add("proxy=$proxyValue")
                    $localProxyEmitted = $true
                    if ($l.Trim() -ne "proxy=$proxyValue") { $proxyChanged = $true }
                } else {
                    $proxyChanged = $true
                }
            } else {
                $customProxy = $true
                $newLines.Add($l)
            }
            continue
        }
        if ($inScope -and $torcontrolValue -and $l -match '(?i)^\s*torcontrol\s*=') {
            if ($l -match '(?i)^\s*torcontrol\s*=\s*127\.0\.0\.1:\d+\s*$') {
                if ($l.Trim() -ne "torcontrol=$torcontrolValue") {
                    $newLines.Add("torcontrol=$torcontrolValue")
                    $torcontrolChanged = $true
                } else {
                    $newLines.Add($l)
                }
            } else {
                $newLines.Add($l)
            }
            continue
        }
        $newLines.Add($l)
    }
    $proxySeen = $localProxyEmitted -or $customProxy
    $missing = @()
    foreach ($k in $required.Keys) {
        if ($k -eq 'proxy' -and $proxySeen) { continue }
        $found = $false
        $scanSection = ''
        foreach ($l in $existing) {
            if ($l -match '^\s*\[([^\]]+)\]') { $scanSection = $Matches[1].Trim().ToLowerInvariant(); continue }
            if ($scanSection -ne '' -and $scanSection -ne 'main') { continue }
            if ($l -cmatch ("^\s*" + [regex]::Escape($k) + "\s*=")) { $found = $true; break }
        }
        if (-not $found) { $missing += $k }
    }
    $missingBinds = @()
    foreach ($b in $bindLines) {
        $found = $false
        foreach ($l in $existing) { if ($l.Trim() -ceq $b) { $found = $true; break } }
        if (-not $found) { $missingBinds += $b }
    }
    if ($missing.Count -gt 0 -or $missingBinds.Count -gt 0) {
        $insertAt = -1
        for ($i = 0; $i -lt $newLines.Count; $i++) {
            if ($newLines[$i] -match '^\s*\[') { $insertAt = $i; break }
        }
        if ($insertAt -ge 0) {
            for ($j = $missingBinds.Count - 1; $j -ge 0; $j--) {
                $newLines.Insert($insertAt, $missingBinds[$j])
            }
            for ($j = $missing.Count - 1; $j -ge 0; $j--) {
                $newLines.Insert($insertAt, "$($missing[$j])=$($required[$missing[$j]])")
            }
        } else {
            foreach ($k in $missing) { $newLines.Add("$k=$($required[$k])") }
            foreach ($b in $missingBinds) { $newLines.Add($b) }
        }
    }
    if ($missing.Count -gt 0 -or $missingBinds.Count -gt 0 -or $proxyChanged -or $torcontrolChanged -or $converted) {
        try { [System.IO.File]::WriteAllLines($script:ConfPath, $newLines.ToArray(), $confEncoding) }
        catch { Fail "Could not update $($script:ConfPath): $($_.Exception.Message)" }
        if ($missing.Count -gt 0) { Write-Log ('Added missing settings: ' + ($missing -join ', ')) }
        if ($missingBinds.Count -gt 0) { Write-Log 'Added loopback bind lines for incoming connections.' }
        if ($proxyChanged) { Write-Log "Updated the local proxy setting to 127.0.0.1:$ProxyPort." }
        if ($torcontrolChanged) { Write-Log "Updated the Tor control setting to $torcontrolValue." }
        if ($converted) { Write-Log 'Converted cachecoin.conf to UTF-8 (it was UTF-16 or had a BOM).' }
    }
    if ($customProxy) {
        Write-Log 'A custom proxy line is set in cachecoin.conf; the launcher keeps it. If it does not point at a working Tor SOCKS port, the node will not connect.' 'WARN'
    }
}

function Invoke-Rpc {
    param([string[]]$RpcArgs)
    try {
        $out = & $script:Cli "-datadir=$($script:DataDir)" '-rpcclienttimeout=10' @RpcArgs 2>&1
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
        if ($script:NodeProcess -and $script:NodeProcess.HasExited) {
            $code = $null
            try { $code = $script:NodeProcess.ExitCode } catch { }
            Write-Log "The node process exited (exit code $code) while waiting for RPC." 'WARN'
            return $false
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Start-Node {
    if (-not (Test-Path -LiteralPath $script:Daemon)) { Fail 'bin\cachecoind.exe is missing. Download the package again.' }
    if (-not (Test-Path -LiteralPath $script:Cli)) { Fail 'bin\cachecoin-cli.exe is missing. Download the package again.' }
    if (Invoke-Rpc @('getblockcount')) {
        Write-Log 'A CacheCoin node is already running; attaching to it.'
        $script:NodeProcess = $null
        $script:AttachedToExisting = $true
        return
    }
    $existing = @(Get-DatadirProcesses -Name 'cachecoind.exe')
    if ($existing.Count -gt 0) {
        Write-Log 'A cachecoind process for this data directory already exists but is not answering RPC yet; waiting for it instead of starting a second one.'
        $script:NodeProcess = $null
        $script:AttachedToExisting = $true
        return
    }
    Write-Log 'Starting the node...'
    try {
        $script:NodeProcess = Start-Process -FilePath $script:Daemon -ArgumentList @("`"-datadir=$($script:DataDir)`"", "`"-conf=$($script:ConfPath)`"") -WindowStyle Hidden -PassThru -RedirectStandardOutput $script:NodeOutLog -RedirectStandardError $script:NodeErrLog
    } catch {
        Fail "Could not start the node: $($_.Exception.Message)"
    }
    $script:NodeStartedByUs = $true
}

function Get-Status {
    $status = [ordered]@{
        Running      = $false
        Peers        = 0
        Height       = 0
        Headers      = 0
        IBD          = $true
        Balance      = 0.0
        Immature     = 0.0
        WalletLoaded = $false
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
    if (((Get-Date) - $script:LastTipRefresh).TotalSeconds -ge 30) {
        $bh = Invoke-Rpc @('getbestblockhash')
        if ($bh) {
            $hdr = Invoke-Rpc @('getblockheader', $bh.Trim())
            if ($hdr) {
                try { $script:LastTipTime = [long](($hdr | ConvertFrom-Json).time) } catch { }
            }
        }
        $ni = Invoke-Rpc @('getnetworkinfo')
        if ($ni) {
            try { $script:TimeOffset = [long](($ni | ConvertFrom-Json).timeoffset) } catch { }
        }
        $script:LastTipRefresh = Get-Date
    }
    $bal = Invoke-Rpc @('-rpcwallet=main', 'getbalances')
    if ($bal) {
        try {
            $j2 = $bal | ConvertFrom-Json
            $status.Balance = [double]$j2.mine.trusted
            $status.Immature = [double]$j2.mine.immature
            $status.WalletLoaded = $true
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
            Write-Host ('Mining: {0} worker(s). Blocks found: {1}. Worker runs: {2}.' -f $script:MiningJobs.Count, $script:FoundBlocks, $script:WorkerRuns)
        }
    }
    if ($st.WalletLoaded) {
        Write-Host ('Balance: {0} CCCN trusted, {1} CCCN immature (spendable after 100 blocks).' -f $st.Balance, $st.Immature)
    } else {
        Write-Host 'Balance: wallet not loaded (node-only run). Mining loads the wallet; start mining to see balances.'
    }
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
    if (-not $script:BackupConfirmed) {
        Write-Log 'Mining was not started: the wallet backup has not been confirmed on this computer. Save the backup first (run CacheCoin.cmd interactively).' 'WARN'
        return
    }
    $script:Mining = $true
    $script:MiningGated = $false
    $script:MiningNextRefill = Get-Date
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
        $script:WorkerRuns++
        $isNormalTimeout = $false
        if ($result -and $result.Output -match '(?i)Failed to make block') { $isNormalTimeout = $true }
        if ($result -and $result.ExitCode -eq 0 -and $result.Output -match '[0-9a-f]{64}') {
            $script:FoundBlocks++
            $script:MiningFailStreak = 0
            $height = 0
            $h = Invoke-Rpc @('getblockcount')
            if ($h) { try { $height = [int]$h } catch { } }
            $reward = 5
            if ($height -gt 720) { $reward = 10 }
            if ($height -gt 0) {
                Write-Log ('Block found! +{0} CCCN at height {1}. Spendable after 100 more blocks.' -f $reward, $height)
            } else {
                Write-Log ('Block found! +{0} CCCN. Spendable after 100 more blocks.' -f $reward)
            }
        } elseif ($isNormalTimeout -or ($result -and $result.ExitCode -eq 0)) {
            $script:MiningFailStreak = 0
        } elseif ($result -and $result.ExitCode -ne 0) {
            $script:MiningFailStreak++
            if (-not $script:LastMiningErrorLog -or ((Get-Date) - $script:LastMiningErrorLog).TotalSeconds -ge 60) {
                $firstLine = ($result.Output -split "`r?`n")[0]
                Write-Log "A mining worker returned an error and will be retried: $firstLine" 'WARN'
                $script:LastMiningErrorLog = Get-Date
            }
        } else {
            $script:MiningFailStreak++
            if (-not $script:LastMiningErrorLog -or ((Get-Date) - $script:LastMiningErrorLog).TotalSeconds -ge 60) {
                Write-Log 'A mining worker ended without a result (it may have been killed); it will be retried.' 'WARN'
                $script:LastMiningErrorLog = Get-Date
            }
        }
        if ($script:MiningFailStreak -gt 0) {
            $backoff = [Math]::Min(60, 5 * [Math]::Pow(2, [Math]::Min(4, $script:MiningFailStreak - 1)))
            $script:MiningNextRefill = (Get-Date).AddSeconds($backoff)
        } else {
            $script:MiningNextRefill = (Get-Date).AddSeconds(2)
        }
    }
    $target = Get-MiningWorkerCount
    while ($script:Mining -and -not $script:MiningGated -and $script:MiningJobs.Count -lt $target -and (Get-Date) -ge $script:MiningNextRefill) { Start-MiningWorker }
}

function Update-MiningGate {
    if (-not $script:Mining) { return }
    $st = Get-Status
    $reason = ''
    if (-not $st.Running) {
        $reason = 'The node is not answering; mining is paused until it is back.'
    } elseif ($st.Headers -gt $st.Height + 1) {
        $reason = 'The node is still syncing; mining will start when it is up to date.'
    } elseif ($st.Peers -eq 0) {
        $reason = 'No peers yet; mining will resume when the node connects.'
    } elseif ($script:TimeOffset -ne 0 -and [Math]::Abs($script:TimeOffset) -gt 300) {
        $reason = ('The computer clock is off by {0} seconds; mining is paused until it is fixed.' -f $script:TimeOffset)
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
    if (Invoke-Rpc @('-rpcwallet=main', 'getwalletinfo')) { return 'loaded' }
    # A wallet on disk is not loaded automatically by a fresh daemon, so try to
    # load the existing wallet before creating a new one (createwallet would
    # fail with "Database already exists" otherwise).
    if (Invoke-Rpc @('loadwallet', 'main')) {
        Start-Sleep -Seconds 2
        if (Invoke-Rpc @('-rpcwallet=main', 'getwalletinfo')) { return 'loaded' }
    }
    Write-Log 'Creating the mining wallet...'
    if (-not (Invoke-Rpc @('createwallet', 'main'))) { return 'failed' }
    Start-Sleep -Seconds 2
    if (Invoke-Rpc @('-rpcwallet=main', 'getwalletinfo')) { return 'created' }
    return 'failed'
}

function Test-DatadirCommandLine {
    param([string]$CommandLine)
    if (-not $CommandLine) { return $false }
    $m = [regex]::Match($CommandLine, '(?i)(?:^|\s)(?:"-datadir=(?<v>[^"]*)"?|-datadir="(?<v>[^"]*)"?|-datadir=(?<v>[^\s"]+))')
    if (-not $m.Success) { return $false }
    $arg = $m.Groups['v'].Value.Trim('"')
    if (-not $arg) { return $false }
    try { $arg = [System.IO.Path]::GetFullPath($arg) } catch { return $false }
    return ($arg.TrimEnd('\') -ieq $script:DataDir.TrimEnd('\'))
}

function Get-DatadirProcesses {
    param([string]$Name, [switch]$OnlyMining)
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name='$Name'" -ErrorAction Stop
    } catch {
        Write-Log "Could not list processes named $Name : $($_.Exception.Message)" 'WARN'
        return @()
    }
    $procs | Where-Object {
        $cl = $_.CommandLine
        if (-not (Test-DatadirCommandLine -CommandLine $cl)) { return $false }
        if ($OnlyMining -and ($cl -notmatch '(?i)generatetoaddress')) { return $false }
        return $true
    }
}

function Stop-StaleMiningProcesses {
    $stale = @(Get-DatadirProcesses -Name 'cachecoin-cli.exe' -OnlyMining)
    foreach ($p in $stale) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
    }
    if ($stale.Count -gt 0) {
        Write-Log "Cleaned up $($stale.Count) leftover mining process(es) from a previous run." 'WARN'
    }
}

function Get-MiningAddress {
    $addr = Invoke-Rpc @('-rpcwallet=main', 'getnewaddress')
    if (-not $addr) { return '' }
    return $addr.Trim()
}

function Get-WalletFingerprint {
    $d = Invoke-Rpc @('-rpcwallet=main', 'listdescriptors')
    if (-not $d) { return '' }
    try {
        $obj = $d | ConvertFrom-Json
        $descs = @($obj.descriptors | ForEach-Object { [string]$_.desc } | Sort-Object)
        if ($descs.Count -eq 0) { return '' }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(($descs -join "`n")))
            return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
        } finally {
            $sha.Dispose()
        }
    } catch {
        return ''
    }
}

function Test-AddressOwned {
    param([string]$Address)
    if (-not $Address) { return $false }
    $info = Invoke-Rpc @('-rpcwallet=main', 'getaddressinfo', $Address)
    if (-not $info) { return $false }
    try { return [bool](($info | ConvertFrom-Json).ismine) } catch { return $false }
}

function Save-State {
    param([string]$Mode)
    try {
        $fp = $script:WalletFingerprint
        if (-not $fp) {
            $existing = Read-State
            if ($existing -and $existing.walletFingerprint) { $fp = [string]$existing.walletFingerprint }
        }
        ([ordered]@{
            mode              = $Mode
            backupConfirmed   = $script:BackupConfirmed
            miningAddress     = $script:Address
            walletFingerprint = $fp
            version           = 1
        } | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $script:StateFile -Encoding UTF8
    } catch { }
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
    try { $resolved = (Get-Item -LiteralPath $folder -ErrorAction Stop).FullName } catch { }
    if (-not $resolved) {
        Write-Host 'That folder does not exist.'
        return $false
    }
    if ($resolved -match '(?i)\\(OneDrive|Dropbox|Google ?Drive|iCloud|MEGAsync|pCloud|Nextcloud|Syncthing|YandexDisk|Box|SharePoint|Creative Cloud Files)(\\|$)') {
        Write-Host 'Warning: that folder syncs to the cloud, so the backup would leave this computer.'
        Write-Host 'A USB drive or a plain local folder is safer for wallet keys.'
    }
    $rootWithSlash = $script:Root.TrimEnd('\') + '\'
    if (($resolved.TrimEnd('\') + '\').StartsWith($rootWithSlash, [System.StringComparison]::OrdinalIgnoreCase) -or
        ($resolved.TrimEnd('\') -ieq $script:Root.TrimEnd('\'))) {
        Write-Host 'Choose a folder outside the CacheCoin app folder (it can be deleted on upgrade).'
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
    try { [System.IO.File]::WriteAllText($descFile, $descriptors, (New-Object System.Text.UTF8Encoding($false))) }
    catch {
        Write-Host 'The descriptor export could not be written; the backup is not confirmed.'
        return $false
    }
    try {
        $h1 = Get-Sha256 $walletBak
        $h2 = Get-Sha256 $descFile
    } catch {
        Write-Host 'The backup files could not be read back after writing; the backup is not confirmed.'
        return $false
    }
    try {
        $bakInfo = Get-Item -LiteralPath $walletBak -ErrorAction Stop
        if ($bakInfo.Length -lt 1024) {
            Write-Host 'The wallet backup file looks too small; the backup is not confirmed.'
            return $false
        }
        $descObj = [System.IO.File]::ReadAllText($descFile) | ConvertFrom-Json
        if (-not $descObj.descriptors -or @($descObj.descriptors).Count -lt 1) {
            Write-Host 'The descriptor export looks empty; the backup is not confirmed.'
            return $false
        }
    } catch {
        Write-Host 'The backup files could not be validated; the backup is not confirmed.'
        return $false
    }
    Write-Log "Wallet backup saved: $walletBak (sha256 $h1), descriptors: $descFile (sha256 $h2)."
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
        $ps1 = Join-Path $script:Root 'launcher\CacheCoin.ps1'
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ps1`" -Silent"
        $runAs = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $runAs
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName 'CacheCoin Node' -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
        if (Get-ScheduledTask -TaskName 'CacheCoin Node' -ErrorAction SilentlyContinue) {
            Write-Log 'Autostart enabled (runs hidden at logon).'
        } else {
            Write-Log 'Autostart registration did not create the task.' 'ERROR'
        }
    } catch {
        Write-Log "Could not enable autostart: $($_.Exception.Message)" 'ERROR'
    }
}

function Disable-Autostart {
    try {
        Unregister-ScheduledTask -TaskName 'CacheCoin Node' -Confirm:$false -ErrorAction Stop
    } catch { }
    if (Get-ScheduledTask -TaskName 'CacheCoin Node' -ErrorAction SilentlyContinue) {
        Write-Log 'Could not disable autostart; the task still exists. Remove "CacheCoin Node" in Task Scheduler manually.' 'ERROR'
    } else {
        Write-Log 'Autostart disabled.'
    }
}

function Show-StatusDialog {
    $st = Get-Status
    $balText = 'wallet not loaded'
    if ($st.WalletLoaded) { $balText = "$($st.Balance) CCCN trusted, $($st.Immature) CCCN immature" }
    $text = "Peers: $($st.Peers)`nBlock: $($st.Height) of $($st.Headers)`nMining: $($script:Mining)`nBalance: $balText"
    Write-Log ("Status requested: " + ($text -replace "`n", '; '))
    if ($script:Tray) {
        try {
            $script:Tray.BalloonTipTitle = 'CacheCoin status'
            $script:Tray.BalloonTipText = $text
            $script:Tray.ShowBalloonTip(10000)
        } catch { }
    } else {
        Write-Host $text
    }
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
    Write-Host 'Usage: CacheCoin.cmd [-Silent] [-Mode node|mining] [-RunSeconds N] [-Stop] [-DisableAutostart] [-EnableAutostart]'
    Write-Host '  -Silent           run without prompts (used by autostart)'
    Write-Host '  -Mode             force node-only or node+mining'
    Write-Host '  -RunSeconds       stop cleanly after N seconds (testing)'
    Write-Host '  -Stop             stop the running node (the launcher exits when it stops)'
    Write-Host '  -DisableAutostart remove the logon task and exit'
    Write-Host '  -EnableAutostart  register the logon task for this folder and exit'
    Write-Host 'Self-test OK.'
    exit 0
}

if ($EnableAutostart) {
    Enable-Autostart
    if (Get-ScheduledTask -TaskName 'CacheCoin Node' -ErrorAction SilentlyContinue) {
        Write-Host 'Autostart enabled for this folder.'
        exit 0
    }
    Write-Host 'Could not register the autostart task.'
    exit 1
}

if ($DisableAutostart) {
    try {
        Unregister-ScheduledTask -TaskName 'CacheCoin Node' -Confirm:$false -ErrorAction Stop
    } catch { }
    if (Get-ScheduledTask -TaskName 'CacheCoin Node' -ErrorAction SilentlyContinue) {
        Write-Host 'Could not remove the autostart task (access denied?). Remove "CacheCoin Node" in Task Scheduler manually.'
        exit 1
    }
    Write-Host 'Autostart task removed.'
    exit 0
}

if ($Stop) {
    $stopCli = Join-Path $script:Root 'bin\cachecoin-cli.exe'
    if (-not (Test-Path -LiteralPath $stopCli)) {
        Write-Host 'cachecoin-cli.exe not found; nothing to stop.'
        exit 1
    }
    $stopDeadline = (Get-Date).AddSeconds(45)
    $stopped = $false
    while ((Get-Date) -lt $stopDeadline) {
        $stopOut = $null
        try { $stopOut = & $stopCli "-datadir=$($script:DataDir)" stop 2>&1 } catch { }
        if ($LASTEXITCODE -eq 0) { $stopped = $true; break }
        Start-Sleep -Seconds 3
    }
    if ($stopped) {
        Write-Host 'Stop requested. The node is shutting down; its launcher exits when it stops.'
        exit 0
    }
    Write-Host 'The node did not answer a stop request (it may still be starting). Wait a minute and try again.'
    exit 3
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\CacheCoinLauncher')
if (-not $mutex.WaitOne(0)) {
    Write-Host 'CacheCoin is already running. Use CacheCoin.cmd -Stop to stop it.'
    if (-not $Silent) {
        try {
            Add-Type -AssemblyName System.Windows.Forms | Out-Null
            [System.Windows.Forms.MessageBox]::Show("CacheCoin is already running.`n`nTo stop it, run: CacheCoin.cmd -Stop", 'CacheCoin') | Out-Null
        } catch { }
    }
    exit 0
}

$lockPath = Join-Path $script:DataDir 'launcher.lock'
try {
    if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
    $script:LockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
} catch {
    Write-Host 'CacheCoin is already running in another session on this computer. Use CacheCoin.cmd -Stop to stop it.'
    if (-not $Silent) {
        try {
            Add-Type -AssemblyName System.Windows.Forms | Out-Null
            [System.Windows.Forms.MessageBox]::Show("CacheCoin is already running in another session.`n`nTo stop it, run: CacheCoin.cmd -Stop", 'CacheCoin') | Out-Null
        } catch { }
    }
    try { $mutex.ReleaseMutex() } catch { }
    exit 0
}

try {
    Write-Log 'CacheCoin launcher starting.'
    Test-PackageHashes
    Test-Preflight
    Stop-StaleMiningProcesses

    $state = Read-State
    if (-not $Silent) {
        try {
            $task = Get-ScheduledTask -TaskName 'CacheCoin Node' -ErrorAction SilentlyContinue
            $wantPs1 = (Join-Path $script:Root 'launcher\CacheCoin.ps1')
            if ($task -and ($task.Actions[0].Execute -ne 'powershell.exe' -or $task.Actions[0].Arguments -notlike "*$wantPs1*")) {
                Write-Log 'The autostart task points at a different CacheCoin folder or an older command; re-registering it for this folder.' 'WARN'
                Enable-Autostart
            }
        } catch { }
    }
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
        $startExit = $null
        try { if ($script:NodeProcess) { $startExit = $script:NodeProcess.ExitCode } } catch { }
        if ($startExit -eq 0) {
            Write-Log 'The node stopped cleanly during startup (a stop was requested); the launcher is exiting.'
            exit 0
        }
        $hint = ''
        try {
            if (Test-Path -LiteralPath $script:NodeErrLog) {
                $last = ((Get-Content -LiteralPath $script:NodeErrLog -Tail 3 -ErrorAction SilentlyContinue) | Where-Object { $_ }) -join ' '
                if ($last) { $hint = " Last node message: $last" }
            }
        } catch { }
        Fail "The node did not answer within 3 minutes.$hint See the log: $($script:LogFile)"
    }
    Write-Log 'The node is running.'

    $st = Get-Status
    if ($st.Peers -eq 0) {
        if (-not $Silent) { Write-Host 'Waiting for peers over Tor (this can take a few minutes)...' }
        $deadline = (Get-Date).AddMinutes(5)
        while ((Get-Date) -lt $deadline -and -not $script:StopRequested) {
            Start-Sleep -Seconds 5
            $st = Get-Status
            if ($st.Peers -gt 0) { break }
            if (-not $st.Running) {
                Write-Log 'The node is not answering.' 'WARN'
                break
            }
        }
    }

    $script:BackupConfirmed = $false
    if ($state -and $state.backupConfirmed) { $script:BackupConfirmed = $true }
    if ($state -and $state.miningAddress) { $script:Address = [string]$state.miningAddress }
    if ($chosen -eq 'mining') {
        $walletState = Get-OrCreateWallet
        if ($walletState -eq 'failed') {
            Fail 'Could not open or create the wallet. If you have a backup, restore it before mining.'
        }
        $script:WalletFingerprint = Get-WalletFingerprint
        if ($walletState -eq 'created') {
            $script:BackupConfirmed = $false
            $script:Address = ''
            Write-Log 'A new wallet was created; the previous backup does not cover it. A new backup is required before mining.' 'WARN'
        } elseif ($state -and $state.walletFingerprint -and $script:WalletFingerprint -and ([string]$state.walletFingerprint -ne $script:WalletFingerprint)) {
            $script:BackupConfirmed = $false
            $script:Address = ''
            Write-Log 'The wallet on disk does not match the last backup record (this can also happen once after a launcher update). Mining waits for a new backup confirmation.' 'WARN'
        }
        if ($script:Address -and -not (Test-AddressOwned -Address $script:Address)) {
            Write-Log 'The saved mining address does not belong to the loaded wallet; a new address will be used.' 'WARN'
            $script:Address = ''
        }
        if (-not $script:Address) {
            $script:Address = Get-MiningAddress
            if (-not $script:Address) { Fail 'Could not get a mining address.' }
            Write-Log "Mining address: $($script:Address)"
        } else {
            Write-Log "Mining address (kept from the previous run): $($script:Address)"
        }
        if (-not $script:BackupConfirmed) {
            if ($Silent) {
                Write-Log 'Mining is configured but no backup has been confirmed on this computer yet. Run CacheCoin.cmd once without -Silent, save the backup, and mining will start.' 'WARN'
            } elseif (Invoke-BackupGate) {
                $script:BackupConfirmed = $true
            } else {
                Write-Host 'Mining was not started because the backup was not confirmed.'
            }
        }
        if ($script:BackupConfirmed) { Start-Mining }
    }

    if (-not $Silent -and -not $state) {
        $a = Read-Host 'Start CacheCoin automatically when you log in? (y/N)'
        if ($a -match '^[Yy]') { Enable-Autostart } else { Disable-Autostart }
    }

    Save-State -Mode $chosen

    $interactive = -not $Silent
    if ($interactive) {
        if (-not (Initialize-Tray)) { $interactive = $false }
    }

    if (-not $Silent) {
        Write-Host ''
        Write-Host 'CacheCoin is running.'
        Write-Host "Data folder: $($script:DataDir)"
        Write-Host "Log file:    $($script:LogFile)"
        if ($interactive) {
            Write-Host 'Use the tray icon to pause mining or stop. Closing this window stops the launcher; the node keeps running.'
        }
        Write-Host ''
    } else {
        Write-Log 'CacheCoin is running silently (autostart).'
    }

    $lastStatus = (Get-Date).AddSeconds(-15)
    $lastGate = (Get-Date).AddSeconds(-5)
    $restarts = 0
    $nodeStartedAt = Get-Date
    $deadline = $null
    if ($RunSeconds -gt 0) { $deadline = (Get-Date).AddSeconds($RunSeconds) }
    while (-not $script:StopRequested) {
        if ($deadline -and (Get-Date) -ge $deadline) { break }
        if ($script:Tray) { [System.Windows.Forms.Application]::DoEvents() }
        if (((Get-Date) - $lastGate).TotalSeconds -ge 5) {
            Update-MiningGate
            $lastGate = Get-Date
            if ($script:AttachedToExisting -and -not $script:NodeProcess) {
                $attachedStatus = Get-Status
                if ($attachedStatus.Running) {
                    $script:AttachedMissCount = 0
                } else {
                    $script:AttachedMissCount++
                    if ($script:AttachedMissCount -ge 6) {
                        Write-Log 'The pre-existing node is not answering; the launcher is exiting.'
                        $script:StopRequested = $true
                    }
                }
            }
        }
        Update-Mining
        if (((Get-Date) - $lastStatus).TotalSeconds -ge 15) {
            $st = Get-Status
            if (-not $Silent) {
                Write-StatusLine -Status $st
            } else {
                Write-Log ('Status: peers={0} height={1} ibd={2} mining={3}' -f $st.Peers, $st.Height, $st.IBD, $script:Mining)
            }
            $lastStatus = Get-Date
            if ($script:Tray) {
                $tip = "CacheCoin - $($st.Peers) peers, block $($st.Height)"
                if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
                $script:Tray.Text = $tip
            }
        }
        if ($script:NodeProcess -and $script:NodeProcess.HasExited) {
            $nodeExit = $null
            try { $nodeExit = $script:NodeProcess.ExitCode } catch { }
            if ($nodeExit -eq 0) {
                Write-Log 'The node stopped cleanly (stop requested); the launcher is exiting.'
                $script:StopRequested = $true
            } else {
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
                        $walletState = Get-OrCreateWallet
                        if ($walletState -eq 'failed') {
                            Stop-Mining
                            Write-Log 'The wallet could not be reopened after the restart; mining is paused. Use the tray menu to resume once the node is healthy.' 'WARN'
                        } elseif ($walletState -eq 'created') {
                            Stop-Mining
                            $script:BackupConfirmed = $false
                            $script:Address = ''
                            $script:WalletFingerprint = Get-WalletFingerprint
                            Write-Log 'The wallet was missing after the restart and a new one was created; mining is paused and a new backup is required.' 'WARN'
                        } else {
                            $script:WalletFingerprint = Get-WalletFingerprint
                            if ($script:Address -and -not (Test-AddressOwned -Address $script:Address)) {
                                $script:Address = ''
                                Write-Log 'The saved mining address does not belong to the reopened wallet; a new address will be used.' 'WARN'
                            }
                            if (-not $script:Address) { $script:Address = Get-MiningAddress }
                        }
                        Save-State -Mode $chosen
                    }
                } else {
                    Write-Log 'The node keeps stopping; giving up. See the log.' 'ERROR'
                    $script:StopRequested = $true
                }
            }
        }
        if ($interactive) { Start-Sleep -Seconds 2 } else { Start-Sleep -Seconds 3 }
    }
} finally {
    try { Stop-Mining } catch { }
    try { Stop-StaleMiningProcesses } catch { }
    try {
        if ($script:NodeStartedByUs -and $script:NodeProcess -and -not $script:NodeProcess.HasExited) {
            Write-Log 'Stopping the node...'
            Invoke-Rpc @('stop') | Out-Null
            if (-not $script:NodeProcess.WaitForExit(90000)) {
                Stop-Process -Id $script:NodeProcess.Id -Force -ErrorAction SilentlyContinue
            }
        } elseif ($script:AttachedToExisting) {
            Write-Log 'Leaving the pre-existing node running.'
        }
    } catch { }
    try {
        if ($script:StartedTor -and $script:TorProcess -and -not $script:TorProcess.HasExited) {
            Stop-Process -Id $script:TorProcess.Id -Force -ErrorAction SilentlyContinue
        }
    } catch { }
    try {
        if ($script:Tray) {
            $script:Tray.Visible = $false
            $script:Tray.Dispose()
        }
    } catch { }
    try {
        if ($script:LockStream) {
            $script:LockStream.Dispose()
            $script:LockStream = $null
        }
    } catch { }
    try { $mutex.ReleaseMutex() } catch { }
    try { Write-Log 'Launcher stopped.' } catch { }
}
