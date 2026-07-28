# Purview eDiscovery (unified) Graph API contract

Canonical request shapes used by `Invoke-EDiscoveryExport.ps1`, **validated end-to-end
against the live tenant on 2026-07-02** (not just docs). All calls are
`Invoke-MgGraphRequest -OutputType PSObject` against `https://graph.microsoft.com`.
Namespace: `microsoft.graph.security`. Base: `/v1.0/security/cases/ediscoveryCases`.

> The model below is the one the Purview portal actually uses. An earlier attempt using
> **custodians** or search-level **additionalSources** failed: custodians don't bind for
> shared mailboxes (estimate returns 0), and a search cannot be created without a data
> source. The working model is **case-level noncustodial data sources + a scoped search**.

## 1. Create case
```
POST /security/cases/ediscoveryCases
{ "displayName": "<case name>", "description": "<desc>" }
```
To reuse, first `GET .../ediscoveryCases?$filter=displayName eq '<name>'`.
**Caveat:** app-only can only see/read cases the app itself created, even with
`eDiscovery.ReadWrite.All`. It cannot read a portal-created case it is not a member of.

## 2. Add case member (portal visibility) — APP-ONLY SUPPORTED
```
POST /security/cases/ediscoveryCases/{caseId}/caseMembers
{ "recipientType": "user", "smtpAddress": "admin@example.com" }
```
Bare body — do **not** send an `@odata.type` (it 400s "Invalid JSON format").
`recipientType` = `user` or `roleGroup`. The user must already be in the **eDiscovery
Manager** role group to actually see the case.

## 3. Add each mailbox as a CASE noncustodial data source (the correct model)
```
POST /security/cases/ediscoveryCases/{caseId}/noncustodialDataSources
{ "dataSource": { "@odata.type": "microsoft.graph.security.userSource", "email": "<smtp>" } }
```
Works for **user AND shared mailboxes** (the portal shows them as "People"/"Groups").
Response `status` becomes `active` and `displayName` resolves to the mailbox owner.
Idempotency: `GET .../noncustodialDataSources?$expand=dataSource` and compare `dataSource.email`.
(For a SharePoint site use `{ "@odata.type": "microsoft.graph.security.siteSource", "site": { "webUrl": "<url>" } }`.)

## 4. Create the search, scoped to the noncustodial sources
```
POST /security/cases/ediscoveryCases/{caseId}/searches
{ "displayName": "<name>", "contentQuery": "<KQL>",
  "dataSourceScopes": "allCaseNoncustodialDataSources" }
```
The scope binds every noncustodial source added in step 3 and satisfies the
"At least one data source is required" rule. Do **not** try to create an empty search or
pass sources inline — both 400. (To bind specific sources instead of the whole scope,
use `custodianSources@odata.bind` / `noncustodialSources@odata.bind` with source URLs.)

### 4a. `contentQuery` KQL reference (mailbox search)

