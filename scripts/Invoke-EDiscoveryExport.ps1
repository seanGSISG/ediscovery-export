<#
.SYNOPSIS
    Run a Microsoft Purview eDiscovery keyword search across a set of mailboxes and export the hits (PST/MSG), app-only and unattended.

.DESCRIPTION
    Purpose:
        Turns a JSON config ("pull <keywords> from <mailboxes> over <dates> -> PST")
        into a repeatable, verified Purview eDiscovery (unified, Graph API) export.
        Replaces the retired classic `New-ComplianceSearch -Export` path (dead in the
        cloud since 2025-05-26) and the fragile custodian model.

    Pipeline (idempotent; safe to re-run):
        1. Connect Microsoft Graph (app-only cert, or -Interactive).
        2. Get-or-create the eDiscovery case.
        3. Add case members (so the case is visible in the Purview portal).
        4. Add each mailbox to the CASE as a noncustodial data source -- this is the
           correct model for user AND shared mailboxes. NOT custodians (they bind
           nothing for shared mailboxes, so the estimate silently returns 0), and
           NOT inline additionalSources on the search (ignored on create).
        5. Get-or-create the search with the built KQL contentQuery, scoped via
           dataSourceScopes = allCaseNoncustodialDataSources. The case data sources
           must already exist: a search cannot be created without at least one.
        6. Estimate statistics and GATE on a non-zero result.
        7. Export the hits, poll the operation to completion.
        8. Download the result package(s) using the separate Purview eDiscovery
           download token (X-AllowWithAADToken), then verify + write a run manifest.

    Limitations:
        - Export operations are asynchronous and can take a long time for multi-GB
          scopes. Download URLs are single-user and valid for 14 days.
        - App-only requires the app to hold eDiscovery.ReadWrite.All (+ the download
          resource) and be an eDiscovery Manager. Case members must already be in the
          eDiscovery Manager role group to gain portal access.

.PARAMETER ConfigFile
    Path to the JSON run config. See config/ediscovery-export.example.json.

.PARAMETER EstimateOnly
    Run through the estimate and stop (no export). Use for the scope-confirmation phase.

.PARAMETER Force
    Proceed to export without the interactive scope-confirmation prompt, and allow a
    zero-hit estimate to continue. For unattended / skill-driven runs.

.PARAMETER Interactive
    Use interactive (browser) Graph auth instead of the app-only certificate.

.PARAMETER SkipDownload
    Fire and complete the export but do not download the package (pull later from the portal).

.EXAMPLE
    PS> ./scripts/Invoke-EDiscoveryExport.ps1 -ConfigFile ./config/my-pull.json -EstimateOnly
    Phase 1: build case/search/sources and show the estimate for confirmation.

.EXAMPLE
    PS> ./scripts/Invoke-EDiscoveryExport.ps1 -ConfigFile ./config/my-pull.json -Force
    Phase 2: reuse the same case/search/sources, export, and download.

.NOTES
    Author:   GSI IT Infrastructure
    Version:  1.0.0
    Requires: PowerShell 7+, Microsoft.Graph.Authentication
.LINK
    https://learn.microsoft.com/graph/api/resources/security-ediscoverysearch
#>

#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Authentication'; ModuleVersion = '2.0' }

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ConfigFile,
    [switch]$EstimateOnly,
    [switch]$Force,
    [switch]$Interactive,
    [switch]$SkipDownload,
    # Async model: by default the export is fired and the script exits without
    # blocking (exports can take 30 min to hours). Poll later with -Resume, or
    # pass -Wait to block until the export finishes and download inline.
    [switch]$Wait,
    [switch]$Resume
)

$ErrorActionPreference = 'Stop'
$ProgressPreference     = 'SilentlyContinue'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot '_lib\EDiscovery.psm1') -Force

# ============================================================================
# Small Graph helpers
# ============================================================================

