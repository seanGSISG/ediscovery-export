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

## Step 0 — Find or create the tenant profile

`config/ediscovery-export.example.json` is a **sanitized public template**: placeholder
`auth`, no local conventions. Never start a real matter from it if a tenant profile exists,
and never hand-write an `auth` block from memory.

A **tenant profile** holds what is the same for every matter in one tenant — the app-only
auth block, the standing `members`, and the house export defaults — so a matter config
carries only `case` / `search` / `mailboxes` / `output`, and a certificate rotation touches
one file instead of every config ever written.

### Does one already exist?

Resolution order (`Resolve-EDTenantProfilePath`), first hit wins:

1. `$env:EDISCOVERY_TENANT_PROFILE` — the per-admin override
2. `config/ediscovery-tenant-profile.json` in the config's directory or **any parent** —
   the repo-level profile, for a team sharing a repo
3. `~/.claude/ediscovery/tenant-profile.json` — the per-user default, needs no repo

Also read `exports/**/config-*.json` if present: prior matters are the best reference for
that tenant's query idiom and naming.

### If none exists, generate it — do not hand-write it

```
pwsh -File "${CLAUDE_PLUGIN_ROOT}/scripts/New-EDTenantProfile.ps1"
```

Prompts for app id, tenant id, certificate thumbprint and case members; **resolves the
certificate, acquires a real app-only token, and verifies that a matter config extending
the profile merges to a complete run config** before it reports success. A profile that
does not authenticate is worse than none, so this fails at setup rather than mid-collection.

Defaults to the per-user path, which is the right choice when admins do not share a folder
layout. Pass `-Path ./config/ediscovery-tenant-profile.json` for a repo-level profile a
team version-controls together.

### Reference it portably

In the matter config write the **sentinel**, not a machine-specific path:

```json
"extends": "tenant-profile"
```

It resolves through the order above, so the same matter config works on any admin's
machine. A literal relative or absolute path also works (with `%VARS%` / `${VARS}`
expanded) when you deliberately want to pin one file.

> A tenant profile is **not** a secret store — app id, tenant id and a certificate
> thumbprint, no private key or client secret. It is still tenant-identifying: keep it out
> of any repository you publish or share as a plugin marketplace. Each tenant generates its
> own.

> Adopting a profile does **not** relax the gates below. Identity resolution, the estimate
> gate, and one-output-directory-per-export still apply.

## Step 1 — Intake and build the config

Collect: **keywords**, the **mailbox list** (SMTP; expand every domain the person holds),
the **date range**, **export format**, and who should **see the case** in the portal.

**Ask for the export format when the request does not state one.** PST is the config
default, but for a small collection (roughly < 100 items) loose `.msg` files are usually
more useful than a PST the requester has to mount. Do not let the default stand silently
on a small result — surface it at the estimate gate.

### MSG exports must use friendly names

Purview names exported `.msg` files by **GUID** unless the `friendlyName` export option is
set — `c5e1aeb0d5e24a92.msg` rather than `RE Safari Electric invoice.msg`. A GUID-named
package is unusable to a requester without cross-referencing `Items.csv` in the report zip,
which is not a deliverable anyone wants to receive.

The engine therefore defaults `export.friendlyNames` **on for `msg`** and off for `pst`
(PST keeps subjects inside the file regardless, and Microsoft documents the option as
having no effect there). Leave it `null` unless you have a reason. Set it to `false` only
when GUID names are wanted deliberately — e.g. a downstream tool keys on them, or subjects
would collide.

If a `.msg` package has already been produced with GUID names, re-exporting with the option
set is cheap: the case and search already exist, so only the export operation re-runs.
Send it to a **new** `output.dir` — never reuse the first export's directory.

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

### Query recipes

`mailboxes` sets **whose** mail is searched; the query sets **which** messages. Keep the
two jobs separate — the most common error is trying to express "between A and B" purely
through the mailbox list.

Each recipe below goes in a single `search.keywords` element, with `startDate`/`endDate`
set so the engine builds both date halves. Elements of `keywords` are OR'd together, so an
`AND` **inside** one element is how you require two conditions.

| Ask | `keywords` element | Notes |
|-----|--------------------|-------|
| Correspondence between an internal person and an external party | `participants:"jane@vendor.com"` | Scope `mailboxes` to the internal person; the **external** address is the discriminator. `participants` covers From, To, Cc **and** Bcc, so it catches both directions in one clause. |
| ...restricted to messages carrying attachments | `participants:"jane@vendor.com" AND hasattachment:true` | Also drops the attachment-free replies in those threads — see the denominator check in Step 2a. |
| Anyone at an external organisation | `participants:"vendor.com"` | Bare domain is legal. Good ceiling check when a named-address query looks too small. |
| Topic keywords | `"widget recall"` | Quote to force a phrase; unquoted words are AND-ed by the index. |
| Topic **and** a named party | `("widget recall" OR "recall notice") AND participants:"jane@vendor.com"` | |
| Internal-only traffic, external noise removed | `"widget recall" AND NOT participants:"vendor.com"` | Useful as a delta against a broader run. |

Two traps worth knowing (full detail in `references/api-contract.md`):

- A recipient property is **expanded through Entra ID** to the user's SMTP, alias, display
  name and LegacyExchangeDN, so `participants:"jane@vendor.com"` matches more forms than
  the literal string. That is usually what you want.
