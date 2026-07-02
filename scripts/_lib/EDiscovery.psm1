#Requires -Version 7.0

<#
.SYNOPSIS
    Self-contained helper module for the ediscovery-export engine.

.DESCRIPTION
    Zero external dependencies beyond Microsoft.Graph.Authentication. Provides:
      - Write-EDStatus         : consistent ASCII-safe console output
      - Get-EDConfig           : load + validate the JSON run config
      - Connect-EDGraph        : app-only (cert) or interactive Graph auth
      - Get-EDDownloadToken    : mint the SEPARATE Purview eDiscovery download
                                 token via an inline cert client-assertion JWT
                                 (no MSAL.PS dependency)
      - New-EDRunManifest      : write a run manifest JSON to the output dir

.NOTES
    Deliberately ASCII-only (no smart quotes / em-dashes / arrows) so the code
    survives copy/paste across terminals and RMM tools.
#>

Set-StrictMode -Version Latest

# ============================================================================
# Console output
# ============================================================================

function Write-EDStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][ValidateSet('Info','Success','Warning','Error','Action','Header')][string]$Type
    )
    $map = @{
        Info    = @{ Prefix = '[*]'; Color = 'Yellow' }
        Success = @{ Prefix = '[+]'; Color = 'Green' }
        Warning = @{ Prefix = '[!]'; Color = 'DarkYellow' }
        Error   = @{ Prefix = '[-]'; Color = 'Red' }
        Action  = @{ Prefix = '[>]'; Color = 'Cyan' }
        Header  = @{ Prefix = '';    Color = 'Cyan' }
    }
    $c = $map[$Type]
    if ($Type -eq 'Header') {
        Write-Host ''
        Write-Host ('=' * 60) -ForegroundColor $c.Color
        Write-Host "  $Message"  -ForegroundColor $c.Color
        Write-Host ('=' * 60) -ForegroundColor $c.Color
    } else {
        Write-Host "$($c.Prefix) $Message" -ForegroundColor $c.Color
    }
}

# ============================================================================
# Configuration
# ============================================================================

function Get-EDConfig {
    <#
    .SYNOPSIS
        Load and validate a run config file. Returns a PSCustomObject.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path $Path)) { throw "Config file not found: $Path" }
    try {
        $cfg = Get-Content -Path $Path -Raw | ConvertFrom-Json
    } catch {
        throw "Config is not valid JSON ($Path): $_"
    }

    # ---- required sections ----
    foreach ($k in 'case','search','mailboxes','export','output','auth') {
        if (-not $cfg.PSObject.Properties.Name.Contains($k)) {
            throw "Config is missing required section '$k'."
        }
    }
    if (-not $cfg.case.name)   { throw "config.case.name is required." }
    if (-not $cfg.search.name) { throw "config.search.name is required." }
    if (-not $cfg.mailboxes -or @($cfg.mailboxes).Count -eq 0) {
        throw "config.mailboxes must list at least one SMTP address."
    }

    # ---- search: either contentQuery OR keywords+dates ----
    $hasQuery = [bool]$cfg.search.PSObject.Properties.Name.Contains('contentQuery') -and $cfg.search.contentQuery
    $hasKw    = [bool]$cfg.search.PSObject.Properties.Name.Contains('keywords') -and @($cfg.search.keywords).Count -gt 0
    if (-not $hasQuery -and -not $hasKw) {
        throw "config.search must provide either 'contentQuery' (raw KQL) or 'keywords' (with optional startDate/endDate)."
    }

    # ---- auth ----
    if ($cfg.auth.mode -eq 'app-only') {
        foreach ($k in 'appId','tenantId','certThumbprint') {
            if (-not $cfg.auth.$k) { throw "config.auth.$k is required for app-only mode." }
        }
    }
    if (-not $cfg.auth.PSObject.Properties.Name.Contains('downloadResourceAppId') -or -not $cfg.auth.downloadResourceAppId) {
        # Well-known first-party Purview eDiscovery download resource.
        $cfg.auth | Add-Member -NotePropertyName downloadResourceAppId -NotePropertyValue 'b26e684c-5068-4120-a679-64a5d2c909d9' -Force
    }
    return $cfg
}

# ============================================================================
# Certificate resolution
# ============================================================================

