#Requires -Version 7.0
<#
.SYNOPSIS
    Create a tenant profile: the inherited base that matter configs extend.

.DESCRIPTION
    A tenant profile holds the settings that are the same for every matter in one tenant -
    the app-only auth block, the standing case member, and the house export defaults - so a
    per-matter config carries only case/search/mailboxes/output, and a certificate rotation
    touches one file instead of every config ever written.

    This script writes that file and validates it before you rely on it: the certificate is
    resolved from the store, and (unless -SkipConnectionTest) an app-only token is acquired
    against the tenant so a bad thumbprint or a missing role surfaces now rather than in the
    middle of a collection.

    WHERE IT WRITES. The default is the per-user location, which needs no repo and is the
    right choice when admins do not share a folder layout:

        ~/.claude/ediscovery/tenant-profile.json

    Use -Path to write a repo-level profile instead (conventionally
    <repo>/config/ediscovery-tenant-profile.json) when a team shares one repo and wants the
    profile version-controlled alongside it.

    The profile is NOT a secret store - it holds an app id, a tenant id and a certificate
    thumbprint, not a private key or a client secret. It is still tenant-identifying, so
    keep it out of any repository you publish or share as a plugin marketplace.

.PARAMETER AppId
    Entra application (client) id of the eDiscovery automation app.

.PARAMETER TenantId
    Entra tenant id.

.PARAMETER CertThumbprint
    Thumbprint of the app's certificate, resolved from CurrentUser\My or LocalMachine\My.

.PARAMETER Members
    UPNs added as case members so the case is visible in the Purview portal. Each must
    already be in the eDiscovery Manager role group - adding a case member does not grant
    the role.

.PARAMETER Path
    Where to write. Defaults to ~/.claude/ediscovery/tenant-profile.json.

.PARAMETER Format
    Default export format for this tenant: pst (default) or msg.

.PARAMETER SkipConnectionTest
    Skip the live token acquisition. Validates the certificate but not the app's access.

.PARAMETER Force
    Overwrite an existing profile.

.EXAMPLE
    pwsh -File scripts/New-EDTenantProfile.ps1
    Prompts for each value, writes the per-user profile, and verifies it end to end.

.EXAMPLE
    pwsh -File scripts/New-EDTenantProfile.ps1 -AppId <guid> -TenantId <guid> `
      -CertThumbprint <thumb> -Members admin@contoso.com `
      -Path ./config/ediscovery-tenant-profile.json
    Writes a repo-level profile non-interactively.

.NOTES
    After writing, point matter configs at it with:  "extends": "tenant-profile"
    That sentinel is resolved through the documented search order, so the same matter config
    works on any admin's machine. See Resolve-EDTenantProfilePath in _lib/EDiscovery.psm1.
#>
[CmdletBinding()]
param(
    [string]$AppId,
    [string]$TenantId,
    [string]$CertThumbprint,
    [string[]]$Members,
    [string]$Path,
    [ValidateSet('pst', 'msg')]
    [string]$Format = 'pst',
    [switch]$SkipConnectionTest,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '_lib/EDiscovery.psm1') -Force

function Read-Required {
    param([string]$Prompt, [string]$Current)
    if ($Current) { return $Current }
    do {
        $v = (Read-Host $Prompt).Trim()
        if (-not $v) { Write-Host "  Required." -ForegroundColor Yellow }
    } while (-not $v)
    return $v
}

Write-EDStatus -Type Header -Message "Create eDiscovery tenant profile"

if (-not $Path) {
    $Path = Join-Path $HOME '.claude/ediscovery/tenant-profile.json'
    Write-Host "Writing the per-user profile (no repo required):"
} else {
    Write-Host "Writing profile to the path you gave:"
}
Write-Host "  $Path"
Write-Host ""

if ((Test-Path $Path) -and -not $Force) {
    throw "A profile already exists at $Path. Pass -Force to overwrite it, or -Path to write elsewhere."
}

$AppId          = Read-Required 'Entra application (client) id' $AppId
$TenantId       = Read-Required 'Entra tenant id'               $TenantId
$CertThumbprint = Read-Required 'Certificate thumbprint'        $CertThumbprint

