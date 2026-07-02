---
name: ediscovery-export
description: >
  Pull emails matching keywords from a set of mailboxes over a date range and
  export them as PST/MSG using Microsoft Purview eDiscovery (unified Graph API,
  app-only). Use when the user asks to "pull/collect/export emails containing
  <keywords> from <people> between <dates>", requests an eDiscovery or legal-hold
  keyword export, a PST of messages for a claim/case/litigation/HR matter, or says
  things like "eDiscovery export", "search all these mailboxes for X and give me a
  PST", or "collect messages about <topic> from these users". Runs an estimate +
  scope-confirmation gate, fires the export asynchronously, then polls for the
  download (exports take 30 min to hours).
---

# eDiscovery keyword export

Wraps `scripts/Invoke-EDiscoveryExport.ps1` (this plugin). The engine uses the
**validated** Purview model: each mailbox is added to the CASE as a **noncustodial data
source**, and the search scopes to `allCaseNoncustodialDataSources`. This works for both
regular and **shared** mailboxes. Do NOT use custodians or search `additionalSources` —
custodians don't bind for shared mailboxes (estimate returns 0) and a search can't be
created without a data source.

Canonical Graph request bodies (validated live) are in `references/api-contract.md`.

## When to invoke

- "pull / collect / export emails containing `<keywords>` from `<people>` between `<dates>`"
- "eDiscovery export" / "give me a PST of messages about `<topic>` from these mailboxes"
- A legal / claim / HR / litigation-hold keyword collection over specific mailboxes

Do **not** invoke for: single-mailbox search, phishing purges (`respond-to-phishing`), or
tenant-wide compliance searches.

## Prerequisites (verify once)

- App-only cert auth: config `auth` needs `appId`, `tenantId`, `certThumbprint` (cert in
  the store), the app holds `eDiscovery.ReadWrite.All`, is an eDiscovery Manager, and can
  reach the download resource `b26e684c-...`.
- Any UPN in `members` must already be in the **eDiscovery Manager role group** to see the
  case in the portal (adding a case member does not grant the role).
- PowerShell 7+ and `Microsoft.Graph.Authentication`.

## Step 1 — Intake and build the config

Collect: **keywords**, the **mailbox list** (SMTP; expand both domains if applicable), the
**date range**, **export format** (PST default; single combined vs per-mailbox), and who
should **see the case** in the portal. Then write a config JSON (copy
`config/ediscovery-export.example.json` to a working path). Rules:

- `search.keywords`: each element is an OR'd KQL group. `["outage request"]` -> `(outage request)`.
  Exact phrase = quote it, or set `search.contentQuery` to raw KQL (overrides keywords + dates).
- `mailboxes`: dedupe; include shared mailboxes freely.
- `members`: default to the requesting admin's cloud UPN.
- `export.singlePst`: `true` = one combined PST; `false` = one PST per mailbox.

## Step 2 — Estimate (scope gate, non-destructive)

```
pwsh -File "${CLAUDE_PLUGIN_ROOT}/scripts/Invoke-EDiscoveryExport.ps1" \
  -ConfigFile "<config>.json" -EstimateOnly
```

This builds the case, adds the member, adds the noncustodial data sources, creates the
scoped search, and returns the estimate (all idempotent). Report to the user:

```
Estimate complete (no export yet):
- Case / Search / Query
- Mailboxes bound: <mailboxCount>
- Items: <indexedItemCount>   Size: ~<sizeGB> GB
- Format: <pst|msg>, <single | per-mailbox>

Proceed with the export? (yes/no)
```

**Never proceed without explicit confirmation.** If items = 0, stop and investigate — do
not pass `-Force` to bypass a zero result unless the user insists.

## Step 3 — Fire the export (async) + poll for the download

After confirmation, fire the export. It returns immediately with an operation id, a
`export-state.json`, and the portal URL — it does **not** block (exports take 30 min to
hours):

```
pwsh -File "${CLAUDE_PLUGIN_ROOT}/scripts/Invoke-EDiscoveryExport.ps1" \
  -ConfigFile "<config>.json" -Force
```

Give the user the **portal export URL** it prints so they can watch/download there too.

Then **poll on a schedule** until the packages land. Run the resume check every ~15 min:

```
pwsh -File "${CLAUDE_PLUGIN_ROOT}/scripts/Invoke-EDiscoveryExport.ps1" \
  -ConfigFile "<config>.json" -Resume
```

- While the op is `running`, `-Resume` prints status and exits (no download).
- When `succeeded`, `-Resume` downloads the PST + report to `output.dir`, verifies the
  Summary item count, writes the run manifest, and marks the state done.

To automate the polling in Claude Code, set up a recurring check with the `/loop` skill
(e.g. `/loop 15m` running the `-Resume` command) or a scheduled routine, and stop it once
the run manifest / downloaded files appear. Outside Claude Code, a Windows Scheduled Task
running the `-Resume` command every 15 min is the equivalent (see `docs/runbook.md`).

When files land, report: `exportStatus`, each file name + size, `verifiedItemCount`, the
output directory, and the portal URL. Download URLs are valid 14 days.

## Parameter reference

| Flag | When to pass |
|------|--------------|
| `-EstimateOnly` | Step 2. Builds everything, stops before export. |
| `-Force`        | Step 3 fire, after the user confirms scope. Skips the prompt; fires async. |
| `-Resume`       | Step 3 poll. Checks the fired export; downloads when ready. |
| `-Wait`         | Optional: block until the export finishes and download inline (only for small/known-fast exports). |
| `-Interactive`  | Browser auth (then download needs the portal or `-Wait` won't have a cert token). |
| `-SkipDownload` | Fire/complete but pull the package from the portal instead. |

## Gotchas

- **Shared mailboxes are noncustodial data sources, not custodians.** The engine already
  does this. `mailboxCount=0` with real mailboxes means the wrong model is in use.
- **Portal visibility** needs the case member in the eDiscovery Manager role group first.
- **Two tokens.** Graph (case/search/export) + a separate Purview eDiscovery resource
  token for the download (`X-AllowWithAADToken: true`). The engine handles both.
- **App-only sees only cases it created** — you can't introspect a portal-made case app-only.
- **Async by default.** `-Force` fires and returns; use `-Resume` (scheduled) to download.
- **PowerShell 7 only.** Invoke via `pwsh`.

## Related files

- Engine: `scripts/Invoke-EDiscoveryExport.ps1`
- Helpers: `scripts/_lib/EDiscovery.psm1`
- Config template: `config/ediscovery-export.example.json`
- API contract (validated request bodies): `references/api-contract.md`
- Runbook: `docs/runbook.md`