function Invoke-EDGraph {
    param([string]$Method,[string]$Uri,$Body,[ref]$Headers)
    # -OutputType PSObject so responses are PSCustomObjects (with working
    # .PSObject.Properties and nested typed objects), not raw hashtables.
    $p = @{ Method = $Method; Uri = $Uri; OutputType = 'PSObject' }
    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        $p.Body = ($Body | ConvertTo-Json -Depth 10 -Compress)
        $p.ContentType = 'application/json'
    }
    if ($Headers) { $p.ResponseHeadersVariable = 'h' }
    $result = Invoke-MgGraphRequest @p
    if ($Headers) { $Headers.Value = $h }
    return $result
}

function Get-OpIdFromLocation {
    param([object]$Headers)
    $loc = [string](@($Headers.Location)[0])
    if ($loc -match "operations\('([^']+)'\)") { return $Matches[1] }
    if ($loc -match "operations/([^/?]+)")     { return $Matches[1] }
    return $null
}

function Wait-EDOperation {
    param([string]$CaseId,[string]$OpId,[int]$PollSeconds = 15,[int]$TimeoutMinutes = 240)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        Start-Sleep -Seconds $PollSeconds
        $op = Invoke-EDGraph GET "/v1.0/security/cases/ediscoveryCases/$CaseId/operations/$OpId"
        $pct = if ($op.PSObject.Properties.Name -contains 'percentProgress') { $op.percentProgress } else { '' }
        Write-EDStatus -Type Action -Message ("  {0}  status={1} {2}" -f (Get-Date -f HH:mm:ss), $op.status, ($(if($pct -ne ''){"($pct%)"}else{''})))
        if ((Get-Date) -gt $deadline) { throw "Operation $OpId timed out after $TimeoutMinutes minutes (last status: $($op.status))." }
    } while ($op.status -in 'notStarted','running','submitted')
    return $op
}

# ============================================================================
# Pipeline steps
# ============================================================================

function Build-ContentQuery {
    param([PSCustomObject]$Search)
    if ($Search.PSObject.Properties.Name -contains 'contentQuery' -and $Search.contentQuery) {
        return [string]$Search.contentQuery
    }
    $kwExpr = '(' + ((@($Search.keywords)) -join ') OR (') + ')'
    $hasStart = $Search.PSObject.Properties.Name -contains 'startDate' -and $Search.startDate
    $hasEnd   = $Search.PSObject.Properties.Name -contains 'endDate'   -and $Search.endDate
    if ($hasStart -and $hasEnd) {
        $s = ([datetime]$Search.startDate).ToString('yyyy-MM-dd')
        $e = ([datetime]$Search.endDate).ToString('yyyy-MM-dd')
        $dateExpr = "(received>=$s AND received<=$e) OR (sent>=$s AND sent<=$e)"
        return "($kwExpr) AND ($dateExpr)"
    }
    return $kwExpr
}

function Get-OrCreate-Case {
    param([PSCustomObject]$Case)
    $name = ($Case.name -replace "'","''")
    $found = (Invoke-EDGraph GET "/v1.0/security/cases/ediscoveryCases?`$filter=displayName eq '$name'").value
    if ($found) {
        Write-EDStatus -Type Info -Message "Reusing existing case '$($Case.name)' = $($found[0].id)"
        return $found[0]
    }
    $desc = if ($Case.PSObject.Properties.Name -contains 'description') { $Case.description } else { '' }
    $c = Invoke-EDGraph POST "/v1.0/security/cases/ediscoveryCases" @{ displayName = $Case.name; description = $desc }
    Write-EDStatus -Type Success -Message "Created case '$($Case.name)' = $($c.id)"
    return $c
}

