# ediscovery-export

Run a **Microsoft Purview eDiscovery** keyword search across a set of mailboxes and
export the matching mail to **PST/MSG** — app-only and unattended — over the unified
**Graph API**. Ships as a standalone PowerShell tool *and* a Claude Code plugin (a
natural-language skill front door).

Built after the classic `New-ComplianceSearch -Export` path was retired in the cloud
(2025-05-26). Uses the correct data-source model so it works for **shared mailboxes**
(the common failure mode — see below).

## Why this exists / the one rule that matters

In unified eDiscovery, mailboxes are added to the **case as noncustodial data sources**,
and the search scopes to `allCaseNoncustodialDataSources` — *not* as case custodians.
Shared mailboxes do **not** bind as custodians; if you use custodians the estimate
silently returns 0 items and you export an empty PST. This tool uses the noncustodial
model, matching exactly what the Purview portal does ("People" + "Groups" data sources).
It is validated end-to-end against a live tenant.

## Layout

```
ediscovery-export/
├── .claude-plugin/
│   ├── plugin.json              # Claude Code plugin manifest
│   └── marketplace.json         # local marketplace (for /plugin install)
├── skills/ediscovery-export/
│   ├── SKILL.md                 # natural-language front door (two-phase flow)
│   └── references/api-contract.md   # canonical Graph request bodies
├── scripts/
│   ├── Invoke-EDiscoveryExport.ps1  # the engine (config-driven pipeline)
│   └── _lib/EDiscovery.psm1         # self-contained helpers (auth, JWT, output)
├── config/ediscovery-export.example.json
└── docs/runbook.md, docs/troubleshooting.md
```

## Requirements

- PowerShell 7+, `Microsoft.Graph.Authentication` (`Install-Module Microsoft.Graph.Authentication`)
- An Entra app with **`eDiscovery.ReadWrite.All`** (application) + access to the Purview
  eDiscovery download resource, holding an **eDiscovery Manager** role, and a certificate
  (in the cert store by thumbprint, or a `.pfx`).
- Any UPN you list under `members` must already be in the **eDiscovery Manager role
  group** to see the case in the portal.

## Authentication (no `.env`, no secret)

Certificate-based **app-only** auth, configured entirely in the config JSON's `auth` block
(`appId`, `tenantId`, `certThumbprint` — or a `.pfx` via `certPath` + optional
`certPasswordEnv`). The engine runs `Connect-MgGraph -Certificate` and mints the separate
Purview download token from the **same cert's private key** — there is no client secret and
no `.env` file. The plugin/skill does not authenticate; the PowerShell **engine** does, from
the config you hand it.

New machine checklist: the cert installed (store or `.pfx`), `Microsoft.Graph.Authentication`
module, and the app registration (`eDiscovery.ReadWrite.All` + eDiscovery Manager + download
resource). On the original GSI workstation this is already in place.

## Usage (standalone)

1. Copy the example config and fill it in:
   ```powershell
   Copy-Item config/ediscovery-export.example.json config/my-pull.json
   ```
2. **Phase 1 — estimate / scope gate** (builds case + sources + search, no export):
   ```powershell
   pwsh -File ./scripts/Invoke-EDiscoveryExport.ps1 -ConfigFile ./config/my-pull.json -EstimateOnly
   ```
   Review the reported mailbox count / item count / size.
3. **Phase 2 — fire the export (async)** — returns immediately with an operation id,
   an `export-state.json`, and the portal URL. Exports take 30 min to hours, so this does
   **not** block:
   ```powershell
   pwsh -File ./scripts/Invoke-EDiscoveryExport.ps1 -ConfigFile ./config/my-pull.json -Force
   ```
4. **Phase 3 — poll for the download** — run every ~15 min (Task Scheduler, a loop, or a
   Claude Code scheduled check). While running it just reports status; when the export
   succeeds it downloads the PST + report to `output.dir` and verifies:
   ```powershell
   pwsh -File ./scripts/Invoke-EDiscoveryExport.ps1 -ConfigFile ./config/my-pull.json -Resume
   ```
   (For small/known-fast exports, pass `-Wait` instead of `-Force` to block and download
   inline in one shot.)

The run is **idempotent** — re-running reuses the case, search, and data sources and only
adds what is missing.

## Usage (Claude Code plugin)

Add this repo as a local marketplace and install the plugin:

```
/plugin marketplace add C:/Users/sswanson/projects/ediscovery-export
/plugin install ediscovery-export@gsi-ediscovery
```

Then just ask, e.g. *"pull all emails containing 'outage request' from these 32
mailboxes between March and October 2022 and give me a single PST."* The skill handles
intake, builds the config, runs the estimate, confirms scope with you, then exports and
downloads.

## Config reference

See `config/ediscovery-export.example.json` (inline `$comment` fields). Highlights:

- `search.keywords` — each element is an OR'd KQL group; `["outage request"]` -> `(outage request)`.
  Set `search.contentQuery` to raw KQL to override keywords + dates.
- `export.singlePst` — `true` = one combined PST; `false` = one PST per mailbox (`splitSource`).
- `members` — UPNs to add as case members (portal visibility).
- `auth` — app-only cert values; `mode: interactive` for browser sign-in.

## Notes

- Export operations are asynchronous; multi-GB scopes take a while. Download URLs are
  single-user and valid **14 days**.
- Two tokens are involved: Graph (create/estimate/export) and a separate Purview
  eDiscovery resource token for the download. The engine handles both; MSAL.PS is
  intentionally avoided.
- See `docs/troubleshooting.md` for the common failure modes.