- Because `participants` spans Bcc, a hit does not prove the address was visible on the
  message. Do not describe results as "sent to X" without checking the message.

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
- Mailboxes: <mailboxCount> with hits, of <N> bound
- Items: <indexedItemCount>   Size: ~<sizeGB> GB
- Format: <pst|msg>, <single | per-mailbox>   <- state it; offer msg if the count is small

Proceed with the export? (yes/no)
```

**Never proceed without explicit confirmation.** If items = 0, stop and investigate — do
not pass `-Force` to bypass a zero result unless the user insists.

### Two different mailbox counts — do not confuse them

The run header prints `Mailboxes: N` (**bound** to the case as data sources). The estimate
prints `mailboxes=M` (**how many of them had hits**). `M < N` is normal and expected — it
just means some custodians never touched the topic.

`M < N` is only a red flag **when comparing two variants of the same query**: if the
broader variant hit 2 mailboxes and the narrower hit 1, the narrower one may be dropping a
domain rather than legitimately narrowing. In isolation, a low `M` is information, not a
fault.

## Step 2a — Breadth triage (only when the request is ambiguous, or the estimate looks wrong)

**Triage is a diagnostic tool, not a mandatory stage.** Most tickets do not need it, and
running three variants on a precisely-worded request wastes time and buries the answer the
requester actually asked for.

### Decide first: one search, or variants?

**Run the single requested search** when the ticket is *transcribable* — you can write the
query directly from its words with no guessing:

- named parties on both sides (or a named party plus a named mailbox), **and**
- an explicit date range, **and**
- an explicit content filter (attachments, a quoted phrase, a document number) or no
  content filter wanted at all.

> "Emails between Bailey and breana.hall@vendor.com, 09/01/23–12/01/23, with attachments"
> is transcribable. Build it, estimate it, confirm it, export it. Do not generate variants.

**Run breadth triage** when any of these hold:

- the subject is described in prose ("anything about the transformer issue") and the
  keywords are your guesses rather than the requester's words;
- the party list is partial ("Bailey and a few people at the vendor");
- competing readings would produce materially different deliverables;
- **or the first estimate came back suspicious** — 0 items, an implausibly large count, or
  coverage that dropped a mailbox you expected to hit.

That last case is the most valuable one: triage earns its keep as a *reaction to a bad
estimate*, not as a ritual before a good one.

### Optional: the denominator check

Even in single-search mode, when the requested query includes a narrowing filter
(`hasattachment:true`, an extra keyword), **one** extra estimate without that filter is
often worth running. It costs one non-destructive call and tells the requester what the
filter excluded — "38 of the 44 messages carry attachments; the other 6 are replies in the
same threads." That is a sentence they can act on.

This is one extra estimate, not a variant set. Do not export it unless asked.

### Running a variant set

Estimates are non-destructive and repeatable, and `Get-OrCreate-Case` matches an existing
case by `displayName` — data sources are added at the **case** level, so several configs
sharing one case name reuse the same case and the same mailbox bindings (the engine
reports `0 added, N already present`). That makes A/B-ing a query's breadth cheap.

1. Build 2-4 configs sharing `case.name` and `mailboxes`, differing **only** in
   `search.name` and the query.
2. Run each with `-EstimateOnly`.
3. Compare **item count** *and* **mailboxes with hits** across variants.
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

**Preferred: run the shipped watcher in the background** — it polls `-Resume` on an
interval and exits as soon as the package lands, so nothing has to babysit it:

```
pwsh -File "${CLAUDE_PLUGIN_ROOT}/scripts/Watch-EDiscoveryExport.ps1" \
  -ConfigFile "<config>.json" -NotifyTo sswanson@gsisg.com
```

Defaults to a 15-minute interval and gives up after ~8 hours (`-IntervalSeconds`,
`-MaxPolls`). It stops on the on-disk result, so an export you finish from the portal
also ends the watch. `-NotifyTo` emails the outcome (landed or gave up) from the
AgentMail inbox (`-NotifyInbox`, default `lsdmt@agentmail.to`) using
`AGENTMAIL_API_KEY`; omit it and the watcher sends nothing. Pass it by default when the
user will not be at the session when the export finishes. An agent should start this as a **background task** and report when
it exits — do not hand-roll a polling loop, and do not sit in a foreground wait.

`/loop 15m` running the `-Resume` command works too, but `/loop` is user-invoked — an
agent cannot start one for itself. Outside Claude Code, a Windows Scheduled Task running
`-Resume` every 15 min is the equivalent (see `docs/runbook.md`).

When files land, report: `exportStatus`, each file name + size, `verifiedItemCount`, the
output directory, and the portal URL. Download URLs are valid 14 days.

## Parameter reference

| Flag | When to pass |
|------|--------------|
| `-EstimateOnly` | Step 2. Builds everything, stops before export. Also the denominator check and any triage variant. |
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
- Tenant profile generator: `scripts/New-EDTenantProfile.ps1`
- Download watcher: `scripts/Watch-EDiscoveryExport.ps1`
- Helpers: `scripts/_lib/EDiscovery.psm1`
- Config template: `config/ediscovery-export.example.json` (see Step 0 — prefer a tenant
  profile if the repo has one)
- API contract (validated request bodies): `references/api-contract.md`
- Runbook: `docs/runbook.md`
