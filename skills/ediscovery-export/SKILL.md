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

**Full setup for a new machine / new tenant** (app registration, certificate, role,
module) is in `docs/authentication-setup.md`. There is no `.env` — auth is entirely the
config `auth` block.

## Step 1 — Intake and build the config

Collect: **keywords**, the **mailbox list** (SMTP; expand every domain the person holds),
the **date range**, **export format** (PST default; single combined vs per-mailbox), and
who should **see the case** in the portal.

### Resolve identities to SMTP addresses

Tickets arrive with **names**, not addresses. Resolve every participant against the tenant
before writing the config — never guess an address or a domain.

1. **Enumerate the tenant's verified domains.** A tenant usually holds several, and one
   person is often addressable in more than one.

   ```
   GET /v1.0/domains?$select=id,isVerified,isDefault
   ```

2. **Resolve each name to a user.** `$search` requires the eventual-consistency header:

   ```
   GET /v1.0/users?$search="displayName:Jane Doe"&$select=displayName,userPrincipalName,mail,proxyAddresses
   ConsistencyLevel: eventual
   ```

3. **Expand the person across every domain they hold.** Read `proxyAddresses` on the
   matched user — someone at `jane.doe@example.com` may also receive at
   `jdoe@example.net`. Put **all** of their addresses in `mailboxes`, and in any
   participant clause in the query. A clause naming one address silently misses mail that
   arrived at the others.

4. **Check for a duplicate as an external contact.** The same human can exist as both an
   internal account and an external mail contact / guest. A `participants:` filter may
   need **both** forms to match every thread.

Confirm the resolved address list back to the user before estimating.

### Write the config

Copy `config/ediscovery-export.example.json` to a working path. Rules:

- `search.keywords`: each element is an OR'd KQL group. `["outage request"]` -> `(outage request)`.
  Exact phrase = quote it, or set `search.contentQuery` to raw KQL (overrides keywords + dates).
- `mailboxes`: dedupe; include shared mailboxes freely.
- `members`: default to the requesting admin's cloud UPN.
- `export.singlePst`: `true` = one combined PST; `false` = one PST per mailbox.

### WARNING — `search.contentQuery` replaces the whole query, dates included

`Build-ContentQuery` returns a supplied `contentQuery` **immediately**, before any date
logic runs. Only the keywords + `startDate` + `endDate` path builds both halves of the
date window:

```
(received>=<start> AND received<=<end>) OR (sent>=<start> AND sent<=<end>)
```

A raw `contentQuery` silently discards the `sent` half. An operator who writes only a
`received>=` clause **loses Sent Items** — which is exactly where a "sent to X" message
lives. Nothing errors and nothing warns; the estimate just comes back smaller. That is
silent under-collection, the worst failure mode in a legal search: over-collection is
reviewable, under-collection is invisible.

Prefer `keywords` + `startDate` + `endDate` and let the engine build the window. If you
must use raw KQL, carry both halves yourself:

```json
"contentQuery": "(\"widget recall\") AND ((received>=2026-01-01 AND received<=2026-01-31) OR (sent>=2026-01-01 AND sent<=2026-01-31))"
```

### One output directory per export

`Save-ExportState` writes `export-state.json` into `output.dir`. Two configs pointing at
the same `output.dir` means the second fired export **overwrites the first's state file**
— the first export can no longer be `-Resume`d or downloaded by the engine (only from the
portal, and only for 14 days). Give every export its own directory, even when the configs
share a case.

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

## Step 2a — Breadth triage (choose the query before exporting)

Estimates are non-destructive and repeatable, and `Get-OrCreate-Case` matches an existing
case by `displayName` — data sources are added at the **case** level, so several configs
sharing one case name reuse the same case and the same mailbox bindings (the engine
reports `0 added, N already present`). That makes A/B-ing a query's breadth cheap.

Use it whenever the request could reasonably be read narrow or broad.

1. Build 2-4 configs sharing `case.name` and `mailboxes`, differing **only** in
   `search.name` and the query.
2. Run each with `-EstimateOnly`.
3. Compare **item count** *and* **mailboxes bound** across variants.
4. Present the comparison, then export **exactly one**.

Reading the numbers:

| Signal | Meaning | Action |
|--------|---------|--------|
| Adding a filter barely moves the item count | Weak discriminator — buys little, still able to exclude the target message | Reject it; keep the broader query |
| A variant hits **fewer mailboxes** than the broad case | Suspect — the query is silently dropping a mailbox or a domain (usually an unexpanded address) | Investigate before trusting it |
| Big count drop, mailbox coverage held | Real narrowing | Export candidate |

Worked example — keyword + attachment + one month, across two mailboxes:

| Variant | Items | Mailboxes hit | Verdict |
|---------|-------|---------------|---------|
| keyword + `hasattachment:true` + month | 276 | 2 of 2 | Baseline |
| ...plus a three-person recipient filter | 231 | 2 of 2 | **Rejected** — cut only ~16% while risking exclusion of the target thread |
| ...plus a second required keyword (`AND`) | 179 | **1 of 2** | **Rejected** — silently dropped a mailbox |

The 276-item baseline was exported. A ~16% reduction does not justify exclusion risk in a
legal collection.

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

**Preferred: automate the poll with the Claude Code `/loop` skill** — e.g. run
`/loop 15m` executing the `-Resume` command, and stop the loop once the run manifest /
downloaded files appear. Outside Claude Code, a Windows Scheduled Task running the
`-Resume` command every 15 min is the equivalent (see `docs/runbook.md`).

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