function Add-CaseMembers {
    param([string]$CaseId,[string[]]$Members)
    if (-not $Members) { return }
    foreach ($m in @($Members)) {
        # Proven working body: bare recipientType + smtpAddress (no @odata.type).
        $body = @{ recipientType = 'user'; smtpAddress = $m }
        try {
            Invoke-EDGraph POST "/v1.0/security/cases/ediscoveryCases/$CaseId/caseMembers" $body | Out-Null
            Write-EDStatus -Type Success -Message "Added case member $m"
        } catch {
            if ("$_" -match 'already|exists|conflict|duplicate') {
                Write-EDStatus -Type Info -Message "Case member $m already present."
            } else {
                Write-EDStatus -Type Warning -Message "Could not add case member $m (must be in the eDiscovery Manager role group first): $_"
            }
        }
    }
}

function Add-NoncustodialSources {
    <#
    .SYNOPSIS
        Add each mailbox to the CASE as a noncustodial data source. This is the
        documented model the Purview portal uses ("People"/"Groups"), and it works
        for both regular and shared mailboxes. The search then binds to all of them
        via dataSourceScopes = allCaseNoncustodialDataSources. Idempotent.
    #>
    param([string]$CaseId,[string[]]$Mailboxes)
    $dedup = @($Mailboxes | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ } | Select-Object -Unique)
    $existing = @()
    try {
        $existing = @((Invoke-EDGraph GET "/v1.0/security/cases/ediscoveryCases/$CaseId/noncustodialDataSources?`$expand=dataSource").value) |
            ForEach-Object { $_.dataSource.email } | Where-Object { $_ } | ForEach-Object { $_.ToLower() }
    } catch {}
    $added = 0; $skipped = 0
    foreach ($mbx in $dedup) {
        if ($existing -contains $mbx) { $skipped++; continue }
        try {
            Invoke-EDGraph POST "/v1.0/security/cases/ediscoveryCases/$CaseId/noncustodialDataSources" `
                @{ dataSource = @{ '@odata.type' = 'microsoft.graph.security.userSource'; email = $mbx } } | Out-Null
            $added++
        } catch {
            Write-EDStatus -Type Warning -Message "Failed to add data source $mbx : $_"
        }
    }
    Write-EDStatus -Type Success -Message "Noncustodial data sources: $added added, $skipped already present ($($dedup.Count) unique mailboxes)."
    return $dedup.Count
}

function Get-OrCreate-Search {
    param([string]$CaseId,[PSCustomObject]$Search,[string]$ContentQuery)
    $name = ($Search.name -replace "'","''")
    $found = (Invoke-EDGraph GET "/v1.0/security/cases/ediscoveryCases/$CaseId/searches?`$filter=displayName eq '$name'").value
    if ($found) {
        Write-EDStatus -Type Info -Message "Reusing existing search '$($Search.name)' = $($found[0].id)"
        return $found[0]
    }
    $desc = if ($Search.PSObject.Properties.Name -contains 'description') { $Search.description } else { '' }
    # dataSourceScopes = allCaseNoncustodialDataSources binds the case noncustodial
    # sources added above and satisfies the "at least one data source" create rule.
    $s = Invoke-EDGraph POST "/v1.0/security/cases/ediscoveryCases/$CaseId/searches" @{
        displayName = $Search.name; description = $desc; contentQuery = $ContentQuery
        dataSourceScopes = 'allCaseNoncustodialDataSources'
    }
    Write-EDStatus -Type Success -Message "Created search '$($Search.name)' = $($s.id)"
    return $s
}

function Invoke-Estimate {
    param([string]$CaseId,[string]$SearchId)
    $h = $null
    Invoke-EDGraph POST "/v1.0/security/cases/ediscoveryCases/$CaseId/searches/$SearchId/estimateStatistics" @{ statisticsOptions = 'includeQueryStats' } ([ref]$h) | Out-Null
    $opId = Get-OpIdFromLocation $h
    if (-not $opId) { throw "Could not resolve estimate operation id from Location header." }
    Write-EDStatus -Type Info -Message "Estimate operation $opId - polling..."
    return Wait-EDOperation -CaseId $CaseId -OpId $opId
}

function Start-Export {
    <#
    .SYNOPSIS
        Fire the export (POST exportResult) and return the new operation id.
        Does NOT block -- exports can take 30 min to hours.
    #>
    param([string]$CaseId,[string]$SearchId,[PSCustomObject]$Export)
    $opts = @()
    if ($Export.includeReport) { $opts += 'includeReport' }
    if (-not $Export.singlePst) { $opts += 'splitSource' }
    if ($opts.Count -eq 0) { $opts += 'none' }

    $criteria = if ($Export.PSObject.Properties.Name -contains 'criteria' -and $Export.criteria) { $Export.criteria } else { 'searchHits' }
    if ($Export.includePartiallyIndexed -and $criteria -notmatch 'partiallyIndexed') { $criteria = "$criteria, partiallyIndexed" }
    $location = if ($Export.PSObject.Properties.Name -contains 'location' -and $Export.location) { $Export.location } else { 'responsiveLocations' }
    $format   = if ($Export.PSObject.Properties.Name -contains 'format'   -and $Export.format)   { $Export.format }   else { 'pst' }

    $body = @{
        displayName       = "Export $(Get-Date -f 'yyyy-MM-dd HHmm')"
        exportCriteria    = $criteria
        exportLocation    = $location
        additionalOptions = ($opts -join ', ')
        exportFormat      = $format
    }
    $h = $null
    Invoke-EDGraph POST "/v1.0/security/cases/ediscoveryCases/$CaseId/searches/$SearchId/exportResult" $body ([ref]$h) | Out-Null
    $opId = Get-OpIdFromLocation $h
    if (-not $opId) { throw "Could not resolve export operation id from Location header." }
    Write-EDStatus -Type Success -Message "Export fired: operation $opId (format=$format, options='$($body.additionalOptions)')."
    return $opId
}

function Get-PortalExportUrl {
    param([string]$CaseId,[string]$CaseName,[string]$TenantId)
    "https://purview.microsoft.com/ediscovery/casespage/$CaseId" +
        "?tid=$TenantId&casename=$([uri]::EscapeDataString($CaseName))&viewid=Exports"
}

function Save-ExportState {
    param([string]$OutDir,[hashtable]$State)
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
    $p = Join-Path $OutDir 'export-state.json'
    $State | ConvertTo-Json -Depth 8 | Set-Content -Path $p -Encoding UTF8
    return $p
}

function Get-ExportState {
    param([string]$OutDir)
    $p = Join-Path $OutDir 'export-state.json'
    if (-not (Test-Path $p)) { throw "No export-state.json in $OutDir. Nothing to resume -- fire an export first (without -Resume)." }
    return (Get-Content $p -Raw | ConvertFrom-Json)
}

function Get-ExportFileMetadata {
    param([string]$CaseId,[object]$Op)
    if ($Op.PSObject.Properties.Name -contains 'exportFileMetadata' -and $Op.exportFileMetadata) {
        return $Op.exportFileMetadata
    }
    # Metadata can lag; re-GET a few times.
    for ($i=0; $i -lt 6; $i++) {
        Start-Sleep 5
        $op2 = Invoke-EDGraph GET "/v1.0/security/cases/ediscoveryCases/$CaseId/operations/$($Op.id)"
        if ($op2.PSObject.Properties.Name -contains 'exportFileMetadata' -and $op2.exportFileMetadata) {
            return $op2.exportFileMetadata
        }
    }
    return @()
}

function Save-ExportFiles {
    param([object[]]$Metadata,[string]$Token,[string]$OutDir)
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
    $saved = @()
    foreach ($m in $Metadata) {
        $dest = Join-Path $OutDir $m.fileName
        Write-EDStatus -Type Action -Message ("Downloading {0} ({1:N0} bytes)..." -f $m.fileName, $m.size)
        Invoke-WebRequest -Uri $m.downloadUrl -OutFile $dest -Headers @{ Authorization = "Bearer $Token"; 'X-AllowWithAADToken' = 'true' }
        $saved += [PSCustomObject]@{ fileName = $m.fileName; size = $m.size; path = $dest }
    }
    return $saved
}

function Test-ExportResults {
    param([object[]]$Saved,[string]$OutDir)
    $reportZip = $Saved | Where-Object { $_.fileName -match '^Reports.*\.zip$' } | Select-Object -First 1
    if (-not $reportZip) { Write-EDStatus -Type Warning -Message "No Reports*.zip found to verify Summary.csv (data package still downloaded)."; return $null }
    $tmp = Join-Path $OutDir ("_verify-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    try {
        Expand-Archive -Path $reportZip.path -DestinationPath $tmp -Force
        $summary = Get-ChildItem -Path $tmp -Recurse -Filter 'Summary*.csv' | Select-Object -First 1
        if (-not $summary) { Write-EDStatus -Type Warning -Message "Summary.csv not present in report zip."; return $null }
        # DirectExport report:   "Indexed items","142","..."
        # GenerateStatistics report: "ItemCount","2385",...
        $line = Get-Content $summary.FullName | Where-Object { $_ -match '^"?(Indexed items|ItemCount)"?\s*,' } | Select-Object -First 1
        if ($line -and $line -match ',\s*"?(\d+)"?') {
            $count = [int]$Matches[1]
            if ($count -gt 0) { Write-EDStatus -Type Success -Message "Verified: Summary reports $count indexed item(s)." }
            else             { Write-EDStatus -Type Warning -Message "Summary reports 0 items (empty export)." }
            return $count
        }
        Write-EDStatus -Type Warning -Message "Could not parse item count from Summary.csv."
        return $null
    } finally {
        if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    }
}

function Complete-Download {
    <#
    .SYNOPSIS
        Given a succeeded export operation, fetch its file metadata, download the
        packages with the Purview eDiscovery token, and verify. Shared by -Wait
        and -Resume. Returns @{ saved; verified; meta }.
    #>
    param([object]$Cfg,[string]$OutDir,[string]$CaseId,[object]$Op,
          [System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert)
    $meta = Get-ExportFileMetadata -CaseId $CaseId -Op $Op
    Write-EDStatus -Type Success -Message "Export $($Op.status): $(@($meta).Count) file(s)."
    $meta | ForEach-Object { Write-Host ("  {0}  {1:N0} bytes" -f $_.fileName, $_.size) }
    $saved = @(); $verified = $null
    if ($SkipDownload) {
        Write-EDStatus -Type Info -Message "SkipDownload set. Download later from the portal (14-day window)."
    } elseif (-not $Cert) {
        throw "Download requires certificate auth; re-run without -Interactive, or use -SkipDownload and pull from the portal."
    } else {
        Write-EDStatus -Type Header -Message "Download + verify"
        $token = Get-EDDownloadToken -Certificate $Cert -TenantId $Cfg.auth.tenantId -AppId $Cfg.auth.appId -ResourceAppId $Cfg.auth.downloadResourceAppId
        $saved = Save-ExportFiles -Metadata $meta -Token $token -OutDir $OutDir
        $verified = Test-ExportResults -Saved $saved -OutDir $OutDir
    }
    return [PSCustomObject]@{ saved = @($saved); verified = $verified; meta = $meta }
}

# ============================================================================
# Main
# ============================================================================

$cert = $null
try {
    Write-EDStatus -Type Header -Message "eDiscovery keyword export"
    $cfgPath = if ([IO.Path]::IsPathRooted($ConfigFile)) { $ConfigFile } else { Join-Path (Get-Location) $ConfigFile }
    $cfg = Get-EDConfig -Path $cfgPath
    $contentQuery = Build-ContentQuery -Search $cfg.search

    $outDir = $cfg.output.dir
    if (-not [IO.Path]::IsPathRooted($outDir)) { $outDir = Join-Path $projectRoot $outDir }

    Write-Host "Case:      $($cfg.case.name)"
    Write-Host "Search:    $($cfg.search.name)"
    Write-Host "Query:     $contentQuery"
    Write-Host "Mailboxes: $(@($cfg.mailboxes).Count)"
    Write-Host "Output:    $outDir"
    Write-Host "Auth:      $($cfg.auth.mode)"

    # ----- Connect -----
    Write-EDStatus -Type Header -Message "Authenticate"
    $cert = Connect-EDGraph -Auth $cfg.auth -Interactive:$Interactive
    Write-EDStatus -Type Success -Message "Connected: $((Get-MgContext).AuthType)"

    # ----- RESUME: check a previously-fired export and download if ready -----
    if ($Resume) {
        Write-EDStatus -Type Header -Message "Resume export"
        $st = Get-ExportState -OutDir $outDir
        $purl = Get-PortalExportUrl -CaseId $st.caseId -CaseName $cfg.case.name -TenantId $cfg.auth.tenantId
        $op = Invoke-EDGraph GET "/v1.0/security/cases/ediscoveryCases/$($st.caseId)/operations/$($st.exportOperationId)"
        $pct = if ($op.PSObject.Properties.Name -contains 'percentProgress') { $op.percentProgress } else { '' }
        Write-EDStatus -Type Info -Message "Export op $($st.exportOperationId): status=$($op.status) $(if($pct -ne ''){"($pct%)"})"
        if ($op.status -in 'notStarted','running','submitted') {
            Write-EDStatus -Type Info -Message "Still running. Check again later, or use the portal:"
            Write-Host "  Portal: $purl"
            return
        }
        if ($op.status -notin 'succeeded','partiallySucceeded') { throw "Export operation ended with status '$($op.status)'." }
        $res = Complete-Download -Cfg $cfg -OutDir $outDir -CaseId $st.caseId -Op $op -Cert $cert
        $done = Join-Path $outDir 'export-state.done.json'
        Move-Item -Force (Join-Path $outDir 'export-state.json') $done -ErrorAction SilentlyContinue
        $mf = New-EDRunManifest -OutputDir $outDir -Data @{
            phase='resume-download'; caseId=$st.caseId; searchId=$st.searchId
            exportOperationId=$st.exportOperationId; exportStatus=$op.status
            files=@($res.saved); verifiedItemCount=$res.verified; portalUrl=$purl
        }
        Write-EDStatus -Type Header -Message "Complete"
        Write-Host "Files:        $(@($res.saved).Count) in $outDir"
        Write-Host "Portal:       $purl"
        Write-Host "Run manifest: $mf"
        return
    }

    # ----- Build case / search / sources (idempotent) -----
    Write-EDStatus -Type Header -Message "Case, members, search, data sources"
    $case = Get-OrCreate-Case -Case $cfg.case
    $members = if ($cfg.PSObject.Properties.Name -contains 'members') { @($cfg.members) } else { @() }
    Add-CaseMembers -CaseId $case.id -Members $members
    # Data sources must exist on the case BEFORE the search is created (the search
    # scopes to them at create time).
    $mbxCount = Add-NoncustodialSources -CaseId $case.id -Mailboxes @($cfg.mailboxes)
    $search = Get-OrCreate-Search -CaseId $case.id -Search $cfg.search -ContentQuery $contentQuery

    # ----- Estimate + gate -----
    Write-EDStatus -Type Header -Message "Estimate (scope gate)"
    $est = Invoke-Estimate -CaseId $case.id -SearchId $search.id
    $items = $est.indexedItemCount; $mbx = $est.mailboxCount
    $sizeGB = if ($est.PSObject.Properties.Name -contains 'indexedItemsSize') { [math]::Round($est.indexedItemsSize/1GB,2) } else { 0 }
    Write-EDStatus -Type Info -Message "Estimate: status=$($est.status)  mailboxes=$mbx  items=$items  size=${sizeGB}GB"

    if ($items -eq 0 -and -not $Force) {
        throw "Estimate returned 0 items. Refusing to export an empty result. Re-run with -Force to override, or check the query/mailboxes."
    }

    if ($EstimateOnly) {
        Write-EDStatus -Type Success -Message "EstimateOnly: stopping before export. Case=$($case.id) Search=$($search.id)"
        $mf = New-EDRunManifest -OutputDir $outDir -Data @{
            phase='estimate'; caseId=$case.id; searchId=$search.id; contentQuery=$contentQuery
            mailboxesRequested=$mbxCount; estimate=@{ mailboxes=$mbx; items=$items; sizeGB=$sizeGB }
        }
        Write-Host "Run manifest: $mf"
        return
    }

    # ----- Confirm scope (interactive) unless -Force -----
    if (-not $Force) {
        Write-Host ""
        Write-Host "About to export $items items (~${sizeGB}GB) across $mbx mailboxes as $($cfg.export.format)." -ForegroundColor Yellow
        $resp = Read-Host "Proceed with export? (y/N)"
        if ($resp -notin 'y','Y') { Write-EDStatus -Type Warning -Message "Cancelled by user."; return }
    }

    if (-not $PSCmdlet.ShouldProcess("$($cfg.case.name)/$($cfg.search.name)", "Export $items items")) { return }

    # ----- Fire the export (async) -----
    Write-EDStatus -Type Header -Message "Export"
    $opId = Start-Export -CaseId $case.id -SearchId $search.id -Export $cfg.export
    $purl = Get-PortalExportUrl -CaseId $case.id -CaseName $cfg.case.name -TenantId $cfg.auth.tenantId
    $statePath = Save-ExportState -OutDir $outDir -State @{
        caseId=$case.id; searchId=$search.id; exportOperationId=$opId
        firedAt=(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ'); format=$cfg.export.format
        contentQuery=$contentQuery; portalUrl=$purl
        estimate=@{ mailboxes=$mbx; items=$items; sizeGB=$sizeGB }
    }

    if ($Wait) {
        $op = Wait-EDOperation -CaseId $case.id -OpId $opId
        if ($op.status -notin 'succeeded','partiallySucceeded') { throw "Export operation ended with status '$($op.status)'." }
        $res = Complete-Download -Cfg $cfg -OutDir $outDir -CaseId $case.id -Op $op -Cert $cert
        Move-Item -Force $statePath (Join-Path $outDir 'export-state.done.json') -ErrorAction SilentlyContinue
        $mf = New-EDRunManifest -OutputDir $outDir -Data @{
            phase='export'; caseId=$case.id; searchId=$search.id; contentQuery=$contentQuery
            exportOperationId=$opId; exportStatus=$op.status
            mailboxesRequested=$mbxCount; estimate=@{ mailboxes=$mbx; items=$items; sizeGB=$sizeGB }
            files=@($res.saved); verifiedItemCount=$res.verified; portalUrl=$purl
        }
        Write-EDStatus -Type Header -Message "Complete"
        Write-Host "Files:        $(@($res.saved).Count) in $outDir"
        Write-Host "Portal:       $purl"
        Write-Host "Run manifest: $mf"
    } else {
        Write-EDStatus -Type Header -Message "Export fired (async)"
        Write-EDStatus -Type Success -Message "Not blocking. Poll with -Resume (exports take 30 min to hours)."
        Write-Host "Case:       $($case.id)"
        Write-Host "Export op:  $opId"
        Write-Host "State file: $statePath"
        Write-Host "Portal:     $purl"
        Write-Host "Resume:     pwsh -File `"$PSCommandPath`" -ConfigFile `"$cfgPath`" -Resume"
    }
}
catch {
    Write-EDStatus -Type Error -Message "Failed: $_"
    throw
}
finally {
    try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch {}
}
