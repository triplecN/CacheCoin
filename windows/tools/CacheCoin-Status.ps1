[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $PSScriptRoot
$script:DataDir = Join-Path $env:APPDATA 'CacheCoin'
$script:Cli = Join-Path $script:Root 'bin\cachecoin-cli.exe'
$script:RpcTimeout = 10
$script:MinedPage = 5000
$script:MinedCap = 50000

. (Join-Path $PSScriptRoot 'CacheCoin-Package.ps1')

function Pause-Exit {
    Read-Host 'Press Enter to close this window' | Out-Null
}

function Invoke-Cli {
    param([string[]]$Arguments)
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & $script:Cli "-datadir=$($script:DataDir)" "-rpcclienttimeout=$($script:RpcTimeout)" '-chain=main' @Arguments 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $oldEap
    return [pscustomobject]@{ Code = $code; Out = (((@($out) | Where-Object { $_ -is [string] }) | Out-String).Trim()) }
}

function Invoke-CliJson {
    param([string[]]$Arguments)
    $r = Invoke-Cli -Arguments $Arguments
    if ($r.Code -ne 0) { return [pscustomobject]@{ Ok = $false; Data = $null } }
    try { return [pscustomobject]@{ Ok = $true; Data = ($r.Out | ConvertFrom-Json) } }
    catch { return [pscustomobject]@{ Ok = $false; Data = $null } }
}

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1073741824) { return ('{0:N2} GB' -f ($Bytes / 1073741824)) }
    if ($Bytes -ge 1048576) { return ('{0:N2} MB' -f ($Bytes / 1048576)) }
    if ($Bytes -ge 1024) { return ('{0:N1} KB' -f ($Bytes / 1024)) }
    return ('{0:N0} bytes' -f $Bytes)
}

function Write-Row {
    param([string]$Label, [string]$Value)
    Write-Host ('{0,-23}{1}' -f ($Label + ':'), $Value)
}

function Get-MinedBlockCount {
    param([string]$WalletName)
    $mined = 0
    $skip = 0
    while ($skip -lt $script:MinedCap) {
        $take = [Math]::Min($script:MinedPage, $script:MinedCap - $skip)
        $page = Invoke-CliJson -Arguments @("-rpcwallet=$WalletName", 'listtransactions', '*', [string]$take, [string]$skip, 'true')
        if (-not $page.Ok) { return $null }
        $items = if ($null -eq $page.Data) { @() } else { @($page.Data) }
        foreach ($tx in $items) {
            $category = [string]$tx.category
            if ($category -eq 'generate' -or $category -eq 'immature') { $mined++ }
        }
        if ($items.Count -lt $take) { return [pscustomobject]@{ Count = $mined; Capped = $false } }
        $skip += $items.Count
    }
    return [pscustomobject]@{ Count = $mined; Capped = $true }
}

Write-Host ''
Write-Host 'CacheCoin status'
Write-Host '================'
Write-Host ''

if (-not (Test-Path -LiteralPath $script:Cli)) {
    Write-Host 'cachecoin-cli.exe was not found next to this script.'
    Write-Host 'Unpack the whole ZIP first, then run this file from the package folder.'
    Pause-Exit
    exit 1
}
if (-not (Test-PackageIntegrity -Root $script:Root)) {
    Write-Host 'This package does not match its version.json file; not running.'
    Write-Host 'Download it again and verify it with docs\VERIFY.txt.'
    Pause-Exit
    exit 1
}

$probe = Invoke-Cli @('getblockcount')
if ($probe.Code -ne 0) {
    Write-Host 'The CacheCoin node is not running.'
    Write-Host 'Start it first with "Start Node.cmd" (or "Start Mining.cmd").'
    Pause-Exit
    exit 1
}

$chainResult = Invoke-CliJson @('getblockchaininfo')
if (-not $chainResult.Ok) {
    Write-Host 'The node answered getblockcount but not getblockchaininfo; try again in a moment.'
    Pause-Exit
    exit 1
}
$chain = $chainResult.Data

$conn = Invoke-Cli @('getconnectioncount')
$peers = if ($conn.Code -eq 0) { $conn.Out } else { 'unknown' }

$difficulty = $null
$mempool = $null
$miningResult = Invoke-CliJson @('getmininginfo')
if ($miningResult.Ok -and $null -ne $miningResult.Data) {
    if ($null -ne $miningResult.Data.difficulty) { $difficulty = [double]$miningResult.Data.difficulty }
    if ($null -ne $miningResult.Data.pooledtx) { $mempool = [int]$miningResult.Data.pooledtx }
}
if ($null -eq $difficulty -and $null -ne $chain.difficulty) { $difficulty = [double]$chain.difficulty }
if ($null -eq $mempool) {
    $mpResult = Invoke-CliJson @('getmempoolinfo')
    if ($mpResult.Ok -and $null -ne $mpResult.Data -and $null -ne $mpResult.Data.size) { $mempool = [int]$mpResult.Data.size }
}

$progress = [double]$chain.verificationprogress
$syncText = if ($chain.initialblockdownload -or $progress -lt 0.999995) { '{0:N2}% (syncing)' -f (100.0 * $progress) } else { '100.00% (up to date)' }
$difficultyText = if ($null -eq $difficulty) { 'unknown' } elseif ([Math]::Abs($difficulty) -ge 1) { '{0:N4}' -f $difficulty } else { '{0:N12}' -f $difficulty }
$mempoolText = if ($null -eq $mempool) { 'unknown' } else { '{0} transaction(s)' -f $mempool }

Write-Row 'Chain' ([string]$chain.chain)
Write-Row 'Blocks' ([string]$chain.blocks)
Write-Row 'Headers' ([string]$chain.headers)
Write-Row 'Sync' $syncText
Write-Row 'Peers' $peers
Write-Row 'Difficulty' $difficultyText
Write-Row 'Mempool' $mempoolText
Write-Row 'Disk' (Format-Bytes ([double]$chain.size_on_disk))

$walletsResult = Invoke-CliJson @('listwallets')
$walletLoaded = $false
if ($walletsResult.Ok -and $null -ne $walletsResult.Data) {
    $walletLoaded = @($walletsResult.Data) -contains 'main'
}

if ($walletLoaded) {
    $balResult = Invoke-CliJson @('-rpcwallet=main', 'getbalances')
    Write-Row 'Wallet' 'main (loaded)'
    if ($balResult.Ok -and $null -ne $balResult.Data -and $null -ne $balResult.Data.mine) {
        Write-Row 'Balance' ('{0:N8} CCCN trusted, {1:N8} CCCN immature' -f ([double]$balResult.Data.mine.trusted), ([double]$balResult.Data.mine.immature))
    } else {
        Write-Row 'Balance' 'unavailable'
    }
    $mined = Get-MinedBlockCount -WalletName 'main'
    if ($null -eq $mined) {
        Write-Row 'Mined by this wallet' 'unknown (no answer from listtransactions)'
    } elseif ($mined.Capped) {
        Write-Row 'Mined by this wallet' ('{0:N0}+ block(s) (capped at {1:N0})' -f $mined.Count, $script:MinedCap)
    } else {
        Write-Row 'Mined by this wallet' ('{0:N0} block(s)' -f $mined.Count)
    }
} else {
    Write-Row 'Wallet' 'not loaded (node-only run)'
    Write-Row 'Mined by this wallet' 'n/a (wallet not loaded)'
}

Write-Host ''
Write-Host "Data folder: $($script:DataDir)"
Write-Host "Log file:    $(Join-Path $script:DataDir 'logs\launcher.log')"
Write-Host ''
Pause-Exit