function Get-EDCertificate {
    <#
    .SYNOPSIS
        Resolve the auth certificate (with private key) from the store by
        thumbprint, or from a PFX path if provided.
    #>
    [CmdletBinding()]
    [OutputType([System.Security.Cryptography.X509Certificates.X509Certificate2])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Auth
    )
    $thumb = ($Auth.certThumbprint -replace '\s','').ToUpper()

    $pfxPath = $null
    if ($Auth.PSObject.Properties.Name.Contains('certPath')) { $pfxPath = $Auth.certPath }

    if ($pfxPath) {
        if (-not (Test-Path $pfxPath)) { throw "certPath not found: $pfxPath" }
        $pw = $null
        if ($Auth.PSObject.Properties.Name.Contains('certPasswordEnv') -and $Auth.certPasswordEnv) {
            $pw = [Environment]::GetEnvironmentVariable($Auth.certPasswordEnv)
        }
        if ($pw) {
            $sec = ConvertTo-SecureString $pw -AsPlainText -Force
            return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($pfxPath, $sec,
                [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
        }
        return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($pfxPath)
    }

    foreach ($loc in 'CurrentUser','LocalMachine') {
        $c = Get-ChildItem "Cert:\$loc\My\$thumb" -ErrorAction SilentlyContinue
        if ($c) { return $c }
    }
    throw "Certificate with thumbprint $thumb not found in CurrentUser or LocalMachine store, and no certPath provided."
}

# ============================================================================
# Graph authentication
# ============================================================================

function Connect-EDGraph {
    <#
    .SYNOPSIS
        Connect Microsoft Graph app-only (cert) or interactively.
        Returns the resolved X509 certificate (needed later for the download token).
    #>
    [CmdletBinding()]
    [OutputType([System.Security.Cryptography.X509Certificates.X509Certificate2])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Auth,
        [switch]$Interactive
    )
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    if ($Interactive -or $Auth.mode -eq 'interactive') {
        Connect-MgGraph -TenantId $Auth.tenantId -Scopes 'eDiscovery.ReadWrite.All' -NoWelcome
        return $null
    }

    $cert = Get-EDCertificate -Auth $Auth
    Connect-MgGraph -ClientId $Auth.appId -TenantId $Auth.tenantId -Certificate $cert -NoWelcome
    $ctx = Get-MgContext
    if ($ctx.AuthType -ne 'AppOnly') {
        Write-EDStatus -Type Warning -Message "Expected AppOnly auth but got '$($ctx.AuthType)'."
    }
    return $cert
}

# ============================================================================
# Purview eDiscovery download token (separate resource from Graph)
# ============================================================================

function Get-EDDownloadToken {
    <#
    .SYNOPSIS
        Mint an access token for the Purview eDiscovery download resource via an
        inline certificate client-assertion JWT. The download endpoint is a
        DIFFERENT resource than Graph, so it needs its own token; pair it with
        the header 'X-AllowWithAADToken: true' on the download request.

    .NOTES
        Avoids MSAL.PS on purpose (PackageManagement shadowing breaks it in some
        environments). Pure .NET RSA signing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][string]$ResourceAppId
    )

    function ConvertTo-B64Url([byte[]]$b) {
        [Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_')
    }

    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    if (-not $rsa) { throw "Certificate has no accessible RSA private key; cannot mint download token." }

    $aud = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    # x5t = base64url(SHA1 cert hash) -- GetCertHash() returns the thumbprint bytes directly.
    $x5t = ConvertTo-B64Url($Certificate.GetCertHash())

    $hdr = ConvertTo-B64Url([Text.Encoding]::UTF8.GetBytes((@{ alg='RS256'; typ='JWT'; x5t=$x5t } | ConvertTo-Json -Compress)))
    $pay = ConvertTo-B64Url([Text.Encoding]::UTF8.GetBytes((@{
        aud = $aud; iss = $AppId; sub = $AppId
        jti = [guid]::NewGuid().ToString()
        nbf = $now; exp = $now + 600; iat = $now
    } | ConvertTo-Json -Compress)))
    $sig = ConvertTo-B64Url($rsa.SignData(
        [Text.Encoding]::ASCII.GetBytes("$hdr.$pay"),
        [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1))

    $body = @{
        client_id             = $AppId
        scope                 = "$ResourceAppId/.default"
        grant_type            = 'client_credentials'
        client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        client_assertion      = "$hdr.$pay.$sig"
    }
    $resp = Invoke-RestMethod -Method POST -Uri $aud -ContentType 'application/x-www-form-urlencoded' -Body $body
    return $resp.access_token
}

# ============================================================================
# Run manifest
# ============================================================================

function New-EDRunManifest {
    <#
    .SYNOPSIS
        Write a run manifest JSON to the output directory and return its path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$OutputDir,
        [Parameter(Mandatory)][hashtable]$Data
    )
    if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }
    $stamp = Get-Date -Format 'yyyy-MM-dd-HHmmss'
    $path  = Join-Path $OutputDir "run-manifest-$stamp.json"
    $Data['timestamp']    = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
    $Data['executedBy']   = $env:USERNAME
    $Data['computerName'] = $env:COMPUTERNAME
    $Data | ConvertTo-Json -Depth 12 | Set-Content -Path $path -Encoding UTF8
    return $path
}

Export-ModuleMember -Function Write-EDStatus,Get-EDConfig,Get-EDCertificate,Connect-EDGraph,Get-EDDownloadToken,New-EDRunManifest
