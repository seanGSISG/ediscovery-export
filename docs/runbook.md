# Runbook — eDiscovery keyword export

Operational steps for a keyword -> PST pull. For the API details see
`skills/ediscovery-export/references/api-contract.md`.

## 0. One-time prerequisites

- App (app-only) has **`eDiscovery.ReadWrite.All`** (application, admin-consented) and
  access to the download resource `b26e684c-5068-4120-a679-64a5d2c909d9`.
- The app is assigned the **eDiscovery Manager** role in Purview.
- The certificate is present (cert store by thumbprint, or a `.pfx` referenced by
  `auth.certPath` + `auth.certPasswordEnv`).
- Each `members` UPN is in the **eDiscovery Manager role group** (portal visibility).
- `Install-Module Microsoft.Graph.Authentication -Scope CurrentUser` if not present.

## 1. Author the config

Copy `config/ediscovery-export.example.json`, then set:

| Field | Notes |
|-------|-------|
| `case.name` / `description` | Human-readable case title. Reused if it already exists. |
| `search.keywords` | Array; each element is an OR'd KQL group. Or set `search.contentQuery` for raw KQL. |
| `search.startDate` / `endDate` | `yyyy-MM-dd`. Builds `(received/sent within range)`. Ignored if `contentQuery` set. |
| `mailboxes` | SMTP addresses. Include shared mailboxes freely. Deduped automatically. |
| `members` | UPNs to add as case members (portal access). |
| `export.format` / `singlePst` | `pst`/`msg`; single combined vs per-mailbox. |
| `export.includePartiallyIndexed` | Adds `partiallyIndexed` to the export criteria. |
| `output.dir` | Where packages land (relative to repo root, or absolute). |
| `auth.*` | app-only cert values, or `mode: interactive`. |

## 2. Estimate (scope gate)

```powershell
pwsh -File ./scripts/Invoke-EDiscoveryExport.ps1 -ConfigFile ./config/<name>.json -EstimateOnly
```

Builds the case, member, noncustodial data sources, and scoped search (idempotent), then
returns the estimate. Confirm `mailboxCount` and `indexedItemCount` are sane before
exporting. If items = 0 the tool refuses to export (unless `-Force`) — investigate the
query/mailboxes, do not force an empty export.

## 3. Fire the export (async)

```powershell
pwsh -File ./scripts/Invoke-EDiscoveryExport.ps1 -ConfigFile ./config/<name>.json -Force
```

Fires the export and returns immediately with the operation id, an `export-state.json` in
`output.dir`, and the **portal export URL**. Exports take 30 min to hours — the script
does not block.

## 4. Poll for the download

```powershell
pwsh -File ./scripts/Invoke-EDiscoveryExport.ps1 -ConfigFile ./config/<name>.json -Resume
```

While the export is `running`, `-Resume` prints status and exits. When `succeeded`, it
downloads each package with the Purview eDiscovery token, verifies the Summary item count,
writes `run-manifest-*.json`, and renames the state to `export-state.done.json`.

### Scheduling the poll (check every ~15 min)

- **Windows Task Scheduler** (unattended): register a task that runs the `-Resume` command
  every 15 minutes. It is a no-op while running and self-completes on success; disable the
  task once `export-state.done.json` appears.
  ```powershell
  $act = New-ScheduledTaskAction -Execute 'pwsh.exe' `
    -Argument '-File "C:\path\Invoke-EDiscoveryExport.ps1" -ConfigFile "C:\path\<name>.json" -Resume'
  $trg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 15)
  Register-ScheduledTask -TaskName 'ediscovery-export-resume' -Action $act -Trigger $trg
  ```
- **Claude Code**: use the `/loop 15m` skill (or a scheduled routine) to re-run the
  `-Resume` command, and stop it once the run manifest / downloaded files appear.
- **Small/known-fast exports**: skip the async dance — pass `-Wait` instead of `-Force` to
  block until done and download inline.

Alternative to downloading: pass `-SkipDownload` (or just use the printed portal URL) and
pull packages from **Purview portal -> eDiscovery -> Cases -> `<case>` -> Exports**
(14-day window).

## 5. After the run

- The case is visible in the portal to each `members` UPN.
- Verify the PST(s) and the `Reports-*.zip` `Summary.csv` item count are non-zero.
- Delete test/throwaway cases from the portal (or `DELETE
  /v1.0/security/cases/ediscoveryCases/{caseId}`) when done.

## Footguns

- **One `output.dir` per export — always.** `export-state.json` is written *into*
  `output.dir` under a fixed name, and the downloaded packages land there too. Firing a
  second export while another is still in flight, against the same `output.dir`, silently
  overwrites the first one's resume state: the operation is still running in Purview, but
  the local pointer to it is gone and `-Resume` now polls the newer export. Give every
  export its own directory (`output/<case>-<date>/`). `export-state.done.json` is the same
  fixed name, so a shared directory also clobbers completed-run state.
- **`-Resume` is a no-op while the export is running.** It prints the operation status and
  exits without downloading — that is the expected output for the first several polls, not
  a failure. Only when the operation reaches `succeeded`/`partiallySucceeded` does it
  download the packages, verify the `Summary.csv` item count, write `run-manifest-*.json`,
  and rename the state to `export-state.done.json`. Treat the run as finished when the
  manifest and the `.done.json` exist, not when `-Resume` stops erroring.
- **Download URLs expire after 14 days.** The `downloadUrl` values captured in
  `export-state.json` are single-user and time-limited. If you lose the local state, or
  come back after the window, do not try to reconstruct the URLs — re-open the export from
  **Purview portal -> eDiscovery -> Cases -> `<case>` -> Exports** and download from
  there, or re-run the export to mint fresh links.
- **App-only auth only sees cases it created.** Even with `eDiscovery.ReadWrite.All`, the
  app cannot enumerate, estimate, or export a case that was created in the portal or by a
  different app registration — it is not a member of it. Every case this tool touches must
  be one it created itself. If you need portal-created work, redo it as a tool-created
  case; adding `members` gives humans portal visibility into that case, not the reverse.

## Rollback / cleanup

Deleting the case removes its searches, data sources, and export operations. Downloaded
packages on disk are independent — remove them from `output.dir` manually if needed.