`contentQuery` is Purview KeyQL. `Build-ContentQuery` assembles it from
`search.keywords` (each element becomes one parenthesised OR'd group) plus
`search.startDate`/`endDate`, or passes `search.contentQuery` through verbatim.

eDiscovery supports **only** the mailbox properties below. Other Exchange message
properties are rejected or silently ignored — notably there is **no `body:`
restriction**: body text is only reachable through bare keywords, which search the
subject, the body, and the participant properties together. Message headers are not
indexed and cannot be searched at all.

| Property | Matches | Example |
|----------|---------|---------|
| `participants` | Every people field — From, To, Cc, **and** Bcc. Accepts a bare domain. | `participants:jsmith@example.com`<br>`participants:example.com` |
| `recipients` | Recipient fields only — To, Cc, Bcc (**not** From). | `recipients:example.com` |
| `to` | The To field. | `to:"Jamie Rivera"` |
| `from` | The sender. | `from:jsmith@example.com` |
| `cc` | The Cc field. | `cc:jsmith@example.com` |
| `bcc` | The Bcc field. Only reliable when the sender's own mailbox is in scope. | `bcc:jsmith@example.com` |
| `subject` | Text **anywhere in** the subject line — substring, never an exact match. `subject:"Q1 Budget"` also hits "Q1 Budget Draft". | `subject:"Q1 Budget"` |
| `hasattachment` | `true` / `false`. | `from:jsmith@example.com AND hasattachment:true` |
| `attachmentnames` | Attached file names. Wildcards allowed. | `attachmentnames:invoice.pdf`<br>`attachmentnames:invoice*` |
| `kind` | Item type. Values: `contacts`, `docs`, `email`, `externaldata`, `faxes`, `im`, `journals`, `meetings`, `microsoftteams`, `notes`, `posts`, `rssfeeds`, `tasks`, `voicemail`. | `kind:email`<br>`kind:email OR kind:microsoftteams` |
| `sent` | Date the message was **sent**. Date-comparison operators apply. | `sent>=2026-01-01 AND sent<=2026-03-31` |
| `received` | Date the message was **received**. Date-comparison operators apply. | `received:2026-04-15` |
| `size` | Item size in bytes. Supports `>`, `<`, and the `..` range form. | `size>26214400`<br>`size:1..1048576` |
| `importance` | `high` / `medium` / `low`. | `importance:high` |
| `isread` | `true` / `false`. | `isread:false` |
| `category` | Outlook colour category. | `category:"Red Category"` |
| `itemclass` | Third-party data imported into mailboxes. | `itemclass:ipm.externaldata.Twitter*` |
| `sensitivetype` | Name of a sensitive information type. Never matches partially indexed items. | `sensitivetype:"Credit Card Number"` |

**Syntax notes**

- **Quoting.** Use straight double quotes for any multi-word value. `subject:budget Q1`
  binds only `budget` to the subject and free-text-searches `Q1`; `subject:"budget Q1"`
  is the phrase. Quotes also suppress wildcards and operators inside them. Smart/curly
  quotes are an error — type queries, don't paste them out of Word.
- **Bare terms are OR'd.** A space between two keywords, or between two `property:value`
  expressions, means **OR** in Purview eDiscovery — `from:"Jamie Rivera" subject:merger`
  returns messages from Jamie *or* messages about the merger. This is why each
  `search.keywords` element is wrapped in its own `( ... )` group. Do not mix bare spaces
  and explicit `OR` in one query; pick one. Boolean operators must be **UPPERCASE**.
- **No space after the colon.** `to: jsmith` searches `jsmith` as a free-text keyword
  rather than restricting the To field. Write `to:jsmith`.
- **Dates.** Use `yyyy-MM-dd` with a comparison operator and no space:
  `received>=2026-01-01 AND received<=2026-03-31`. A bare colon means that exact day
  (`received:2026-04-15`). Cover **both** `sent` and `received` — which one is populated
  depends on whether the item is in the sender's or the recipient's mailbox, which is why
  the builder emits `(received>=.. AND received<=..) OR (sent>=.. AND sent<=..)`.
- **Wildcards.** Trailing asterisk only (`invoice*`). Leading (`*invoice`), embedded
  (`in*ce`), and enclosing (`*invoice*`) wildcards are unsupported.
- **Negation.** Prefix with `-` or `NOT`: `-from:"Jamie Rivera"`.
- **Empty properties are unsearchable.** `subject:""` returns zero results; there is no
  way to query "field is blank".
- **Recipient expansion.** Any recipient property (`from`, `to`, `cc`, `bcc`,
  `participants`, `recipients`) is expanded via Entra ID to the user's SMTP/UPN, alias,
  display name, and LegacyExchangeDN — so `participants:jsmith@example.com` quietly
  becomes an OR of all four. It does **not** work for users whose Entra object was
  deleted; list their old addresses manually. To suppress expansion, truncate the domain
  and add a trailing wildcard inside quotes: `participants:"jsmith@exampl*"`.

## 5. Estimate statistics (scope gate)
```
POST /security/cases/ediscoveryCases/{caseId}/searches/{searchId}/estimateStatistics
{ "statisticsOptions": "includeQueryStats" }
```
202 + `Location` header -> an operation URL. Poll:
`GET .../operations/{opId}` -> read `status`, `mailboxCount`, `indexedItemCount`, `indexedItemsSize`.
Gate: proceed only when `indexedItemCount > 0`.

## 6. Export results (asynchronous)
```
POST /security/cases/ediscoveryCases/{caseId}/searches/{searchId}/exportResult
{ "displayName": "<export name>",
  "exportCriteria": "searchHits",            // or "searchHits, partiallyIndexed"
  "exportLocation": "responsiveLocations",   // or add ", nonresponsiveLocations"
  "additionalOptions": "includeReport",      // add "splitSource" for per-mailbox PSTs
  "exportFormat": "pst" }                      // "pst" or "msg" (eml deprecated)
```
Required: `exportCriteria`, `exportFormat`. 202 + `Location` operation. **Exports take
30 min to hours** — do not block; record the operation id and poll later.

## 7. Read export result files
When `GET .../operations/{opId}` has `status` = `succeeded`/`partiallySucceeded`, the
operation (`@odata.type = #microsoft.graph.security.ediscoverySearchExportOperation`)
carries `exportFileMetadata`: an array of `{ fileName, downloadUrl, size }`. Expect two
entries: a `PSTs.NNN.*.zip` data package and a `Reports-*.zip`. If empty on success,
re-GET (metadata lags a few seconds). **Use `-OutputType PSObject`** or the response is a
hashtable and `.PSObject.Properties` checks silently fail.

## 8. Download the package (SEPARATE resource token)
The download endpoint is the **Purview eDiscovery API**, not Graph, so it needs its own
token — resource `b26e684c-5068-4120-a679-64a5d2c909d9` (`.../.default`) — plus the
header `X-AllowWithAADToken: true`:
```
GET <downloadUrl>
Authorization: Bearer <purview-ediscovery-token>
X-AllowWithAADToken: true
```
Minted via an inline cert client-assertion JWT (no MSAL.PS). `downloadUrl` links are
single-user and valid **14 days**.

## Portal export page (monitor / manual download)
```
https://purview.microsoft.com/ediscovery/casespage/{caseId}?tid={tenantId}&casename={urlencoded name}&viewid=Exports
```

## Summary.csv verification
DirectExport report: line `"Indexed items","142","..."`. GenerateStatistics report:
`"ItemCount","2385"`. Parse either.

## Permissions
App-only: `eDiscovery.ReadWrite.All` + the download resource above; the app must be an
eDiscovery Manager. Delegated callers need eDiscovery Manager (own cases) / Administrator
(all cases).

## Gotchas carried forward
- Classic `New-ComplianceSearch -Export` is retired in the cloud (2025-05-26). Graph only.
- Custodians (esp. shared mailboxes) silently bind to nothing -> use noncustodial sources.
- A search cannot be created without a data source; scope to `allCaseNoncustodialDataSources`.
- `Invoke-MgGraphRequest` returns hashtables unless you pass `-OutputType PSObject`.
- Two tokens: Graph (create/estimate/export) + Purview eDiscovery (download).
- App-only sees only cases it created.