if (-not $Members) {
    $raw = (Read-Host 'Case member UPN(s), comma-separated (must be eDiscovery Managers)').Trim()
    $Members = @($raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if (-not $Members) { throw "At least one case member UPN is required, or cases never appear in the portal." }

# ---- validate before writing: a profile that does not work is worse than none ----
Write-EDStatus -Type Header -Message "Validate"

$CertThumbprint = ($CertThumbprint -replace '[^0-9A-Fa-f]', '').ToUpper()

$auth = [PSCustomObject]@{
    mode = 'app-only'; appId = $AppId; tenantId = $TenantId
    certThumbprint = $CertThumbprint; certPath = $null; certPasswordEnv = $null
    downloadResourceAppId = 'b26e684c-5068-4120-a679-64a5d2c909d9'
}

$cert = Get-EDCertificate -Auth $auth
Write-EDStatus -Type Success -Message "Certificate found: $($cert.Subject) (expires $($cert.NotAfter.ToString('yyyy-MM-dd')))"
if ($cert.NotAfter -lt (Get-Date).AddDays(30)) {
    Write-EDStatus -Type Warning -Message "Certificate expires in under 30 days - rotate it before relying on this profile."
}

if ($SkipConnectionTest) {
    Write-EDStatus -Type Warning -Message "Skipping connection test (-SkipConnectionTest). The app's access is unverified."
} else {
    try {
        Connect-EDGraph -Auth $auth | Out-Null
        Write-EDStatus -Type Success -Message "Authenticated app-only against tenant $TenantId."
    } catch {
        throw @"
Could not authenticate with these values: $_

Check that the app id and tenant id are right, the certificate is the one uploaded to the
app registration, and eDiscovery.ReadWrite.All is granted with admin consent.
Setup guide: docs/authentication-setup.md
"@
    }
}

# ---- write ----
Write-EDStatus -Type Header -Message "Write"

$profile = [ordered]@{
    '$comment' = @(
        "eDiscovery TENANT PROFILE - the inherited base for every matter config in this tenant.",
        "Point a matter config at it with:  `"extends`": `"tenant-profile`"",
        "That sentinel resolves through: `$env:EDISCOVERY_TENANT_PROFILE, then",
        "config/ediscovery-tenant-profile.json in any parent directory, then",
        "~/.claude/ediscovery/tenant-profile.json - so the same matter config works on any",
        "admin's machine regardless of folder layout.",
        "",
        "Holds only what is tenant-wide: auth, the standing case member, and export defaults.",
        "Matter-specific settings (case, search, mailboxes, output) belong in the matter config.",
        "Objects deep-merge and arrays/scalars replace, so a matter can override one field.",
        "Requires the ediscovery-export engine at v1.2.0 or later.",
        "",
        "This is the single point of certificate rotation for this tenant.",
        "Not a secret store - no private key or client secret - but it is tenant-identifying,",
        "so keep it out of any repository you publish or share.",
        "",
        "Generated by scripts/New-EDTenantProfile.ps1."
    )
    members = @($Members)
    export  = [ordered]@{
        format                  = $Format
        singlePst               = $true
        criteria                = 'searchHits'
        location                = 'responsiveLocations'
        includeReport           = $true
        includePartiallyIndexed = $false
        friendlyNames           = $null
    }
    auth = [ordered]@{
        mode                  = 'app-only'
        appId                 = $AppId
        tenantId              = $TenantId
        certThumbprint        = $CertThumbprint
        certPath              = $null
        certPasswordEnv       = $null
        downloadResourceAppId = 'b26e684c-5068-4120-a679-64a5d2c909d9'
    }
}

$dir = Split-Path -Parent $Path
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$profile | ConvertTo-Json -Depth 8 | Set-Content -Path $Path -Encoding UTF8
Write-EDStatus -Type Success -Message "Wrote $Path"

# ---- prove it loads through the same path the engine uses ----
$probeDir = Join-Path ([IO.Path]::GetTempPath()) ("edprofile-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $probeDir | Out-Null
try {
    $probe = [ordered]@{
        extends   = $Path
        case      = @{ name = 'probe' }
        search    = @{ name = 'probe'; keywords = @('probe'); startDate = '2024-01-01'; endDate = '2024-01-02' }
        mailboxes = @('probe@example.com')
        output    = @{ dir = $probeDir }
    }
    $probePath = Join-Path $probeDir 'probe.json'
    $probe | ConvertTo-Json -Depth 8 | Set-Content $probePath
    $merged = Get-EDConfig -Path $probePath
    if ($merged.auth.appId -ne $AppId) { throw "Merged config did not inherit appId." }
    Write-EDStatus -Type Success -Message "Verified: a matter config extending this profile merges to a complete run config."
} finally {
    Remove-Item $probeDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-EDStatus -Type Header -Message "Next steps"
Write-Host "1. In each matter config, inherit from this profile:"
Write-Host '     "extends": "tenant-profile"' -ForegroundColor Cyan
if ($Path -ne (Join-Path $HOME '.claude/ediscovery/tenant-profile.json')) {
    Write-Host ""
    Write-Host "   You wrote to a non-default path, so either keep matter configs in this repo"
    Write-Host "   (the search walks parent directories for config/ediscovery-tenant-profile.json),"
    Write-Host "   or set the override so it is found from anywhere:"
    Write-Host "     `$env:EDISCOVERY_TENANT_PROFILE = '$Path'" -ForegroundColor Cyan
    Write-Host "   Persist it with: [Environment]::SetEnvironmentVariable('EDISCOVERY_TENANT_PROFILE','$Path','User')"
}
Write-Host ""
Write-Host "2. Copy config/ediscovery-export.example.json for the matter itself, keeping only"
Write-Host "   case / search / mailboxes / output."
Write-Host ""
Write-Host "3. Estimate before exporting:"
Write-Host "     pwsh -File scripts/Invoke-EDiscoveryExport.ps1 -ConfigFile <matter>.json -EstimateOnly" -ForegroundColor Cyan
