# ediscovery-export

A **Claude Code plugin** (and standalone PowerShell tool) that runs a Microsoft **Purview
eDiscovery** keyword search across a set of mailboxes and exports the matching mail to
**PST/MSG** — app-only, unattended, over the unified Graph API.

Ask in plain language ("pull all emails containing *outage request* from these mailboxes
between March and October 2022 and give me a single PST") and the skill handles the rest:
resolve scope → estimate → confirm → export → download.

## Install in Claude Code

```
/plugin marketplace add https://github.com/seanGSISG/ediscovery-export
/plugin install ediscovery-export@gsi-ediscovery
```

(Or add it from a local clone: `/plugin marketplace add /path/to/ediscovery-export`.)

The `ediscovery-export` skill then triggers automatically on eDiscovery/keyword-export
requests. It shells out to the bundled PowerShell engine.

## What it does

1. **Estimate (scope gate)** — builds the case, adds you as a member (portal visibility),
   attaches each mailbox as a data source, creates the search, and reports how many items
   match — *before* anything is exported.
2. **Export (async)** — fires the export and returns immediately with an operation id, a
   state file, and the Purview portal URL. Exports take 30 min to hours, so it never blocks.
3. **Download** — a `-Resume` check (poll it with `/loop 15m`) downloads the PST + report
   when the export finishes, verifies the item count, and writes a run manifest.

Works for **shared mailboxes** because it uses the correct Purview model — mailboxes are
added as **case noncustodial data sources** scoped by `allCaseNoncustodialDataSources`, not
custodians (custodians silently return 0 items for shared mailboxes). Validated end-to-end.

Two things the skill does before it estimates, because both are common sources of a clean
but **wrong** "no results":

- **Identity resolution.** Requests arrive with *names*, not SMTP addresses. Each person is
  resolved against the directory and expanded across **every** domain their account holds —
  searching one domain when someone is dual-homed returns a confident false negative. It
  also checks whether the same human exists a second time as an external contact or guest.
- **Breadth triage.** Several searches can share one case and reuse its mailbox bindings, so
  candidate queries can be A/B'd by estimate before anything is exported. Compare item count
  *and* mailboxes bound: a filter that barely moves the count is a weak discriminator that
  only adds exclusion risk, and a variant hitting fewer mailboxes is usually dropping one
  silently rather than legitimately narrowing.

## Requirements

- PowerShell 7+ and the `Microsoft.Graph.Authentication` module.
- An Entra app with `eDiscovery.ReadWrite.All` (application, admin-consented), assigned the
  **eDiscovery Manager** role, plus a **certificate** (store thumbprint or `.pfx`).

Authentication is certificate-based app-only, configured in the config file's `auth` block —
**no client secret, no `.env`**. Full new-machine setup (app registration, cert, role,
module) is in **[docs/authentication-setup.md](docs/authentication-setup.md)**.

## Use it directly (without Claude Code)

```powershell
# 1. copy the example and fill it in (real configs are gitignored)
Copy-Item config/ediscovery-export.example.json config/my-pull.json

# 2. estimate / scope gate (no export)
pwsh -File ./scripts/Invoke-EDiscoveryExport.ps1 -ConfigFile ./config/my-pull.json -EstimateOnly

# 3. fire the export (async — returns an op id + portal URL)
pwsh -File ./scripts/Invoke-EDiscoveryExport.ps1 -ConfigFile ./config/my-pull.json -Force

# 4. poll until the PST lands (schedule this every ~15 min)
pwsh -File ./scripts/Invoke-EDiscoveryExport.ps1 -ConfigFile ./config/my-pull.json -Resume
```

For small/known-fast exports, pass `-Wait` instead of `-Force` to block and download inline.
Runs are idempotent — re-running reuses the case, search, and data sources.

## Config

See [`config/ediscovery-export.example.json`](config/ediscovery-export.example.json)
(inline `$comment` fields). Highlights: `search.keywords` (each element an OR'd KQL group),
`export.singlePst` (single combined vs per-mailbox), `members` (UPNs to grant portal
access), `auth` (app-only cert).

> **`search.contentQuery` replaces the whole query — dates included.** Supplying raw KQL
> bypasses the date builder entirely, so a query with only a `received>=` clause silently
> drops **Sent Items** — exactly where a "sent to X" message lives. Nothing errors; the
> estimate just comes back smaller. Prefer `keywords` + `startDate`/`endDate`, or carry
> both halves yourself:
> `(<terms>) AND ((received>=A AND received<=B) OR (sent>=A AND sent<=B))`

Building a query by hand? The supported KeyQL properties (`participants`, `subject`,
`hasattachment`, `attachmentnames`, `kind`, `sent`/`received`, …) are tabulated with
syntax rules in
**[skills/ediscovery-export/references/api-contract.md](skills/ediscovery-export/references/api-contract.md)**.
Note there is no `body:` property — body text is reachable only via bare keywords.

## Layout

```
.claude-plugin/{plugin.json, marketplace.json}   # plugin + local marketplace
skills/ediscovery-export/SKILL.md                 # the skill (+ references/api-contract.md)
scripts/Invoke-EDiscoveryExport.ps1               # the engine
scripts/_lib/EDiscovery.psm1                      # auth, download-token JWT, output
config/ediscovery-export.example.json
docs/{authentication-setup,runbook,troubleshooting}.md
```

## Notes

- Export operations are asynchronous; download URLs are single-user and valid 14 days.
- Two tokens: Graph (case/search/export) + a separate Purview eDiscovery resource token for
  the download. The engine handles both; MSAL.PS is intentionally avoided.
- Classic `New-ComplianceSearch -Export` is retired in the cloud (2025-05-26); Graph is the
  only cloud export path. See [docs/troubleshooting.md](docs/troubleshooting.md).
