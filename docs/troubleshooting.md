# Troubleshooting

## Estimate returns 0 items / 0 mailboxes, but the mailboxes clearly have mail

**Cause:** the mailboxes were added as **custodians** instead of **noncustodial data
sources**. Shared mailboxes do not bind as custodians, so `allCaseCustodians` resolves to
nothing and the estimate is a silent empty success. This engine avoids that by POSTing
each mailbox to `.../noncustodialDataSources` and scoping the search to
`allCaseNoncustodialDataSources`. If you extended the engine, confirm that is what it does.

## Export operation says `succeeded` but the PST is empty

Same root cause as above, or you exported before the estimate confirmed a non-zero
count. Always run the `-EstimateOnly` phase first and check `indexedItemCount > 0`.

## Case is not visible in the Purview portal

The case was created app-only, so it has no human members. Add the user via
`members` in the config (the engine POSTs `caseMembers`). **The user must already be in
the eDiscovery Manager role group** — adding a case member does not grant that role. As
a fallback, an eDiscovery **Administrator** can see all cases.

## Download fails with 401 / 403

The download endpoint is a **separate resource** from Graph. It needs its own token
(resource `b26e684c-5068-4120-a679-64a5d2c909d9`) and the header
`X-AllowWithAADToken: true`. Verify the app has access to that resource. If cert auth
is unavailable (e.g. `-Interactive`), the engine cannot mint the download token — use
`-SkipDownload` and pull the package from the portal.

## `Connect-MgGraph` succeeds but `AuthType` is not `AppOnly`

You likely fell back to interactive/delegated. Check the cert is resolvable by
thumbprint in the store (`Get-ChildItem Cert:\CurrentUser\My\<thumb>`), or set
`auth.certPath` to a `.pfx`.

## 500 on `POST ediscoveryCases`

A **classic** (non-unified) eDiscovery/compliance case with the same name exists — the
namespaces collide. Rename the case, or delete the classic one.

## "At least one data source is required" on search create

A search cannot be created empty, and inline sources are ignored. Add the mailboxes as
**case noncustodial data sources first**, then create the search with
`dataSourceScopes: "allCaseNoncustodialDataSources"` (the engine does this in order).

## Export op is `succeeded` but "0 file(s)" / "property 'fileName' cannot be found"

`Invoke-MgGraphRequest` returns hashtables by default, so `.PSObject.Properties` checks on
`exportFileMetadata` silently fail. Call it with `-OutputType PSObject` (the engine does).
Also note `exportFileMetadata` can lag a few seconds after `succeeded` — re-GET the op.

## Export is huge / slow

Set `export.singlePst: false` to split into per-mailbox PSTs, narrow the date range, or
reduce the mailbox list. Download URLs remain valid 14 days, so you can also
`-SkipDownload` and fetch from the portal when convenient.
