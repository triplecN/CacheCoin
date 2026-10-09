[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$Silent,
    [ValidateSet('node', 'mining')][string]$Mode,
    [int]$RunSeconds = 0,
    [switch]$Stop,
    [switch]$DisableAutostart,
    [switch]$EnableAutostart,
    [switch]$Takeover
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
$script:Seeds = @(
    'ag7rydtma6dt5fonz76sdbecrbugq3uln7cc6ddvg2c2jngio4lw6mid.onion:29333',
    '7uodchunfsykltytzwhpq6plvlxsulhtawjisrvcxzhljfdsmwnjbead.onion:29333'
)

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
$script:Threads = 0
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
$script:ClockWarned = $false
$script:NodeOutLog = Join-Path $script:LogDir 'node-out.log'
$script:NodeErrLog = Join-Path $script:LogDir 'node-err.log'
$script:LockStream = $null
$script:MiningFailStreak = 0
$script:AttachedMissCount = 0
$script:LastAttest = [DateTime]::MinValue
$script:AttestFails = 0
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
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() }
    catch { return '' }
}

function Test-PackageHashes {
    if (-not (Test-Path -LiteralPath $script:VersionFile)) {
        Fail 'version.json is missing, so the package cannot be verified. Download it again and do not run this copy.'
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
    foreach ($req in @('bin/cachecoind.exe', 'bin/cachecoin-cli.exe', 'tor/tor.exe', 'launcher/CacheCoin.ps1', 'tools/CacheCoin-NewWallet.ps1', 'tools/CacheCoin-Package.ps1', 'tools/CacheCoin-Status.ps1')) {
        if (-not $map.ContainsKey($req)) {
            Fail "version.json does not list the required file $req. Download the package again."
        }
    }
    $checked = 0
    $dangerous = @('.exe', '.cmd', '.bat', '.ps1', '.dll', '.com', '.scr', '.msi', '.vbs', '.vbe', '.js', '.jse', '.wsf', '.wsh', '.hta', '.cpl', '.ocx', '.lnk', '.chm', '.psm1', '.psd1', '.jar', '.config', '.manifest', '.scf', '.pif', '.inf', '.msc', '.reg')
    foreach ($name in $map.Keys) {
        if ($name -match '(^|/)\.\.(/|$)' -or $name.StartsWith('/') -or $name.StartsWith('\') -or $name.Contains(':') -or ($name.TrimEnd(' ', '.') -ne $name)) {
            Fail "version.json contains an unsafe path ($name). Download the package again."
        }
        $rel = $name -replace '/', '\'
        $full = Join-Path $script:Root $rel
        if (-not (Test-Path -LiteralPath $full)) {
            Fail "A file listed in version.json is missing: $rel. Download the package again."
        }
        $actual = Get-Sha256 $full
        if ($actual -ne $map[$name].ToLowerInvariant()) {
            Fail ("A file does not match the published hash: {0}`nExpected: {1}`nFound:    {2}`nDo not run this copy; download it again." -f $rel, $map[$name], $actual)
        }
        $checked++
    }
    # A program the manifest does not cover is a supply-chain hole, not a warning. This includes
    # DLLs and scripts: anything that can run or be loaded counts.
    $unlisted = @()
    $rootFull = $script:Root.TrimEnd('\')
    $rootOfRoot = ([System.IO.Path]::GetPathRoot($script:Root)).TrimEnd('\')
    if ($rootOfRoot -ieq $rootFull) {
        Fail 'The package is sitting at a drive root. Extract it into its own folder (for example Downloads\CacheCoin-Windows) and run it from there; a package at a drive root cannot be checked for extra programs.'
    }
    try {
        if (((Get-Item -LiteralPath $script:Root -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Fail 'The package folder is a link; extract the package again into a plain folder and run it from there.'
        }
        $items = @(Get-ChildItem -LiteralPath $script:Root -Recurse -Force -ErrorAction Stop)
        foreach ($it in $items) {
            if (($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Fail "The package contains a link ($($it.FullName)); refusing to run. Extract the package again into a plain folder."
            }
            if ($it.PSIsContainer) { continue }
            $ext = [System.IO.Path]::GetExtension($it.Name.TrimEnd(' ', '.')).ToLowerInvariant()
            if ($dangerous -notcontains $ext) { continue }
            $rel = ($it.FullName.Substring($script:Root.Length).TrimStart('\') -replace '\\', '/')
            if (-not $map.ContainsKey($rel)) { $unlisted += $rel }
        }
    } catch {
        Fail 'Could not list the package files to check for unlisted programs. Download the package again.'
    }
    if ($unlisted.Count -gt 0) {
        Fail ('These program files are not listed in version.json, so they cannot be trusted: ' + ($unlisted -join ', ') + '. Download the package again and do not run this copy.')
    }
    Write-Log "Package files match version.json ($checked files checked; no unlisted programs)."
}

# True when the node advertises an onion address of its own (the honest proof that incoming works).
function Test-OnionAdvertised {
    $info = Invoke-Rpc @('getnetworkinfo')
    if (-not $info) { return $false }
    try {
        $j = $info | ConvertFrom-Json
        foreach ($a in @($j.localaddresses)) {
            if ($a.address -and ([string]$a.address).EndsWith('.onion')) { return $true }
        }
    } catch { }
    return $false
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

# A real Tor SOCKS port answers the SOCKS5 greeting; a random listener on 9050 does not.
function Test-TorSocks {
    param([int]$Port, [int]$TimeoutMs = 1500)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($iar)
        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutMs
        $stream.WriteTimeout = $TimeoutMs
        $req = [byte[]](5, 1, 0)
        $stream.Write($req, 0, $req.Length)
        $resp = New-Object byte[] 2
        $read = 0
        while ($read -lt 2) {
            $n = $stream.Read($resp, $read, 2 - $read)
            if ($n -le 0) { return $false }
            $read += $n
        }
        return ($resp[0] -eq 5)
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Get-TorProxy {
    foreach ($p in @(9050, 9150)) {
        if (Test-TcpPort -TargetHost '127.0.0.1' -Port $p) {
            if (Test-TorSocks -Port $p) { return $p }
            Write-Log "Port $p is open but it does not answer as a Tor SOCKS proxy." 'WARN'
        }
    }
    return 0
}

function Start-BundledTor {
    if (-not (Test-Path -LiteralPath $script:TorExe)) { return $false }
    $torDir = Join-Path $script:DataDir 'tor'
    if (-not (Test-Path -LiteralPath $torDir)) { New-Item -ItemType Directory -Path $torDir -Force | Out-Null }
    $torrc = Join-Path $torDir 'torrc'
    # Forward slashes: Tor reads backslashes in paths as escapes.
    $torDirFwd = $torDir -replace '\\', '/'
    $lines = @(
        "DataDirectory `"$torDirFwd`"",
        "CookieAuthFile `"$torDirFwd/control_auth_cookie`"",
        'SocksPort 127.0.0.1:9050',
        'ControlPort 127.0.0.1:9051',
        'CookieAuthentication 1',
        'ClientOnly 1',
        'SafeLogging 1'
    )
    try { Write-TextAtomic -Path $torrc -Lines $lines -Encoding (New-Object System.Text.UTF8Encoding($false)) }
    catch {
        Write-Log "Could not write the Tor configuration: $($_.Exception.Message)" 'ERROR'
        return $false
    }
    Write-Log 'Starting the bundled Tor...'
    if (-not (Test-Path -LiteralPath $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
    $torOut = Join-Path $script:LogDir 'tor-out.log'
    $torErr = Join-Path $script:LogDir 'tor-err.log'
    try {
        $script:TorProcess = Start-Process -FilePath $script:TorExe -ArgumentList @('-f', "`"$torrc`"") -WindowStyle Hidden -PassThru -RedirectStandardOutput $torOut -RedirectStandardError $torErr
    } catch {
        Write-Log "Could not start the bundled Tor: $($_.Exception.Message)" 'ERROR'
        return $false
    }
    $script:StartedTor = $true
    if (Wait-TcpPort -TargetHost '127.0.0.1' -Port 9050 -Seconds 90) {
        if ($script:TorProcess.HasExited) {
            Write-Log 'The bundled Tor exited right after it started (see logs\tor-err.log).' 'ERROR'
            return $false
        }
        if (-not (Test-TorSocks -Port 9050)) {
            Write-Log 'Port 9050 did not answer as Tor SOCKS after the bundled Tor start.' 'ERROR'
            return $false
        }
        return $true
    }
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

function Write-TextAtomic {
    param([string]$Path, [string[]]$Lines, [System.Text.Encoding]$Encoding)
    $dir = Split-Path -Parent $Path
    $tmp = Join-Path $dir ('.' + [System.IO.Path]::GetFileName($Path) + '.tmp')
    [System.IO.File]::WriteAllLines($tmp, $Lines, $Encoding)
    if (Test-Path -LiteralPath $Path) {
        try { [System.IO.File]::Replace($tmp, $Path, $null) }
        catch { Move-Item -LiteralPath $tmp -Destination $Path -Force }
    } else {
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    }
}

function Initialize-Config {
    param([int]$ProxyPort, [bool]$Listen, [bool]$MigrateSeeds = $false)
    if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
    $required = [ordered]@{
        'server'      = '1'
        'proxy'       = "127.0.0.1:$ProxyPort"
        'onlynet'     = 'onion'
        'dnsseed'     = '0'
        'discover'    = '0'
        'natpmp'      = '0'
        'rpcbind'     = '127.0.0.1'
        'rpcallowip'  = '127.0.0.1'
        'rpcport'     = '29332'
        'fallbackfee' = '0.0001'
        'dbcache'     = '450'
        'maxmempool'  = '150'
        'maxconnections'  = '32'
        'maxuploadtarget' = '5000'
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
        foreach ($s in $script:Seeds) { $content += "addnode=$s" }
        foreach ($b in $bindLines) { $content += $b }
        try { Write-TextAtomic -Path $script:ConfPath -Lines $content -Encoding (New-Object System.Text.UTF8Encoding($false)) }
        catch { Fail "Could not write $($script:ConfPath): $($_.Exception.Message)" }
        $script:ConfigListening = [bool]$Listen
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
    } elseif ($rawBytes.Length -ge 8 -and $rawBytes.Length % 2 -eq 0 -and (($rawBytes | Where-Object { $_ -eq 0 }).Count * 4) -ge $rawBytes.Length) {
        # UTF-16 without a BOM: many NUL bytes are valid UTF-8, so detect and convert them here.
        # A single stray NUL in a UTF-8 file does not match this rule (it would be destructive).
        $confText = [System.Text.Encoding]::Unicode.GetString($rawBytes)
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
    if ($confText.IndexOf([char]0) -ge 0) {
        Fail 'cachecoin.conf contains NUL bytes and cannot be read safely. Fix or delete that file, then start again.'
    }
    $existing = New-Object System.Collections.Generic.List[string]
    $reader = New-Object System.IO.StringReader($confText)
    while ($null -ne ($line = $reader.ReadLine())) { $existing.Add($line) }
    $reader.Close()
    $confListen = $false
    # Core also accepts dotted keys like "main.listen"; normalize them before the detection
    # scans below, or a dotted listen=1 would be invisible while still taking effect.
    $dottedFixed = $false
    for ($i = 0; $i -lt $existing.Count; $i++) {
        if ($existing[$i] -match '^\s*main\.(server|onlynet|dnsseed|discover|natpmp|rpcbind|rpcallowip|rpcport|listen|listenonion|proxy|torcontrol|bind|onion|i2psam|whitebind|addnode|connect|seednode)\s*=') {
            $existing[$i] = $existing[$i] -replace '^(\s*)main\.', '$1'
            $dottedFixed = $true
        }
    }
    # A file that uses only CR line endings is one line to the node but many lines here: rewrite it.
    if ($confText -match "`r" -and $confText -notmatch "`n") { $converted = $true }
    # Core trims only space/tab/CR/LF; other Unicode whitespace in a key would hide it from the node
    # while this launcher still sees it. Normalize those characters to plain spaces.
    for ($i = 0; $i -lt $existing.Count; $i++) {
        if ($existing[$i] -match '[\u00A0\u1680\u2000-\u200A\u202F\u205F\u3000\u2028\u2029\u000B\u000C]') {
            $existing[$i] = [regex]::Replace($existing[$i], '[\u00A0\u1680\u2000-\u200A\u202F\u205F\u3000\u2028\u2029\u000B\u000C]', ' ')
            $dottedFixed = $true
        }
    }
    # includeconf is followed by the node and never scanned here: refuse it.
    foreach ($l in $existing) {
        if ($l -cmatch '^\s*(?:main\.)?includeconf\s*=') {
            Fail 'cachecoin.conf uses includeconf, which this launcher cannot check. Remove that line (or delete the file) and start again.'
        }
    }
    # Chain selectors and RPC-channel keys are owned by this package; a stale or hostile line here
    # stops the node from starting or breaks every RPC call, so they are refused instead of trusted.
    foreach ($l in $existing) {
        $badKey = Get-ForbiddenConfKey $l
        if ($badKey) {
            Fail "cachecoin.conf sets the $badKey key, which this package controls. Remove that line (or delete the file) and start again."
        }
    }
    # A bare word is a fatal parse error to the node: refuse it here with a message the user can act on.
    foreach ($l in $existing) {
        $bare = Get-BareConfLine $l
        if ($bare) {
            Fail "cachecoin.conf has a line that is not a setting ($bare). Remove that line (or delete the file) and start again."
        }
    }
    # Core negation keys: no<key>=0 turns a setting ON, no<key>=1 turns it OFF.
    $negBool = @('server', 'dnsseed', 'discover', 'natpmp', 'listen', 'listenonion')
    $negDanger = @('onlynet', 'proxy', 'proxyrandomize', 'bind', 'whitebind', 'rpcbind', 'rpcallowip', 'torcontrol', 'onion', 'i2psam')
    for ($i = 0; $i -lt $existing.Count; $i++) {
        if ($existing[$i] -cmatch '^\s*(?:main\.)?no([a-z]+)\s*=\s*(.*)$') {
            $nk = $Matches[1]
            if ($negDanger -contains $nk) {
                Fail "cachecoin.conf uses the negation key no$nk, which changes a safety setting. Remove that line and start again."
            }
            if ($negBool -contains $nk) {
                $nv = $Matches[2]
                $nh = $nv.IndexOf('#'); if ($nh -ge 0) { $nv = $nv.Substring(0, $nh) }
                $nv = $nv.Trim()
                $truthy = $true
                if ($nv.Length -gt 0) {
                    $nm = [regex]::Match($nv, '^[+-]?[0-9]+')
                    if ($nm.Success) {
                        $ni = 0
                        if (-not [int]::TryParse($nm.Value, [ref]$ni)) { $truthy = $true } else { $truthy = ($ni -ne 0) }
                    } else { $truthy = $false }
                }
                $existing[$i] = $nk + $(if ($truthy) { '=0' } else { '=1' })
                $dottedFixed = $true
            }
        }
    }
    $scanSection = ''
    foreach ($l in $existing) {
        if ($l -match '^\s*\[([^\]]+)\]') { $scanSection = $Matches[1]; continue }
        if ($scanSection -cne '' -and $scanSection -cne 'main') { continue }
        # Core keys are case-sensitive, '#' starts a comment, and a value is true when it is empty
        # or its integer form is not zero (the node's own atoi rule, so "1abc" counts as 1).
        if ($l -cmatch '^\s*(listen|listenonion)\s*=(.*)$') {
            $val = $Matches[2]
            $hash = $val.IndexOf('#')
            if ($hash -ge 0) { $val = $val.Substring(0, $hash) }
            $val = $val.Trim()
            if ($val.Length -eq 0) { $confListen = $true; break }
            $numM = [regex]::Match($val, '^[+-]?[0-9]+')
            if ($numM.Success) {
                $num = 0
                if (-not [int]::TryParse($numM.Value, [ref]$num)) { $confListen = $true; break }
                if ($num -ne 0) { $confListen = $true; break }
            }
        }
    }
    $customBind = $false
    $stdBindSeen = $false
    $whiteBindSeen = $false
    $stdBinds = @('bind=127.0.0.1:29333', 'bind=127.0.0.1:29334=onion')
    $scanSection = ''
    foreach ($l in $existing) {
        if ($l -match '^\s*\[([^\]]+)\]') { $scanSection = $Matches[1]; continue }
        if ($scanSection -cne '' -and $scanSection -cne 'main') { continue }
        if ($l -cmatch '^\s*bind\s*=\s*(.*)$') {
            $bv = $Matches[1]
            $bh = $bv.IndexOf('#'); if ($bh -ge 0) { $bv = $bv.Substring(0, $bh) }
            $bv = $bv.Trim()
            $isStd = ($bv -ceq '127.0.0.1:29333') -or ($bv -ceq '127.0.0.1:29334=onion')
            if ($isStd) {
                $stdBindSeen = $true
            } else {
                $customBind = $true
                if ($bv -notmatch '^127\.0\.0\.1(:\d+)?(=onion)?$' -and $bv -notmatch '^\[::1\](:\d+)?(=onion)?$') {
                    Fail "cachecoin.conf binds a non-loopback address (bind=$bv). This package is Tor-only; remove that bind= line (or run the node directly if you really want a public listener)."
                }
            }
        }
        if ($l -cmatch '^\s*whitebind\s*=\s*(.*)$') {
            $wv = $Matches[1]
            $wh = $wv.IndexOf('#'); if ($wh -ge 0) { $wv = $wv.Substring(0, $wh) }
            $wv = $wv.Trim()
            # Core allows an optional permissions@ prefix; the node refuses "=onion" on whitebind.
            $wat = $wv.LastIndexOf('@'); if ($wat -ge 0) { $wv = $wv.Substring($wat + 1) }
            if ($wv -notmatch '^127\.0\.0\.1(:\d+)?$' -and $wv -notmatch '^\[::1\](:\d+)?$') {
                Fail "cachecoin.conf uses whitebind= with a non-loopback address (whitebind=$wv). This package is Tor-only; remove that line."
            }
            $whiteBindSeen = $true
        }
        if ($l -cmatch '^\s*(addnode|connect|seednode)\s*=\s*(.*)$') {
            $pk = $Matches[1]
            $pv = $Matches[2]
            $ph = $pv.IndexOf('#'); if ($ph -ge 0) { $pv = $pv.Substring(0, $ph) }
            $pv = $pv.Trim()
            # Core's own idiom: connect=0 disables automatic connections. It reaches no clearnet host,
            # so it is kept instead of being refused as a "non-onion peer".
            $autoOff = ($pk -ceq 'connect') -and ($pv -ceq '0')
            if (-not $autoOff -and $pv -notmatch '\.onion(:\d+)?$') {
                Fail "cachecoin.conf points at a non-onion peer ($pk=$pv). This package is Tor-only; remove that line."
            }
        }
    }
    # The node refuses bind= or whitebind= together with listen=0, so any of them keeps listening on.
    $effectiveListen = $Listen -or $confListen -or $customBind -or $stdBindSeen -or $whiteBindSeen
    $script:ConfigListening = $effectiveListen
    if ($effectiveListen) {
        $required['listen'] = '1'
        $required['listenonion'] = '1'
        if ($ProxyPort -eq 9150) { $required['torcontrol'] = '127.0.0.1:9151' } else { $required['torcontrol'] = '127.0.0.1:9051' }
        if ($customBind) {
            $bindLines = @()
            Write-Log 'A custom bind= line is set in cachecoin.conf; the launcher keeps it and keeps listening so the node can start. Make sure it only binds loopback addresses.' 'WARN'
        } else {
            $bindLines = @('bind=127.0.0.1:29333', 'bind=127.0.0.1:29334=onion')
        }
    }
    $proxyValue = [string]$required['proxy']
    $torcontrolValue = ''
    if ($effectiveListen) {
        if ($ProxyPort -eq 9150) { $torcontrolValue = '127.0.0.1:9151' } else { $torcontrolValue = '127.0.0.1:9051' }
    }
    $proxyChanged = $false
    $torcontrolChanged = $false
    $listenChanged = $false
    $netChanged = $false
    $customTorControl = $false
    $localProxyEmitted = $false
    $newLines = New-Object System.Collections.Generic.List[string]
    $section = ''
    foreach ($l in $existing) {
        if ($l -match '^\s*\[([^\]]+)\]') {
            $section = $Matches[1]
            $newLines.Add($l)
            continue
        }
        $inScope = ($section -ceq '' -or $section -ceq 'main')
        # Tor-only is the point of CacheCoin: a stale clearnet, DNS-seed or open-RPC setting is corrected, not trusted.
        if ($inScope -and $l -cmatch '^\s*(server|onlynet|dnsseed|discover|natpmp|rpcbind|rpcallowip|rpcport)\s*=\s*(.*)$') {
            $netKey = $Matches[1].ToLowerInvariant()
            $netWant = [string]$required[$netKey]
            if ($l.Trim() -ine "$netKey=$netWant") {
                $newLines.Add("$netKey=$netWant")
                $netChanged = $true
            } else {
                $newLines.Add($l)
            }
            continue
        }
        if ($inScope -and $l -cmatch '^\s*proxy\s*=') {
            if ($l -cmatch '^\s*proxy\s*=\s*127\.0\.0\.1:\d+\s*(#.*)?$') {
                if (-not $localProxyEmitted) {
                    $newLines.Add("proxy=$proxyValue")
                    $localProxyEmitted = $true
                    if ($l.Trim() -ne "proxy=$proxyValue") { $proxyChanged = $true }
                } else {
                    $proxyChanged = $true
                }
            } else {
                Fail "cachecoin.conf sets a proxy that is not the local Tor ($($l.Trim())). This package uses Tor at 127.0.0.1 only; remove that proxy= line."
            }
            continue
        }
        # A conf onion= line outranks the proxy= pin for onion connections and can point them at a
        # clearnet host, so it is corrected like proxy= (loopback) or refused (anything else).
        if ($inScope -and $l -cmatch '^\s*onion\s*=') {
            if ($l -cmatch '^\s*onion\s*=\s*127\.0\.0\.1:\d+\s*(#.*)?$') {
                $newLines.Add("onion=$proxyValue")
                if ($l.Trim() -ne "onion=$proxyValue") { $proxyChanged = $true }
            } else {
                Fail "cachecoin.conf sets an onion proxy that is not the local Tor ($($l.Trim())). This package uses Tor at 127.0.0.1 only; remove that onion= line."
            }
            continue
        }
        # I2P is not used by this package: an i2psam= line can make the node dial a clearnet host.
        if ($inScope -and $l -cmatch '^\s*i2psam\s*=') {
            Fail "cachecoin.conf sets i2psam, which this package does not use. Remove that i2psam= line (or delete the file) and start again."
        }
        # Randomizing Tor credentials is part of the Tor-only posture: anything but 1 is refused.
        if ($inScope -and $l -cmatch '^\s*(?:main\.)?proxyrandomize\s*=(.*)$') {
            $rv = $Matches[1]
            $rh = $rv.IndexOf('#'); if ($rh -ge 0) { $rv = $rv.Substring(0, $rh) }
            $rv = $rv.Trim()
            if ($rv -ne '1') {
                Fail "cachecoin.conf sets proxyrandomize to something other than 1 ($($l.Trim())). Remove that line (or set it to 1) and start again."
            }
            $newLines.Add($l)
            continue
        }
        if ($inScope -and $torcontrolValue -and $l -cmatch '^\s*torcontrol\s*=(.*)$') {
            $tv = $Matches[1]
            $th = $tv.IndexOf('#')
            if ($th -ge 0) { $tv = $tv.Substring(0, $th) }
            $tv = $tv.Trim()
            if ($tv -eq '127.0.0.1:9051' -or $tv -eq '127.0.0.1:9151') {
                if ($tv -ne $torcontrolValue) {
                    $newLines.Add("torcontrol=$torcontrolValue")
                    $torcontrolChanged = $true
                } else {
                    $newLines.Add($l)
                }
            } else {
                $newLines.Add($l)
                $customTorControl = $true
            }
            continue
        }
        if ($inScope -and $effectiveListen -and $l -cmatch '^\s*listen\s*=') {
            if ($l.Trim() -cne 'listen=1') {
                $newLines.Add('listen=1')
                $listenChanged = $true
            } else {
                $newLines.Add($l)
            }
            continue
        }
        if ($inScope -and $effectiveListen -and $l -cmatch '^\s*listenonion\s*=') {
            if ($l.Trim() -cne 'listenonion=1') {
                $newLines.Add('listenonion=1')
                $listenChanged = $true
            } else {
                $newLines.Add($l)
            }
            continue
        }
        $newLines.Add($l)
    }
    $proxySeen = $localProxyEmitted
    $missing = @()
    foreach ($k in $required.Keys) {
        if ($k -eq 'proxy' -and $proxySeen) { continue }
        $found = $false
        $scanSection = ''
        foreach ($l in $existing) {
            if ($l -match '^\s*\[([^\]]+)\]') { $scanSection = $Matches[1]; continue }
            if ($scanSection -cne '' -and $scanSection -cne 'main') { continue }
            if ($l -cmatch ("^\s*" + [regex]::Escape($k) + "\s*=")) { $found = $true; break }
        }
        if (-not $found) { $missing += $k }
    }
    $missingBinds = @()
    foreach ($b in $bindLines) {
        $wantVal = $b -replace '^bind=', ''
        $found = $false
        $scanSection = ''
        foreach ($l in $existing) {
            if ($l -match '^\s*\[([^\]]+)\]') { $scanSection = $Matches[1]; continue }
            if ($scanSection -cne '' -and $scanSection -cne 'main') { continue }
            if ($l -cmatch '^\s*bind\s*=\s*(.*)$') {
                $bv = $Matches[1]
                $bh = $bv.IndexOf('#'); if ($bh -ge 0) { $bv = $bv.Substring(0, $bh) }
                if ($bv.Trim() -ceq $wantVal) { $found = $true; break }
            }
        }
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
    # Shipped seeds are injected once per package version (a migration), never on every run:
    # an operator who removes or comments a seed keeps that choice afterwards.
    $missingSeeds = @()
    if ($MigrateSeeds) {
        foreach ($s in $script:Seeds) {
            $found = $false
            $scanSection = ''
            foreach ($l in $existing) {
                if ($l -match '^\s*\[([^\]]+)\]') { $scanSection = $Matches[1]; continue }
                if ($scanSection -cne '' -and $scanSection -cne 'main') { continue }
                $lt = $l.Trim()
                if ($lt -ceq "addnode=$s" -or $lt -ceq "# addnode=$s" -or $lt -ceq "#addnode=$s") { $found = $true; break }
            }
            if (-not $found) { $missingSeeds += $s }
        }
    }
    if ($missingSeeds.Count -gt 0) {
        $insertAt = -1
        for ($i = 0; $i -lt $newLines.Count; $i++) {
            if ($newLines[$i] -match '^\s*\[') { $insertAt = $i; break }
        }
        if ($insertAt -ge 0) {
            for ($j = $missingSeeds.Count - 1; $j -ge 0; $j--) { $newLines.Insert($insertAt, "addnode=$($missingSeeds[$j])") }
        } else {
            foreach ($s in $missingSeeds) { $newLines.Add("addnode=$s") }
        }
    }
    if ($missing.Count -gt 0 -or $missingBinds.Count -gt 0 -or $missingSeeds.Count -gt 0 -or $proxyChanged -or $torcontrolChanged -or $listenChanged -or $netChanged -or $dottedFixed -or $converted) {
        try { Write-TextAtomic -Path $script:ConfPath -Lines $newLines.ToArray() -Encoding $confEncoding }
        catch { Fail "Could not update $($script:ConfPath): $($_.Exception.Message)" }
        if ($missing.Count -gt 0) { Write-Log ('Added missing settings: ' + ($missing -join ', ')) }
        if ($missingBinds.Count -gt 0) { Write-Log 'Added loopback bind lines for incoming connections.' }
        if ($missingSeeds.Count -gt 0) { Write-Log ('Added seed nodes: ' + ($missingSeeds -join ', ')) }
        if ($proxyChanged) { Write-Log "Updated the local proxy setting to 127.0.0.1:$ProxyPort." }
        if ($torcontrolChanged) { Write-Log "Updated the Tor control setting to $torcontrolValue." }
        if ($listenChanged) { Write-Log 'Updated the incoming-connection settings to match this run (mining also serves other nodes).' }
        if ($netChanged) { Write-Log 'Corrected a non-Tor network setting in cachecoin.conf (Tor-only is enforced).' 'WARN' }
        if ($dottedFixed) { Write-Log 'Normalized dotted main.<key> settings in cachecoin.conf.' }
        if ($converted) { Write-Log 'Converted cachecoin.conf to UTF-8 (it was UTF-16 or had a BOM).' }
    }
    # A very large memory/connection value or a zero fee floor is legal but dangerous on a small PC.
    $capWarn = $false
    $capSection = ''
    foreach ($l in $existing) {
        if ($l -match '^\s*\[([^\]]+)\]') { $capSection = $Matches[1]; continue }
        if ($capSection -cne '' -and $capSection -cne 'main') { continue }
        if ($l -match '^\s*dbcache\s*=\s*(\d+)') { $cv = 0L; if ((-not [long]::TryParse($Matches[1], [ref]$cv)) -or $cv -gt 2000) { $capWarn = $true } }
        if ($l -match '^\s*maxmempool\s*=\s*(\d+)') { $cv = 0L; if ((-not [long]::TryParse($Matches[1], [ref]$cv)) -or $cv -gt 1000) { $capWarn = $true } }
        if ($l -match '^\s*maxconnections\s*=\s*(\d+)') { $cv = 0L; if ((-not [long]::TryParse($Matches[1], [ref]$cv)) -or $cv -gt 256) { $capWarn = $true } }
        if ($l -match '^\s*fallbackfee\s*=\s*(0|0\.0+)\s*$') { $capWarn = $true }
    }
    if ($capWarn) {
        Write-Log 'cachecoin.conf has a very large memory/connection value or a zero fee floor; that can exhaust a small PC or block sending. Review dbcache, maxmempool, maxconnections and fallbackfee.' 'WARN'
    }
    if ($customTorControl) {
        Write-Log 'A custom Tor control port is set in cachecoin.conf; the launcher keeps it. Incoming connections need that Tor to accept control connections.' 'WARN'
    }
}

function Invoke-Rpc {
    param([string[]]$RpcArgs)
    # A native program that writes to stderr raises a terminating error under
    # $ErrorActionPreference='Stop' even when it exits 0, so run this call locally quiet.
    $savedEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $out = & $script:Cli "-datadir=$($script:DataDir)" '-rpcclienttimeout=10' '-chain=main' @RpcArgs 2>&1
        $code = $LASTEXITCODE
        if ($code -ne 0) { return $null }
        # Keep only real output lines: merged stderr ErrorRecords must not corrupt the JSON.
        return ((@($out) | Where-Object { $_ -is [string] }) | Out-String).Trim()
    } catch {
        return $null
    } finally {
        $ErrorActionPreference = $savedEap
    }
}

# Stop is a recovery path (for example after a foreign node is refused), so it tries the pinned chain
# first and then without it: a legacy conf with regtest=1 refuses -chain=main, while a conf with
# chain=regtest needs -chain=main for the cookie lookup.
function Invoke-StopCli {
    param([string]$CliPath)
    $savedEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        try { $null = & $CliPath "-datadir=$($script:DataDir)" '-rpcclienttimeout=15' '-chain=main' stop 2>&1 } catch { }
        if ($LASTEXITCODE -eq 0) { return $true }
        try { $null = & $CliPath "-datadir=$($script:DataDir)" '-rpcclienttimeout=15' stop 2>&1 } catch { }
        return ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $savedEap
    }
}

# A node this launcher did not start may still be able to reach the open internet while the window
# claims Tor-only. getnetworkinfo is the only place that shows the running process's real profile:
# a pinned node reports ipv4/ipv6/i2p/cjdns unreachable, onion reachable, and a loopback onion proxy.
function Test-TorOnlyProfile {
    param([string]$Json)
    if (-not $Json) { return $false }
    try {
        $j = $Json | ConvertFrom-Json
        $net = @{}
        foreach ($n in @($j.networks)) { if ($n -and $n.name) { $net[[string]$n.name] = $n } }
        foreach ($name in @('ipv4', 'ipv6', 'i2p', 'cjdns')) {
            if (-not $net.ContainsKey($name)) { return $false }
            $r = $net[$name].PSObject.Properties['reachable']
            $p = $net[$name].PSObject.Properties['proxy']
            if ($null -eq $r -or $null -eq $p) { return $false }
            if (-not ($r.Value -is [bool])) { return $false }
            if ($r.Value) { return $false }
            # A remote proxy for a clearnet network can carry manual (addnode/connect) traffic.
            $pv = [string]$p.Value
            if ($pv -ne '' -and $pv -notmatch '^127\.0\.0\.1:\d+$') { return $false }
        }
        if (-not $net.ContainsKey('onion')) { return $false }
        $onionReach = $net['onion'].PSObject.Properties['reachable']
        $onionProxy = $net['onion'].PSObject.Properties['proxy']
        if ($null -eq $onionReach -or $null -eq $onionProxy) { return $false }
        if (-not ($onionReach.Value -is [bool])) { return $false }
        if (-not $onionReach.Value) { return $false }
        return ([string]$onionProxy.Value -match '^127\.0\.0\.1:\d+$')
    } catch {
        return $false
    }
}

# A peer that is a Tor onion or a loopback address is local-only and safe. Inbound onion peers
# arrive through the local Tor onion service, so the node reports them as 127.0.0.1.
function Test-OnionOrLoopbackPeer {
    param([string]$Address)
    if (-not $Address) { return $false }
    if ($Address -match '\.onion(:\d+)?$') { return $true }
    if ($Address -match '^127\.0\.0\.1(:\d+)?$') { return $true }
    if ($Address -match '^\[::1\](:\d+)?$') { return $true }
    if ($Address -match '^::1(:\d+)?$') { return $true }
    return $false
}

# A node can report a Tor-only network profile and still hold manual clearnet peers. Every added
# node and every current peer must be an onion or loopback address; anything unreadable fails closed.
function Test-TorOnlyPeers {
    param([string]$AddedJson, [string]$PeersJson)
    if ([string]::IsNullOrWhiteSpace($AddedJson) -or [string]::IsNullOrWhiteSpace($PeersJson)) { return $false }
    try {
        $added = $AddedJson | ConvertFrom-Json
        $peers = $PeersJson | ConvertFrom-Json
        if ($null -eq $added -or $null -eq $peers) { return $false }
        foreach ($a in @($added)) {
            if ($null -eq $a) { return $false }
            $an = [string]$a.addednode
            if (-not (Test-OnionOrLoopbackPeer $an)) { return $false }
            foreach ($ad in @($a.addresses)) {
                if ($null -eq $ad) { return $false }
                $addr = [string]$ad.address
                if (-not (Test-OnionOrLoopbackPeer $addr)) { return $false }
            }
        }
        foreach ($p in @($peers)) {
            if ($null -eq $p) { return $false }
            $pa = [string]$p.addr
            if (-not (Test-OnionOrLoopbackPeer $pa)) { return $false }
        }
        return $true
    } catch {
        return $false
    }
}

# The default P2P ports must never be listening on a non-loopback address. GetActiveTcpListeners
# needs no process handle, so it also works for a node this launcher did not start.
function Test-TorOnlyListeners {
    try {
        $eps = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        foreach ($ep in $eps) {
            if ($ep.Port -ne 29333 -and $ep.Port -ne 29334) { continue }
            if ($ep.Address -and -not [System.Net.IPAddress]::IsLoopback($ep.Address)) { return $false }
        }
        return $true
    } catch {
        return $true   # no OS API available: do not block startup on it
    }
}

# Chain selectors and RPC-channel keys belong to this package, not to cachecoin.conf: a stale or
# hostile line here stops the node from starting or makes every RPC call fail.
function Get-ForbiddenConfKey {
    param([string]$Line)
    if ($Line -cmatch '^\s*(?:main\.)?(?:no)?(chain|regtest|testnet4|testnet|signet)\s*=') { return $Matches[1] }
    if ($Line -cmatch '^\s*(?:main\.)?(rpcconnect|rpcwhitelistdefault|rpcwhitelist)\s*=') { return $Matches[1] }
    # Expensive or wallet-selecting start-up switches: a hostile line here makes the node redo hours
    # of work on every start or loads a different wallet than the one the window manages.
    if ($Line -cmatch '^\s*(?:main\.)?(?:no)?(reindex-chainstate|reindex|rescan|zapwallettxes|walletdir|wallet|prune|txindex|upgradewallet|salvagewallet|settings)\s*=') { return $Matches[1] }
    return ''
}

# Core treats a non-empty line that is not a section, a comment or key=value as a fatal parse error;
# a hostile one-word line would stop the node until the file is edited by hand. Only a complete
# "[name]" line is a section to Core: "[main] foo" and "[" are parse errors.
function Get-BareConfLine {
    param([string]$Line)
    $t = $Line
    $h = $t.IndexOf('#'); if ($h -ge 0) { $t = $t.Substring(0, $h) }
    $t = $t.Trim()
    if ($t.Length -eq 0) { return '' }
    if ($t.StartsWith('[')) {
        if ($t -match '^\[[^\]]*\]$') { return '' }
        return $t
    }
    if ($t.Contains('=')) { return '' }
    return $t
}

function Wait-Rpc {
    param([int]$Seconds = 180, [string]$StopMarker = '')
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (Invoke-Rpc @('getblockchaininfo')) { return $true }
        if ($StopMarker -and (Test-Path -LiteralPath $StopMarker)) { return $false }
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
        $nodeArgs = @("`"-datadir=$($script:DataDir)`"", "`"-conf=$($script:ConfPath)`"", '-printtoconsole=0',
            '-nosettings', '-chain=main', '-onlynet=onion',
            "-proxy=127.0.0.1:$($script:ProxyPort)",
            "-onion=127.0.0.1:$($script:ProxyPort)",
            '-i2pacceptincoming=0',
            '-dnsseed=0', '-discover=0', '-natpmp=0')
        if ($script:ConfigListening) {
            $nodeArgs += @('-listen=1', '-listenonion=1')
        } else {
            $nodeArgs += @('-listen=0', '-listenonion=0')
        }
        $script:NodeProcess = Start-Process -FilePath $script:Daemon -ArgumentList $nodeArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput $script:NodeOutLog -RedirectStandardError $script:NodeErrLog
        $null = $script:NodeProcess.Handle
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
            Write-Host 'Mining is paused (waiting for the node, sync or peers).'
        } else {
            Write-Host ('Mining: {0} worker(s). Blocks found: {1}. Worker runs: {2}.' -f $script:MiningJobs.Count, $script:FoundBlocks, $script:WorkerRuns)
        }
    }
    if ($st.WalletLoaded) {
        Write-Host ('Balance: {0} CCCN trusted, {1} CCCN immature (spendable after 100 blocks).' -f $st.Balance, $st.Immature)
    } else {
        Write-Host 'Balance: no wallet is loaded in this node session. The CacheCoin App loads its wallet when it is open.'
    }
}

function Get-RecommendedThreads {
    $cores = [Environment]::ProcessorCount
    if ($cores -lt 1) { $cores = 1 }
    return [Math]::Min(4, [Math]::Max(1, $cores - 1))
}

# The rule for the thread count: exactly the core count means "use every core"; anything above the
# core count is unsafe, so it falls back to cores-1; anything from 1 to cores-1 is used as asked.
function Resolve-MiningThreads {
    param([int]$Requested, [int]$Cores)
    if ($Cores -lt 1) { $Cores = 1 }
    if ($Requested -le 0) { $Requested = Get-RecommendedThreads }
    if ($Requested -gt $Cores) { return [Math]::Max(1, $Cores - 1) }
    return $Requested
}

# Ask how many processors mining should use. The machine's count is never shown; it is only used
# to keep the answer inside what this computer can actually run.
function Read-MiningThreads {
    $cores = [Environment]::ProcessorCount
    if ($cores -lt 1) { $cores = 1 }
    $def = Get-RecommendedThreads
    Write-Host ''
    Write-Host 'How many processors do you want to spend on mining?'
    Write-Host 'Type a number, for example 2. More processors mine faster and make the computer hotter and louder.'
    for ($i = 0; $i -lt 5; $i++) {
        $a = Read-Host 'Processors, as a number (Enter = recommended)'
        if (-not $a) { return $def }
        $v = 0
        if ([int]::TryParse($a.Trim(), [ref]$v)) {
            if ($v -lt 1) { Write-Host 'At least 1 processor is needed.'; continue }
            if ($v -gt $cores) {
                $safe = [Math]::Max(1, $cores - 1)
                Write-Host "This computer cannot give mining that many; it will use $safe processors."
                return $safe
            }
            return $v
        }
        Write-Host 'Type a number, or press Enter for the recommended value.'
    }
    return $def
}

function Start-MiningWorker {
    $job = Start-Job -ScriptBlock {
        param($CliPath, $DataDir, $Addr)
        $out = & $CliPath "-datadir=$DataDir" '-rpcclienttimeout=0' '-chain=main' 'generatetoaddress' '1' $Addr '500' 2>&1
        [pscustomobject]@{ Output = (($out | Out-String).Trim()); ExitCode = $LASTEXITCODE }
    } -ArgumentList $script:Cli, $script:DataDir, $script:Address
    $script:MiningJobs += $job
}

function Start-Mining {
    if ($script:Mining) { return }
    if (-not $script:Address) { Write-Log 'No mining address; not starting.' 'WARN'; return }
    if ($script:Threads -lt 1) { $script:Threads = Get-RecommendedThreads }
    $script:Mining = $true
    $script:MiningGated = $false
    $script:MiningNextRefill = Get-Date
    $n = $script:Threads
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
            if ($height -gt 0) {
                Write-Log ('Block found at height {0}. Spendable after 100 more blocks.' -f $height)
            } else {
                Write-Log 'Block found. Spendable after 100 more blocks.'
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
    $target = $script:Threads
    if ($target -lt 1) { $target = Get-RecommendedThreads }
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
    }
    if (-not $script:ClockWarned) {
        if ($script:TimeOffset -lt -300) {
            Write-Log ('Peers report a time difference of about {0} seconds: your clock may be ahead. If Windows time is wrong, fix it; a block found with a wrong clock can be rejected by the network. Mining is not paused for this alone.' -f [Math]::Abs($script:TimeOffset)) 'WARN'
            $script:ClockWarned = $true
        } elseif ($script:TimeOffset -gt 300) {
            Write-Log ('Peers report a time difference of about {0} seconds: your clock may be behind. If Windows time is wrong, fix it. Mining is not paused for this alone.' -f $script:TimeOffset) 'WARN'
            $script:ClockWarned = $true
        } elseif ($script:LastTipTime -gt 0 -and $script:LastTipTime -gt ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 300)) {
            Write-Log 'The chain tip is ahead of this computer''s clock. If Windows time is wrong, fix it. Mining is not paused for this alone.' 'WARN'
            $script:ClockWarned = $true
        }
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

# A valid CacheCoin mainnet address: starts with cccn1 and the node confirms it is a witness address.
# Returns the canonical (lowercase) form, or '' when it is not usable.
function Get-ValidMainnetAddress {
    param([string]$Address)
    if (-not $Address) { return '' }
    $a = $Address.Trim().ToLowerInvariant()
    if ($a -notmatch '^cccn1[ac-hj-np-z02-9]{6,87}$') { return '' }
    $v = Invoke-Rpc @('validateaddress', $a)
    if (-not $v) { return '' }
    try {
        $j = $v | ConvertFrom-Json
        if ([bool]$j.isvalid -and [bool]$j.iswitness) { return [string]$j.address }
        return ''
    } catch { return '' }
}

function Save-State {
    param([string]$Mode)
    try {
        $existing = Read-State
        $fp = $script:WalletFingerprint
        if (-not $fp -and $existing -and $existing.walletFingerprint) { $fp = [string]$existing.walletFingerprint }
        # Never erase a saved mining address just because this run chose none.
        $addr = $script:Address
        if (-not $addr -and $existing -and $existing.miningAddress) { $addr = [string]$existing.miningAddress }
        # A node-only run has no thread choice: keep the last saved one instead of writing 0.
        $thr = $script:Threads
        if ($thr -lt 1 -and $existing -and $existing.threads) {
            $tval = 0
            if ([int]::TryParse([string]$existing.threads, [ref]$tval) -and $tval -ge 1) { $thr = $tval }
        }
        $json = ([ordered]@{
            mode              = $Mode
            backupConfirmed   = $script:BackupConfirmed
            miningAddress     = $addr
            threads           = $thr
            seedsVersion      = 2
            walletFingerprint = $fp
            version           = 1
        } | ConvertTo-Json -Depth 4)
        Write-TextAtomic -Path $script:StateFile -Lines @($json) -Encoding (New-Object System.Text.UTF8Encoding($false))
    } catch { }
}

function Read-State {
    if (Test-Path -LiteralPath $script:StateFile) {
        try {
            $raw = Get-Content -LiteralPath $script:StateFile -Raw
            if ($null -eq $raw -or $raw.Trim().Length -eq 0) {
                try { Copy-Item -LiteralPath $script:StateFile -Destination "$($script:StateFile).bad" -Force } catch { }
                return $null
            }
            return ($raw | ConvertFrom-Json)
        } catch {
            try { Copy-Item -LiteralPath $script:StateFile -Destination "$($script:StateFile).bad" -Force } catch { }
            return $null
        }
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
    Write-Host 'Usage: powershell -NoProfile -ExecutionPolicy Bypass -File launcher\CacheCoin.ps1 [-Silent] [-Mode node|mining] [-RunSeconds N] [-Stop] [-Takeover] [-DisableAutostart] [-EnableAutostart]'
    Write-Host '  -Silent           run without prompts (used by autostart)'
    Write-Host '  -Mode             force node-only or node+mining'
    Write-Host '  -RunSeconds       stop cleanly after N seconds (testing)'
    Write-Host '  -Stop             stop the running node (the launcher exits when it stops)'
    Write-Host '  -Takeover         close another running controller without asking, then continue'
    Write-Host '  -DisableAutostart remove the logon task and exit'
    Write-Host '  -SelfTest         run the built-in checks and exit'
    Write-Host '  -EnableAutostart  register the logon task for this folder and exit'
    $script:SelfTestFail = 0
    function Check {
        param([string]$Name, [bool]$Ok)
        if ($Ok) { Write-Host "OK   $Name" } else { Write-Host "FAIL $Name"; $script:SelfTestFail++ }
    }
    Check 'threads: 8 of 8 cores -> 8' ((Resolve-MiningThreads -Requested 8 -Cores 8) -eq 8)
    Check 'threads: 9 of 8 cores -> 7' ((Resolve-MiningThreads -Requested 9 -Cores 8) -eq 7)
    Check 'threads: 3 of 8 cores -> 3' ((Resolve-MiningThreads -Requested 3 -Cores 8) -eq 3)
    Check 'threads: 2 of 1 core -> 1' ((Resolve-MiningThreads -Requested 2 -Cores 1) -eq 1)
    Check 'threads: 0 -> recommended' ((Resolve-MiningThreads -Requested 0 -Cores 8) -eq (Get-RecommendedThreads))
    Check 'address: cccn1 bech32 pattern' ('cccn1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh' -match '^cccn1[ac-hj-np-z02-9]{6,87}$')
    Check 'address: bitcoin bc1 rejected' (-not ('bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh' -match '^cccn1[ac-hj-np-z02-9]{6,87}$'))

    # Config rewrite: mining must turn listening on even in an old conf that says listen=0,
    # and the peer caps must be written. Uses a throwaway folder, never the real data folder.
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('cccn-selftest-' + [guid]::NewGuid().ToString('N'))
    $savedData = $script:DataDir
    $savedLogDir = $script:LogDir
    $savedLogFile = $script:LogFile
    $savedConf = $script:ConfPath
    try {
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $script:DataDir = $tmp
        $script:LogDir = Join-Path $tmp 'logs'
        $script:LogFile = Join-Path $script:LogDir 'launcher.log'
        $script:ConfPath = Join-Path $tmp 'cachecoin.conf'
        Set-Content -LiteralPath $script:ConfPath -Value @('listen=0', 'listenonion=0', 'proxy=127.0.0.1:9050', 'onlynet=onion') -Encoding ASCII
        Initialize-Config -ProxyPort 9050 -Listen $true -MigrateSeeds $true
        $t = Get-Content -LiteralPath $script:ConfPath -Raw
        Check 'config: mining turns listening on in an old conf' (($t -match '(?m)^listen=1\s*$') -and ($t -match '(?m)^listenonion=1\s*$') -and ($t -match '(?m)^torcontrol=127\.0\.0\.1:9051\s*$'))
        Check 'config: peer caps are written' (($t -match '(?m)^maxconnections=32\s*$') -and ($t -match '(?m)^maxuploadtarget=5000\s*$'))
        Check 'config: both seed nodes are written' (($t -match '(?m)^addnode=ag7rydtma\S*\.onion:29333\s*$') -and ($t -match '(?m)^addnode=7uodchun\S*\.onion:29333\s*$'))
        Check 'config: loopback binds are added' (($t -match '(?m)^bind=127\.0\.0\.1:29333\s*$') -and ($t -match '(?m)^bind=127\.0\.0\.1:29334=onion\s*$'))
        # Idempotent: a second mining run must not change the file or duplicate keys.
        $h1 = (Get-FileHash -LiteralPath $script:ConfPath -Algorithm SHA256).Hash
        Initialize-Config -ProxyPort 9050 -Listen $true
        $h2 = (Get-FileHash -LiteralPath $script:ConfPath -Algorithm SHA256).Hash
        $t2 = Get-Content -LiteralPath $script:ConfPath -Raw
        $listenCount = ([regex]::Matches($t2, '(?m)^listen=1\s*$')).Count
        Check 'config: a second mining run changes nothing (idempotent)' ($h1 -eq $h2)
        Check 'config: no duplicate listen lines' ($listenCount -eq 1)
        # False-detection guard: a node-only run must not turn an existing listener off.
        Initialize-Config -ProxyPort 9050 -Listen $false
        $t3 = Get-Content -LiteralPath $script:ConfPath -Raw
        Check 'config: a node-only run keeps an existing listener on' (($t3 -match '(?m)^listen=1\s*$') -and ($t3 -match '(?m)^listenonion=1\s*$'))
        # Tor-only is enforced, not trusted.
        Set-Content -LiteralPath $script:ConfPath -Value @('server=0', 'onlynet=ipv4', 'dnsseed=1', 'proxy=127.0.0.1:9050') -Encoding ASCII
        Initialize-Config -ProxyPort 9050 -Listen $false
        $tn = Get-Content -LiteralPath $script:ConfPath -Raw
        Check 'config: a non-Tor network setting is corrected' (($tn -match '(?m)^server=1\s*$') -and ($tn -match '(?m)^onlynet=onion\s*$') -and ($tn -match '(?m)^dnsseed=0\s*$'))
        # A custom loopback bind must keep the node listening, or it refuses to start.
        Set-Content -LiteralPath $script:ConfPath -Value @('listen=0', 'bind=127.0.0.1:29335', 'proxy=127.0.0.1:9050') -Encoding ASCII
        Initialize-Config -ProxyPort 9050 -Listen $false
        $tb = Get-Content -LiteralPath $script:ConfPath -Raw
        Check 'config: a custom bind keeps the node listening' (($tb -cmatch '(?m)^listen=1\s*$') -and ($tb -cmatch '(?m)^bind=127\.0\.0\.1:29335\s*$'))
        # A whitebind= line is refused by the node together with listen=0 too: count it as listening.
        Set-Content -LiteralPath $script:ConfPath -Value @('listen=0', 'whitebind=@127.0.0.1:29335', 'proxy=127.0.0.1:9050') -Encoding ASCII
        Initialize-Config -ProxyPort 9050 -Listen $false
        $twb = Get-Content -LiteralPath $script:ConfPath -Raw
        Check 'config: a whitebind keeps the node listening' (($twb -cmatch '(?m)^listen=1\s*$') -and ($twb -cmatch '(?m)^whitebind=@127\.0\.0\.1:29335\s*$'))
        Set-Content -LiteralPath $script:ConfPath -Value @('listen=0', 'whitebind=download@127.0.0.1:29336', 'proxy=127.0.0.1:9050') -Encoding ASCII
        Initialize-Config -ProxyPort 9050 -Listen $false
        $twb2 = Get-Content -LiteralPath $script:ConfPath -Raw
        Check 'config: a whitebind with a permissions prefix keeps listening' (($twb2 -cmatch '(?m)^listen=1\s*$') -and ($twb2 -cmatch '(?m)^whitebind=download@127\.0\.0\.1:29336\s*$'))
        # A loopback onion= proxy is pointed at the Tor in use; a remote one is refused.
        Set-Content -LiteralPath $script:ConfPath -Value @('listen=0', 'onion=127.0.0.1:9999', 'proxy=127.0.0.1:9050') -Encoding ASCII
        Initialize-Config -ProxyPort 9050 -Listen $false
        $ton = Get-Content -LiteralPath $script:ConfPath -Raw
        Check 'config: a loopback onion= proxy follows the Tor in use' ($ton -cmatch '(?m)^onion=127\.0\.0\.1:9050\s*$')
        # Core's connect=0 idiom disables automatic connections and is kept, not refused as a peer.
        Set-Content -LiteralPath $script:ConfPath -Value @('listen=0', 'connect=0', 'proxy=127.0.0.1:9050') -Encoding ASCII
        Initialize-Config -ProxyPort 9050 -Listen $false
        $tco = Get-Content -LiteralPath $script:ConfPath -Raw
        Check 'config: connect=0 is kept (it disables automatic connections)' ($tco -cmatch '(?m)^connect=0\s*$')
        # Randomized Tor credentials are part of the Tor-only posture; =1 is kept, anything else refused.
        Set-Content -LiteralPath $script:ConfPath -Value @('listen=0', 'proxyrandomize=1', 'proxy=127.0.0.1:9050') -Encoding ASCII
        Initialize-Config -ProxyPort 9050 -Listen $false
        $tpr = Get-Content -LiteralPath $script:ConfPath -Raw
        Check 'config: proxyrandomize=1 is kept' ($tpr -cmatch '(?m)^proxyrandomize=1\s*$')
        # A stop request must end an RPC wait instead of waiting out the whole timeout.
        $mk = Join-Path $tmp 'stop-requested'
        Set-Content -LiteralPath $mk -Value 'test' -Encoding ASCII
        Check 'wait: a stop marker ends the RPC wait' (-not (Wait-Rpc -Seconds 30 -StopMarker $mk))
        Remove-Item -LiteralPath $mk -Force -ErrorAction SilentlyContinue
        # Chain selectors and RPC-channel keys are refused before anything runs.
        Check 'config: chain= is refused' ((Get-ForbiddenConfKey 'chain=regtest') -eq 'chain')
        Check 'config: regtest= is refused' ((Get-ForbiddenConfKey 'regtest=1') -eq 'regtest')
        Check 'config: noregtest=0 is refused' ((Get-ForbiddenConfKey 'noregtest=0') -eq 'regtest')
        Check 'config: dotted main.chain= is refused' ((Get-ForbiddenConfKey 'main.chain=regtest') -eq 'chain')
        Check 'config: testnet4= is refused' ((Get-ForbiddenConfKey 'testnet4=1') -eq 'testnet4')
        Check 'config: rpcconnect= is refused' ((Get-ForbiddenConfKey 'rpcconnect=192.0.2.1') -eq 'rpcconnect')
        Check 'config: rpcport= is not a forbidden key' ((Get-ForbiddenConfKey 'rpcport=29332') -eq '')
        Check 'config: reindex= is refused' ((Get-ForbiddenConfKey 'reindex=1') -eq 'reindex')
        Check 'config: wallet= is refused' ((Get-ForbiddenConfKey 'wallet=evil') -eq 'wallet')
        Check 'config: prune= is refused' ((Get-ForbiddenConfKey 'prune=550') -eq 'prune')
        Check 'config: txindex= is refused' ((Get-ForbiddenConfKey 'txindex=1') -eq 'txindex')
        Check 'config: rescan= is refused' ((Get-ForbiddenConfKey 'rescan=1') -eq 'rescan')
        Check 'config: noreindex=0 is refused' ((Get-ForbiddenConfKey 'noreindex=0') -eq 'reindex')
        Check 'config: a bare word is refused' ((Get-BareConfLine 'proxy') -eq 'proxy')
        Check 'config: a comment is not a bare word' ((Get-BareConfLine '# proxy') -eq '')
        Check 'config: a section is not a bare word' ((Get-BareConfLine '[main]') -eq '')
        Check 'config: a setting is not a bare word' ((Get-BareConfLine 'proxy=1') -eq '')
        Check 'config: a bare word behind a comment is refused' ((Get-BareConfLine 'proxy # x = y') -eq 'proxy')
        Check 'config: a malformed section line is refused' ((Get-BareConfLine '[main] foo') -eq '[main] foo')
        Check 'config: a lone bracket is refused' ((Get-BareConfLine '[') -eq '[')
        Check 'config: a real section line is not a bare word' ((Get-BareConfLine '[main]') -eq '')
        Check 'config: walletdir= is refused' ((Get-ForbiddenConfKey 'walletdir=x') -eq 'walletdir')
        Check 'config: upgradewallet= is refused' ((Get-ForbiddenConfKey 'upgradewallet=1') -eq 'upgradewallet')
        Check 'config: settings= is refused' ((Get-ForbiddenConfKey 'settings=x') -eq 'settings')
        # A foreign RPC port is corrected to the port this package and its tools use.
        Set-Content -LiteralPath $script:ConfPath -Value @('listen=0', 'rpcport=9999', 'proxy=127.0.0.1:9050') -Encoding ASCII
        Initialize-Config -ProxyPort 9050 -Listen $false
        $trp = Get-Content -LiteralPath $script:ConfPath -Raw
        Check 'config: a foreign rpcport is corrected to the package port' ($trp -cmatch '(?m)^rpcport=29332\s*$')
        # The attach path also refuses manual clearnet peers.
        $onionAdded = '[{"addednode":"abc.onion:29333","connected":false,"addresses":[]}]'
        $onionPeers = '[{"addr":"abc.onion:29333","inbound":false}]'
        $clearAdded = '[{"addednode":"192.0.2.9:29333","connected":false,"addresses":[]}]'
        $clearPeers = '[{"addr":"192.0.2.9:29333","inbound":true}]'
        Check 'peers: onion added nodes and peers are accepted' (Test-TorOnlyPeers $onionAdded $onionPeers)
        Check 'peers: a clearnet added node is refused' (-not (Test-TorOnlyPeers $clearAdded $onionPeers))
        Check 'peers: a clearnet peer is refused' (-not (Test-TorOnlyPeers $onionAdded $clearPeers))
        Check 'peers: a loopback inbound peer is accepted' (Test-TorOnlyPeers $onionAdded '[{"addr":"127.0.0.1:51055","inbound":true}]')
        Check 'peers: an IPv6 loopback peer is accepted' (Test-TorOnlyPeers $onionAdded '[{"addr":"[::1]:51055","inbound":true}]')
        Check 'peers: a loopback added node is accepted' (Test-TorOnlyPeers '[{"addednode":"127.0.0.1:29333","connected":false,"addresses":[]}]' '[]')
        Check 'peers: empty lists are accepted' (Test-TorOnlyPeers '[]' '[]')
        Check 'peers: empty answers are refused' (-not (Test-TorOnlyPeers '' '[]'))
        Check 'peers: a null JSON answer is refused' (-not (Test-TorOnlyPeers 'null' 'null'))
        Check 'peers: an added node without an address is refused' (-not (Test-TorOnlyPeers '[{"addednode":"","connected":false,"addresses":[]}]' '[]'))
        Check 'peers: garbage is refused' (-not (Test-TorOnlyPeers 'x' 'y'))
        # The attach path only trusts a node whose real profile is Tor-only.
        $pinJson = '{"networks":[{"name":"ipv4","reachable":false,"proxy":"127.0.0.1:9050"},{"name":"ipv6","reachable":false,"proxy":"127.0.0.1:9050"},{"name":"onion","reachable":true,"proxy":"127.0.0.1:9050"},{"name":"i2p","reachable":false,"proxy":""},{"name":"cjdns","reachable":false,"proxy":""}]}'
        $clearJson = '{"networks":[{"name":"ipv4","reachable":true,"proxy":""},{"name":"ipv6","reachable":true,"proxy":""},{"name":"onion","reachable":false,"proxy":""},{"name":"i2p","reachable":false,"proxy":""},{"name":"cjdns","reachable":false,"proxy":""}]}'
        Check 'profile: a pinned Tor-only node is accepted' (Test-TorOnlyProfile $pinJson)
        Check 'profile: a clearnet node is refused' (-not (Test-TorOnlyProfile $clearJson))
        Check 'profile: a remote onion proxy is refused' (-not (Test-TorOnlyProfile ($pinJson -replace '127\.0\.0\.1:9050', '192.0.2.9:9050')))
        Check 'profile: a remote clearnet proxy is refused' (-not (Test-TorOnlyProfile ([regex]::Replace($pinJson, '127\.0\.0\.1:9050', '192.0.2.9:9050', 1))))
        Check 'profile: a non-boolean reachable value is refused' (-not (Test-TorOnlyProfile ($pinJson -replace '"reachable":true', '"reachable":"true"')))
        Check 'profile: missing network entries are refused' (-not (Test-TorOnlyProfile '{"networks":[{"name":"onion","reachable":true,"proxy":"127.0.0.1:9050"}]}'))
        Check 'profile: garbage is refused' (-not (Test-TorOnlyProfile 'not json'))
        # Seeds are a one-time migration; after that a removed seed stays removed.
        Set-Content -LiteralPath $script:ConfPath -Value @('listen=1', 'proxy=127.0.0.1:9050') -Encoding ASCII
        Initialize-Config -ProxyPort 9050 -Listen $false -MigrateSeeds $false
        $ts = Get-Content -LiteralPath $script:ConfPath -Raw
        Check 'config: seeds are not re-injected after migration' (-not ($ts -match '(?m)^addnode='))
        # Node keys are case-sensitive: a dead "Listen=1" must not turn listening on.
        Set-Content -LiteralPath $script:ConfPath -Value @('Listen=1', 'listen=0', 'proxy=127.0.0.1:9050') -Encoding ASCII
        Initialize-Config -ProxyPort 9050 -Listen $false
        $tc = Get-Content -LiteralPath $script:ConfPath -Raw
        Check 'config: a capitalized Listen= is ignored' (($tc -cmatch '(?m)^Listen=1\s*$') -and ($tc -cmatch '(?m)^listen=0\s*$') -and -not ($tc -cmatch '(?m)^listen=1\s*$'))
        # A commented value is read the way the node reads it: 'listen=1 # x' is ON.
        Set-Content -LiteralPath $script:ConfPath -Value @('listen=1 # keep', 'proxy=127.0.0.1:9050') -Encoding ASCII
        Initialize-Config -ProxyPort 9050 -Listen $false
        $tc = Get-Content -LiteralPath $script:ConfPath -Raw
        Check 'config: a commented listen value is read like the node reads it' (($tc -cmatch '(?m)^listen=1\s*$') -and -not ($tc -cmatch '(?m)^listen=0\s*$'))
        # Open RPC is corrected.
        Set-Content -LiteralPath $script:ConfPath -Value @('rpcbind=0.0.0.0', 'rpcallowip=0.0.0.0', 'proxy=127.0.0.1:9050') -Encoding ASCII
        Initialize-Config -ProxyPort 9050 -Listen $false
        $tc = Get-Content -LiteralPath $script:ConfPath -Raw
        Check 'config: an open RPC bind is corrected' (($tc -cmatch '(?m)^rpcbind=127\.0\.0\.1\s*$') -and ($tc -cmatch '(?m)^rpcallowip=127\.0\.0\.1\s*$'))
        # A custom control port is kept; the app's own one follows the Tor port in use.
        Set-Content -LiteralPath $script:ConfPath -Value @('listen=1', 'torcontrol=192.168.1.9:9051', 'proxy=127.0.0.1:9050') -Encoding ASCII
        Initialize-Config -ProxyPort 9050 -Listen $true
        $tc = Get-Content -LiteralPath $script:ConfPath -Raw
        Check 'config: a custom torcontrol is kept' ($tc -cmatch '(?m)^torcontrol=192\.168\.1\.9:9051\s*$')
        Set-Content -LiteralPath $script:ConfPath -Value @('listen=1', 'torcontrol=127.0.0.1:9151', 'proxy=127.0.0.1:9050') -Encoding ASCII
        Initialize-Config -ProxyPort 9050 -Listen $true
        $tc = Get-Content -LiteralPath $script:ConfPath -Raw
        Check 'config: the canonical torcontrol follows the Tor port' ($tc -cmatch '(?m)^torcontrol=127\.0\.0\.1:9051\s*$')
        # A commented standard bind must not be duplicated, and a dead "BIND=" must not hide it.
        Set-Content -LiteralPath $script:ConfPath -Value @('listen=1', 'bind=127.0.0.1:29333 # node', 'bind=127.0.0.1:29334=onion', 'proxy=127.0.0.1:9050') -Encoding ASCII
        Initialize-Config -ProxyPort 9050 -Listen $false
        $tb2 = Get-Content -LiteralPath $script:ConfPath -Raw
        Check 'config: a commented standard bind is not duplicated' (([regex]::Matches($tb2, '(?m)^bind=127\.0\.0\.1:29333')).Count -eq 1)
        Set-Content -LiteralPath $script:ConfPath -Value @('listen=1', 'BIND=127.0.0.1:29333', 'proxy=127.0.0.1:9050') -Encoding ASCII
        Initialize-Config -ProxyPort 9050 -Listen $true
        $tb3 = Get-Content -LiteralPath $script:ConfPath -Raw
        Check 'config: a dead BIND= does not hide the loopback bind' ($tb3 -cmatch '(?m)^bind=127\.0\.0\.1:29333\s*$')
        # A dotted main.listen must be seen and served on loopback, not silently left open.
        Set-Content -LiteralPath $script:ConfPath -Value @('[main]', 'main.listen=1', 'proxy=127.0.0.1:9050') -Encoding ASCII
        Initialize-Config -ProxyPort 9050 -Listen $false
        $td = Get-Content -LiteralPath $script:ConfPath -Raw
        Check 'config: a dotted listen is normalized and served on loopback' (($script:ConfigListening) -and ($td -cmatch '(?m)^bind=127\.0\.0\.1:29333\s*$') -and ($td -cmatch '(?m)^torcontrol=127\.0\.0\.1:9051\s*$') -and -not ($td -cmatch '(?m)^main\.listen'))
        # A commented shipped seed counts as the operator's choice and is not re-injected.
        Set-Content -LiteralPath $script:ConfPath -Value @('listen=1', ('# addnode=' + $script:Seeds[0]), 'proxy=127.0.0.1:9050') -Encoding ASCII
        Initialize-Config -ProxyPort 9050 -Listen $false -MigrateSeeds $true
        $ts2 = Get-Content -LiteralPath $script:ConfPath -Raw
        Check 'config: a commented shipped seed is not re-injected' (-not ($ts2 -cmatch ('(?m)^addnode=' + [regex]::Escape($script:Seeds[0]) + '\s*$')))
        # Core negation keys are normalized before detection: nolisten=0 means listen ON.
        Set-Content -LiteralPath $script:ConfPath -Value @('nolisten=0', 'proxy=127.0.0.1:9050') -Encoding ASCII
        Initialize-Config -ProxyPort 9050 -Listen $false
        $tn = Get-Content -LiteralPath $script:ConfPath -Raw
        Check 'config: a negation key is normalized (nolisten=0 means listen on)' (($tn -cmatch '(?m)^listen=1\s*$') -and -not ($tn -cmatch '(?m)^nolisten') -and ($tn -cmatch '(?m)^bind=127\.0\.0\.1:29333\s*$'))
        # A CR-only file is one line to the node but many lines here; it must be rewritten.
        $crText = 'listen=0' + "`r" + 'proxy=127.0.0.1:9050' + "`r"
        [System.IO.File]::WriteAllText($script:ConfPath, $crText, (New-Object System.Text.UTF8Encoding($false)))
        Initialize-Config -ProxyPort 9050 -Listen $false
        $tcr = Get-Content -LiteralPath $script:ConfPath -Raw
        Check 'config: a CR-only file is rewritten with normal line endings' ($tcr -match "`n")
    } finally {
        $script:DataDir = $savedData
        $script:LogDir = $savedLogDir
        $script:LogFile = $savedLogFile
        $script:ConfPath = $savedConf
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($script:SelfTestFail -gt 0) {
        Write-Host "Self-test FAILED ($script:SelfTestFail check(s))."
        exit 1
    }
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
    # Verify the package before this path runs cachecoin-cli.exe from it.
    Test-PackageHashes
    # The window (CacheCoin.exe) owns the node while it runs: stopping it from here would fight it.
    $guiRunning = $false
    try { $guiMutex = [System.Threading.Mutex]::OpenExisting('Local\CacheCoinGui'); $guiMutex.Dispose(); $guiRunning = $true } catch { }
    if ($guiRunning) {
        Write-Host 'The CacheCoin window (CacheCoin.exe) is running and manages the node.'
        Write-Host 'Close the window instead: right-click its tray icon, then Quit CacheCoin.'
        if (-not $Silent) {
            try {
                Add-Type -AssemblyName System.Windows.Forms | Out-Null
                [System.Windows.Forms.MessageBox]::Show("The CacheCoin window (CacheCoin.exe) is running and manages the node.`n`nClose the window instead: right-click its tray icon, then Quit CacheCoin.", 'CacheCoin') | Out-Null
            } catch { }
        }
        exit 2
    }
    $stopCli = Join-Path $script:Root 'bin\cachecoin-cli.exe'
    if (-not (Test-Path -LiteralPath $stopCli)) {
        Write-Host 'cachecoin-cli.exe not found; nothing to stop.'
        exit 1
    }
    $stopMarker = Join-Path $script:LogDir 'stop-requested'
    try {
        if (-not (Test-Path -LiteralPath $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
        Set-Content -LiteralPath $stopMarker -Value ("{0} pid={1}" -f [DateTime]::UtcNow.ToString('o'), $PID) -Encoding ASCII
    } catch { }
    $stopDeadline = (Get-Date).AddSeconds(45)
    $stopped = $false
    while ((Get-Date) -lt $stopDeadline) {
        if (Invoke-StopCli -CliPath $stopCli) { $stopped = $true; break }
        Start-Sleep -Seconds 3
    }
    if ($stopped) {
        Write-Host 'Stop requested. The node is shutting down; its launcher exits when it stops.'
        exit 0
    }
    Remove-Item -LiteralPath $stopMarker -Force -ErrorAction SilentlyContinue
    Write-Host 'The node did not answer a stop request (it may still be starting). Wait a minute and try again.'
    exit 3
}

# Fail closed BEFORE touching another controller: a package that does not match version.json must never
# close a running window or stop a node.
Test-PackageHashes

$mutex = New-Object System.Threading.Mutex($false, 'Local\CacheCoinLauncher')
$owns = $false
try { $owns = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owns = $true }
if (-not $owns) {
    # Another controller is running: the window (CacheCoin.exe) or another launcher. CacheCoin allows
    # one controller at a time on one wallet, so offer a clean takeover: close the old one, then
    # continue here; a node that survives the old controller is joined by Start-Node below.
    $guiRunning = $false
    try { $guiMutex = [System.Threading.Mutex]::OpenExisting('Local\CacheCoinGui'); $guiMutex.Dispose(); $guiRunning = $true } catch { }
    $what = if ($guiRunning) { 'The CacheCoin window (CacheCoin.exe)' } else { 'Another CacheCoin launcher' }
    if ($Silent) {
        Write-Log "$what is already running; not taking over in silent mode (autostart)." 'WARN'
        exit 0
    }
    Write-Host ''
    Write-Host "$what is already running and controls the node and wallet."
    Write-Host 'CacheCoin allows one controller at a time on this wallet, so the old one is closed first.'
    $answer = if ($Takeover) { 'Y' } else { Read-Host 'Close it and continue here? (Y/n)' }
    if ($answer -match '^[Nn]') { Write-Host 'Exiting; nothing was changed.'; exit 0 }
    Write-Log "Taking over from: $what"
    if ($guiRunning) {
        Write-Host 'Closing the CacheCoin window...'
        try { Get-Process -Name 'CacheCoin' -ErrorAction SilentlyContinue | ForEach-Object { $null = $_.CloseMainWindow() } } catch { }
        $deadline = (Get-Date).AddSeconds(25)
        while ((Get-Date) -lt $deadline) {
            $alive = $false
            try { $m1 = [System.Threading.Mutex]::OpenExisting('Local\CacheCoinGui'); $m1.Dispose(); $alive = $true } catch { }
            if (-not $alive) { break }
            Start-Sleep -Milliseconds 500
        }
        $alive = $false
        try { $m2 = [System.Threading.Mutex]::OpenExisting('Local\CacheCoinGui'); $m2.Dispose(); $alive = $true } catch { }
        if ($alive) {
            Write-Host 'The window did not close by itself; ending it.'
            try { Stop-Process -Name 'CacheCoin' -Force -ErrorAction SilentlyContinue } catch { }
            Start-Sleep -Seconds 3
        }
    } else {
        # Ask the other launcher to stop the way its own -Stop does; it exits when the node stops.
        $stopCli = Join-Path $script:Root 'bin\cachecoin-cli.exe'
        if (Test-Path -LiteralPath $stopCli) {
            $stopMarker = Join-Path $script:LogDir 'stop-requested'
            try {
                if (-not (Test-Path -LiteralPath $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
                Set-Content -LiteralPath $stopMarker -Value ("{0} pid={1}" -f [DateTime]::UtcNow.ToString('o'), $PID) -Encoding ASCII
            } catch { }
            for ($i = 0; $i -lt 30; $i++) {
                if (-not (Test-Path -LiteralPath $stopMarker)) { break }
                if (Invoke-StopCli -CliPath $stopCli) { break }
                Start-Sleep -Seconds 1
            }
        }
    }
    $free = $false
    for ($i = 0; $i -lt 90; $i++) {
        $acquired = $false
        try { $acquired = $mutex.WaitOne(500) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if ($acquired) { $free = $true; break }
    }
    if (-not $free) {
        Write-Host 'The other controller did not release the lock. Close it, or stop it with -Stop, then try again.'
        exit 1
    }
    Write-Host 'Continuing here.'
}

$lockPath = Join-Path $script:DataDir 'launcher.lock'
try {
    if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
    $script:LockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
} catch {
    $guiRunning = $false
    try { $guiMutex2 = [System.Threading.Mutex]::OpenExisting('Local\CacheCoinGui'); $guiMutex2.Dispose(); $guiRunning = $true } catch { }
    if ($guiRunning) {
        Write-Host 'The CacheCoin window (CacheCoin.exe) is already running and controls the node and mining.'
        Write-Host 'Use the window''s Mining page, or close the window first (right-click its tray icon, then Quit CacheCoin).'
    } else {
        Write-Host 'CacheCoin is already running in another session on this computer. To stop it, run this from the package folder:'
        Write-Host 'powershell -NoProfile -ExecutionPolicy Bypass -File launcher\CacheCoin.ps1 -Stop'
    }
    if (-not $Silent) {
        try {
            Add-Type -AssemblyName System.Windows.Forms | Out-Null
            $msg = if ($guiRunning) { "The CacheCoin window (CacheCoin.exe) is already running and controls the node and mining.`n`nUse the window's Mining page, or close the window first." } else { "CacheCoin is already running in another session.`n`nTo stop it, run this from the package folder:`n`npowershell -NoProfile -ExecutionPolicy Bypass -File launcher\CacheCoin.ps1 -Stop" }
            [System.Windows.Forms.MessageBox]::Show($msg, 'CacheCoin') | Out-Null
        } catch { }
    }
    try { $mutex.ReleaseMutex() } catch { }
    exit 0
}

try {
    Write-Log 'CacheCoin launcher starting.'
    if ($Silent) {
        Write-Log "Program folder: $($script:Root); data folder: $($script:DataDir)"
    } else {
        Write-Host ''
        Write-Host "Program folder: $($script:Root)"
        Write-Host "Data folder:    $($script:DataDir)"
        Write-Host ''
    }
    Remove-Item -LiteralPath (Join-Path $script:LogDir 'stop-requested') -Force -ErrorAction SilentlyContinue
    Test-Preflight
    Stop-StaleMiningProcesses

    $state = Read-State
    $script:SeedsVersion = 0
    if ($state -and $state.seedsVersion) {
        $sv = 0
        if ([int]::TryParse([string]$state.seedsVersion, [ref]$sv)) { $script:SeedsVersion = $sv }
    }
    if (-not $Silent) {
        try {
            $task = Get-ScheduledTask -TaskName 'CacheCoin Node' -ErrorAction SilentlyContinue
            $wantPs1 = (Join-Path $script:Root 'launcher\CacheCoin.ps1')
            if ($task -and ($task.Actions[0].Execute -ne 'powershell.exe' -or ([string]$task.Actions[0].Arguments).IndexOf($wantPs1, [System.StringComparison]::OrdinalIgnoreCase) -lt 0)) {
                Write-Log 'The autostart task points at a different CacheCoin folder or an older command; re-registering it for this folder.' 'WARN'
                Enable-Autostart
            }
        } catch { }
    }
    $chosen = $Mode
    if (-not $chosen -and $state -and $state.mode) { $chosen = [string]$state.mode }
    if ($chosen -ne 'mining' -and $chosen -ne 'node') { $chosen = '' }
    if (-not $chosen) {
        $noPrompt = $Silent
        if (-not $noPrompt) { try { $noPrompt = [Console]::IsInputRedirected } catch { $noPrompt = $true } }
        if ($noPrompt) {
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
    if ($chosen -eq 'mining') {
        # Mining is a package: node + peer + miner. The node accepts incoming Tor
        # connections so the network does not depend on one seed server.
        $listen = $true
    } elseif (-not $Silent -and -not $state) {
        $a = Read-Host 'Help other nodes connect by accepting incoming Tor connections? (y/N)'
        if ($a -match '^[Yy]') { $listen = $true }
    }
    Initialize-Config -ProxyPort $proxy -Listen $listen -MigrateSeeds ($script:SeedsVersion -lt 2)
    if ($script:ConfigListening) {
        Write-Log 'Incoming Tor connections are enabled: this node also serves other nodes.'
        if (-not $Silent) {
            Write-Host 'This computer also helps other nodes connect (it accepts incoming Tor connections).'
            if (-not $script:StartedTor) {
                Write-Host 'Note: if this Tor has no control port, others cannot reach you; mining still works.'
            }
        }
    }

    $stopMarkerNow = Join-Path $script:LogDir 'stop-requested'
    Start-Node
    $ready = Wait-Rpc -Seconds 180 -StopMarker $stopMarkerNow
    if (-not $ready -and $script:NodeProcess -and -not $script:NodeProcess.HasExited) {
        # A healthy node can spend a long time loading (large chainstate, slow disk). Do not kill it:
        # keep waiting while the process is alive, no stop was asked for, and 30 minutes have not passed.
        $loadingUntil = (Get-Date).AddMinutes(30)
        $loadingWarned = $false
        while (-not $ready -and -not $script:StopRequested -and -not $script:NodeProcess.HasExited -and -not (Test-Path -LiteralPath $stopMarkerNow) -and (Get-Date) -lt $loadingUntil) {
            if (-not $loadingWarned) {
                Write-Log 'The node is still loading; waiting up to 30 minutes instead of stopping it.' 'WARN'
                $loadingWarned = $true
            }
            Start-Sleep -Seconds 15
            if ($script:StopRequested -or $script:NodeProcess.HasExited) { break }
            $ready = [bool](Invoke-Rpc @('getblockchaininfo'))
        }
    }
    if (-not $ready) {
        $startExit = $null
        try { if ($script:NodeProcess) { $startExit = $script:NodeProcess.ExitCode } } catch { }
        if ($startExit -eq 0 -or (Test-Path -LiteralPath $stopMarkerNow)) {
            Remove-Item -LiteralPath $stopMarkerNow -Force -ErrorAction SilentlyContinue
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
        Fail "The node did not answer, even after the extra loading wait.$hint See the log: $($script:LogFile)"
    }
    Write-Log 'The node is running.'
    # A node we merely attached to was not started with the pins above; verify its real profile
    # instead of trusting the conf file, which a running process never re-reads.
    if ($script:AttachedToExisting) {
        $attestMsg = 'A CacheCoin node is already running, but it is not set to Tor-only (non-onion peers, a public listener, or it can reach the open internet). Stop it first (powershell -NoProfile -ExecutionPolicy Bypass -File launcher\CacheCoin.ps1 -Stop), then start again.'
        if (-not (Test-TorOnlyProfile (Invoke-Rpc @('getnetworkinfo')))) { Fail $attestMsg }
        if (-not (Test-TorOnlyPeers (Invoke-Rpc @('getaddednodeinfo')) (Invoke-Rpc @('getpeerinfo')))) { Fail $attestMsg }
        if (-not (Test-TorOnlyListeners)) { Fail $attestMsg }
    }
    if ($script:ConfigListening) {
        $onionOk = $false
        for ($i = 0; $i -lt 15 -and -not $script:StopRequested; $i++) {
            if (Test-OnionAdvertised) { $onionOk = $true; break }
            Start-Sleep -Seconds 2
        }
        if ($onionOk) {
            Write-Log 'Incoming Tor connections are active: this node advertises its own onion address.'
        } else {
            Write-Log 'Incoming connections were requested but no onion address appeared; other nodes may not reach this one. Mining still works.' 'WARN'
            if (-not $Silent) { Write-Host 'Note: this node has not published its onion address; others may not be able to connect to it.' }
        }
    }

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
    if ($chosen -eq 'mining') {
        # 1. Threads: the hardware is read, and a request above the core count falls back to cores-1.
        $cores = [Environment]::ProcessorCount
        if ($Silent) {
            $req = 0
            if ($state -and $state.threads) {
                $sv = 0
                if ([int]::TryParse([string]$state.threads, [ref]$sv)) { $req = $sv }
            }
            $script:Threads = Resolve-MiningThreads -Requested $req -Cores $cores
        } else {
            $script:Threads = Read-MiningThreads
        }
        Write-Host "Mining will use $($script:Threads) processor(s)."
        Write-Log "Mining processors: $($script:Threads)."
        if ($script:Threads -gt 16) {
            Write-Host "Warning: $($script:Threads) workers is a lot; the computer may become slow or hot."
            Write-Log "High worker count: $($script:Threads)." 'WARN'
        }

        # 2. Address: a wallet made with Create New Wallet (Wallet folder), or a pasted segwit address.
        $walletDir = Join-Path $script:Root 'Wallet'
        $walletAddr = ''
        $walletFile = ''
        if (Test-Path -LiteralPath $walletDir) {
            $files = @(Get-ChildItem -LiteralPath $walletDir -Filter 'cachecoin-wallet-*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 20)
            foreach ($file in $files) {
                $line = $null
                try { $line = (Get-Content -LiteralPath $file.FullName -TotalCount 200 -ErrorAction SilentlyContinue | Where-Object { $_ -match '^Modern segwit address' } | Select-Object -First 1) } catch { }
                if ($line) {
                    $cand = $line.Substring($line.IndexOf(':') + 1).Trim()
                    $ok = Get-ValidMainnetAddress -Address $cand
                    if ($ok) { $walletAddr = $ok; $walletFile = $file.Name; break }
                }
            }
        }
        if ($Silent) {
            # Autostart mines only to the address that was already chosen and saved.
            $savedAddr = ''
            if ($state -and $state.miningAddress) { $savedAddr = Get-ValidMainnetAddress -Address ([string]$state.miningAddress) }
            if ($savedAddr) {
                $script:Address = $savedAddr
            } elseif ($state -and $state.miningAddress -and -not (Invoke-Rpc @('getblockcount'))) {
                $script:Address = [string]$state.miningAddress
                Write-Log 'The node is not answering, so the saved mining address could not be checked; using the saved address.' 'WARN'
            } else {
                $script:Address = ''
                Write-Log 'No valid mining address is saved; mining is not started in silent mode.' 'WARN'
            }
        } else {
            $script:Address = ''
            Write-Host ''
            Write-Host 'Where should the mined coins go?'
            Write-Host '  1) Use a wallet from the Wallet folder (made with Create New Wallet.cmd)'
            Write-Host '  2) Use your own public address (modern segwit, starts with cccn1)'
            for ($i = 0; $i -lt 5 -and -not $script:Address; $i++) {
                $pick = ("$(Read-Host 'Type 1 or 2')").Trim()
                if ($pick -eq '1') {
                    if ($walletAddr) {
                        Write-Host "Wallet file: $walletFile"
                        Write-Host "All mined coins will go to: $walletAddr"
                        $yn = Read-Host 'Type Y to use this address, or N to choose again'
                        if ($yn -notmatch '^[Yy]') { continue }
                        $script:Address = $walletAddr
                    } else {
                        Write-Host 'No usable wallet was found in the Wallet folder.'
                        Write-Host 'Run Create New Wallet.cmd first (option 1 saves it there), or type 2 to paste an address.'
                    }
                } elseif ($pick -eq '2') {
                    $a = "$(Read-Host 'Paste your modern segwit address (cccn1...)')"
                    $ok = Get-ValidMainnetAddress -Address $a
                    if (-not $ok) {
                        if (-not (Invoke-Rpc @('getblockcount'))) {
                            Write-Host 'The node is not answering right now, so the address cannot be checked. Wait a moment and try again.'
                        } else {
                            Write-Host "That is not a valid CacheCoin mainnet address: $(([string]$a).Trim())"
                            Write-Host 'It must start with cccn1. Check every character and try again.'
                        }
                        continue
                    }
                    Write-Host "All mined coins will go to: $ok"
                    Write-Host 'A wrong address cannot be undone. If this is an exchange address, they must credit you.'
                    $yn = Read-Host 'Press Enter (or Y) to start mining to this address, or type N to choose again'
                    if ($yn -match '^[Nn]') { continue }
                    $script:Address = $ok
                } else {
                    Write-Host 'Type 1 or 2.'
                }
            }
            if (-not $script:Address) { Write-Host 'No address was chosen; mining was not started.' }
        }
        if ($script:Address) {
            Write-Log "Mining address: $($script:Address)"
            Start-Mining
        }
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
        Write-Host "Program folder: $($script:Root)"
        Write-Host "Data folder:    $($script:DataDir)"
        Write-Host "Log file:       $($script:LogFile)"
        if ($script:Address) {
            Write-Host "Mining to: $($script:Address)"
        }
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
            # An attached node can change after the first check (a manual peer, a new listener):
            # re-attest once a minute and stop using it after three failed checks in a row.
            if ($script:AttachedToExisting -and ((Get-Date) - $script:LastAttest).TotalSeconds -ge 60) {
                $script:LastAttest = Get-Date
                $attestOk = (Test-TorOnlyProfile (Invoke-Rpc @('getnetworkinfo'))) -and (Test-TorOnlyPeers (Invoke-Rpc @('getaddednodeinfo')) (Invoke-Rpc @('getpeerinfo'))) -and (Test-TorOnlyListeners)
                if ($attestOk) {
                    $script:AttestFails = 0
                } else {
                    $script:AttestFails++
                    Write-Log "The attached node no longer looks Tor-only (check $($script:AttestFails) of 3)." 'WARN'
                    if ($script:AttestFails -ge 3) {
                        Fail 'The running CacheCoin node is no longer Tor-only (non-onion peers, a public listener, or open internet). Stop it and start again.'
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
            $stopMarker = Join-Path $script:LogDir 'stop-requested'
            $stopWasRequested = $false
            if (Test-Path -LiteralPath $stopMarker) {
                # A stop request counts while it is fresh; an old marker from a killed -Stop is stale.
                $fresh = $false
                try { $fresh = ((Get-Date) - (Get-Item -LiteralPath $stopMarker -ErrorAction Stop).LastWriteTime).TotalMinutes -lt 10 } catch { }
                if ($fresh) {
                    $stopWasRequested = $true
                } else {
                    Write-Log 'A stale stop marker was removed; treating this as a crash.' 'WARN'
                }
                Remove-Item -LiteralPath $stopMarker -Force -ErrorAction SilentlyContinue
            }
            if ($stopWasRequested) {
                Write-Log 'The node stopped (a stop was requested); the launcher is exiting.'
                $script:StopRequested = $true
            } elseif ($nodeExit -eq 0) {
                Write-Log 'The node stopped cleanly; the launcher is exiting.'
                $script:StopRequested = $true
            } else {
                if ($null -eq $nodeExit) {
                    $tail = ''
                    try { $tail = ((Get-Content -LiteralPath $script:NodeErrLog -Tail 2 -ErrorAction SilentlyContinue) -join ' ') } catch { }
                    Write-Log "The node exited with an unknown code; treating it as a crash. $tail" 'WARN'
                }
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
                        Write-Log "The node is back; mining continues to $($script:Address)."
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
    try { Remove-Item -LiteralPath (Join-Path $script:LogDir 'stop-requested') -Force -ErrorAction SilentlyContinue } catch { }
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
