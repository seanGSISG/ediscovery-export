#Requires -Version 7.0
<#
.SYNOPSIS
    Poll a fired eDiscovery export until its package downloads.

.DESCRIPTION
    Wraps Invoke-EDiscoveryExport.ps1 -Resume on an interval. Exports take 30 minutes to
    hours, so the fire step returns immediately and the download has to be collected
    later. This script is the unattended collector.

    Run it in the background (or as a scheduled task) after firing an export. It exits 0
    as soon as the package lands, so an agent or a job runner is notified on completion
    rather than having to poll the poller.

    Stop condition is the on-disk result, not the API status: either export-state.done.json
    exists in the output directory, or a package archive has been written there. That way
    an export completed by some other means (portal download, a parallel -Resume) also
    ends the watch.

.PARAMETER ConfigFile
    The same config passed to -Force when the export was fired.

.PARAMETER IntervalSeconds
    Seconds between polls. Default 900 (15 minutes). Purview updates export status slowly;
    polling faster mostly buys throttling.

.PARAMETER MaxPolls
    Give up after this many polls. Default 32 (~8 hours at the default interval).

.PARAMETER EnginePath
    Override the path to Invoke-EDiscoveryExport.ps1. Defaults to the copy alongside this
    script.

.EXAMPLE
    pwsh -File scripts/Watch-EDiscoveryExport.ps1 -ConfigFile exports/matter/config.json

.EXAMPLE
    Start-Job { pwsh -File scripts/Watch-EDiscoveryExport.ps1 -ConfigFile $using:cfg }

.NOTES
    Exit codes: 0 = package landed, 1 = gave up after MaxPolls, 2 = bad input.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ConfigFile,

    [ValidateRange(60, 7200)]
    [int]$IntervalSeconds = 900,

    [ValidateRange(1, 500)]
    [int]$MaxPolls = 32,

    [string]$EnginePath
)

$ErrorActionPreference = 'Stop'

if (-not $EnginePath) {
    $EnginePath = Join-Path $PSScriptRoot 'Invoke-EDiscoveryExport.ps1'
}
# $ErrorActionPreference is Stop, so a bare Write-Error would throw and exit 1 before
# reaching the documented exit 2. Report input faults non-terminating, then exit ourselves.
function Exit-BadInput {
    param([string]$Message)
    Write-Error $Message -ErrorAction Continue
    exit 2
}

if (-not (Test-Path $EnginePath)) { Exit-BadInput "Engine not found: $EnginePath" }
if (-not (Test-Path $ConfigFile)) { Exit-BadInput "Config not found: $ConfigFile" }

# output.dir is where the engine writes state and packages; resolve it relative to the
# config so a relative dir in the config behaves the same here as it does in the engine.
try {
    $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    $outDir = $cfg.output.dir
} catch {
    Exit-BadInput "Could not read output.dir from ${ConfigFile}: $_"
}
if (-not $outDir) {
    Exit-BadInput "Config has no output.dir: $ConfigFile"
}
if (-not [System.IO.Path]::IsPathRooted($outDir)) {
    $outDir = Join-Path (Split-Path -Parent (Resolve-Path $ConfigFile)) $outDir
}

function Test-PackageLanded {
    param([string]$Dir)
    if (-not (Test-Path $Dir)) { return $false }
    if (Test-Path (Join-Path $Dir 'export-state.done.json')) { return $true }
    return [bool](Get-ChildItem -Path $Dir -File -Include '*.zip', '*.pst' -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1)
}

Write-Host "Watching export for $ConfigFile"
Write-Host "  Output:   $outDir"
Write-Host "  Interval: ${IntervalSeconds}s   Max polls: $MaxPolls"

if (Test-PackageLanded -Dir $outDir) {
    Write-Host "Package already present - nothing to watch."
    exit 0
}

for ($i = 1; $i -le $MaxPolls; $i++) {
    Write-Host ""
    Write-Host "=== poll $i/$MaxPolls  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="

    # A transient failure (token blip, throttle, network) must not end the watch - the
    # export is still running server-side and the next poll will pick it up.
    try {
        & pwsh -NoProfile -File $EnginePath -ConfigFile $ConfigFile -Resume 2>&1 |
            Select-Object -Last 20
    } catch {
        Write-Warning "Poll $i failed (continuing): $_"
    }

    if (Test-PackageLanded -Dir $outDir) {
        Write-Host ""
        Write-Host "=== PACKAGE LANDED after $i poll(s) ==="
        Get-ChildItem -Path $outDir -File |
            Select-Object Name, @{ n = 'MB'; e = { [math]::Round($_.Length / 1MB, 2) } }, LastWriteTime |
            Format-Table -AutoSize |
            Out-String |
            Write-Host
        exit 0
    }

    if ($i -lt $MaxPolls) { Start-Sleep -Seconds $IntervalSeconds }
}

Write-Warning "Gave up after $MaxPolls polls. The export may still be running - check the portal, or re-run this watcher."
exit 1
