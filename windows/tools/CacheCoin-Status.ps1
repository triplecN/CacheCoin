[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $PSScriptRoot
$script:DataDir = Join-Path $env:APPDATA 'CacheCoin'
$script:Cli = Join-Path $script:Root 'bin\cachecoin-cli.exe'

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

$r = Invoke-Cli @('getblockcount')
if ($r.Code -ne 0) {
    Write-Host 'The CacheCoin node is not running.'
    Write-Host 'Start it first with "Start Node.cmd" (or "Start Mining.cmd").'
    Pause-Exit
    exit 1
}

$chain = Invoke-Cli @('getblockchaininfo')
$peers = Invoke-Cli @('getconnectioncount')
if ($chain.Code -eq 0) {
    try {
        $c = $chain.Out | ConvertFrom-Json
        Write-Host ('Block:      {0} of {1}' -f $c.blocks, $c.headers)
        if ($c.initialblockdownload) {
            Write-Host ('Syncing:    {0:N1}%' -f (100.0 * $c.verificationprogress))
        } else {
            Write-Host 'Syncing:    up to date'
        }
    } catch {
        Write-Host "Block:      $($chain.Out)"
    }
} else {
    Write-Host "Block:      $($r.Out)"
}
if ($peers.Code -eq 0) { Write-Host "Peers:      $($peers.Out)" }

$wallets = Invoke-Cli @('listwallets')
if ($wallets.Code -eq 0 -and $wallets.Out -match '"main"') {
    $bal = Invoke-Cli @('-rpcwallet=main', 'getbalances')
    if ($bal.Code -eq 0) {
        try {
            $b = $bal.Out | ConvertFrom-Json
            Write-Host ('Balance:    {0} CCCN trusted, {1} CCCN immature' -f $b.mine.trusted, $b.mine.immature)
        } catch {
            Write-Host "Balance:    $($bal.Out)"
        }
    }
    $found = Invoke-Cli @('-rpcwallet=main', 'getwalletinfo')
    if ($found.Code -eq 0) {
        try {
            $w = $found.Out | ConvertFrom-Json
            Write-Host ('Wallet:     main, {0} addresses' -f $w.keypoolsize)
        } catch { }
    }
} else {
    Write-Host 'Balance:    wallet not loaded (node-only run).'
    Write-Host '            Use "Start Mining.cmd" once to load the wallet and see the balance.'
}

Write-Host ''
Write-Host "Data folder: $($script:DataDir)"
Write-Host "Log file:    $(Join-Path $script:DataDir 'logs\launcher.log')"
Write-Host ''
Pause-Exit
