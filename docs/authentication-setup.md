# Authentication & setup

The engine authenticates to Microsoft Graph with **certificate-based app-only auth** — a
service-principal + certificate, driven entirely by the `auth` block of your config file.
**There is no client secret and no `.env` file.** The plugin/skill never authenticates; the
PowerShell **engine** does, using the config you hand it.

Two tokens are involved (the engine handles both):
1. **Graph** — for the case/search/estimate/export calls (`https://graph.microsoft.com`).
2. **Purview eDiscovery download resource** — a *different* audience, minted from the same
   certificate's private key as an inline client-assertion JWT, used only for downloading
   the export packages (`X-AllowWithAADToken: true`).

---

## The `auth` config block

```json
"auth": {
  "mode": "app-only",
  "appId": "<entra app (client) id>",
  "tenantId": "<entra tenant id>",
  "certThumbprint": "<cert thumbprint in the store>",
  "certPath": null,
  "certPasswordEnv": null,
  "downloadResourceAppId": "b26e684c-5068-4120-a679-64a5d2c909d9"
}
```

| Field | Meaning |
|-------|---------|
| `mode` | `app-only` (cert, unattended) or `interactive` (browser sign-in; download then needs the portal). |
| `appId` / `tenantId` | Your Entra app registration (client) ID and tenant ID. |
| `certThumbprint` | Thumbprint of a cert **with private key** in `Cert:\CurrentUser\My` (or `LocalMachine\My`). |
| `certPath` | Alternative to the store: path to a `.pfx`. Takes precedence over `certThumbprint` when set. |
| `certPasswordEnv` | Name of an environment variable holding the `.pfx` password (only if `certPath` is a protected pfx). |
| `downloadResourceAppId` | Microsoft's first-party Purview eDiscovery download resource. **Same GUID for every tenant** — leave as-is. |

Secrets are never stored in the repo. Real configs live outside version control — `.gitignore`
tracks only `config/*.example.json`, so a `config/my-pull.json` you create is ignored.

---

## New-machine / new-tenant setup

### 1. Entra app registration

Create (or reuse) an app registration and grant it these **application** Graph permissions
(admin consent required):

- `eDiscovery.ReadWrite.All`

That single permission covers case/search/export. The download uses the Microsoft first-party
resource `b26e684c-...` via the same app identity — no extra Graph permission, but the app must
be able to request a token for that resource (it can, as a confidential client with the cert).

### 2. Certificate

App-only auth uses a certificate, not a secret (the download-token JWT needs the private key,
which a client secret cannot provide).

1. Obtain/create a certificate (self-signed is fine for automation):
   ```powershell
   $cert = New-SelfSignedCertificate -Subject "CN=EDiscoveryExport" `
     -CertStoreLocation "Cert:\CurrentUser\My" -KeyExportPolicy Exportable `
     -KeySpec Signature -NotAfter (Get-Date).AddYears(2)
   $cert.Thumbprint   # -> put this in auth.certThumbprint
   ```
2. Upload the **public** key to the app registration (Certificates & secrets -> Certificates):
   ```powershell
   Export-Certificate -Cert $cert -FilePath .\EDiscoveryExport.cer   # public only; upload this
   ```
3. Keep the **private** key available where the engine runs — either in the cert store (as
   above) or as a `.pfx` referenced by `auth.certPath` (+ `auth.certPasswordEnv` for its
   password). Never commit the `.pfx`.

### 3. Purview eDiscovery role

The service principal must be able to manage eDiscovery cases. In the Microsoft Purview portal
-> **Settings -> Roles & scopes -> Role groups**, add the app (or a group it belongs to) to the
**eDiscovery Manager** role group. Any human UPN you list under `members` (for portal
visibility) must **also** be in that role group — adding a case member does not grant the role.

### 4. PowerShell prerequisites

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
```
PowerShell 7+ is required (`#Requires -Version 7.0`).

### 5. Fill the config and test

```powershell
Copy-Item config/ediscovery-export.example.json config/my-pull.json   # gitignored
# edit case/keywords/mailboxes/dates + the auth block
pwsh -File ./scripts/Invoke-EDiscoveryExport.ps1 -ConfigFile ./config/my-pull.json -EstimateOnly
```
A successful connect prints `Connected: AppOnly`. If it prints anything else, see below.

---

## Auth troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `Connected:` is not `AppOnly` | Cert not resolvable — check `Get-ChildItem Cert:\CurrentUser\My\<thumb>`, or set `auth.certPath` to a `.pfx`. |
| `Certificate ... not found` | Thumbprint wrong, or private key only in `LocalMachine` (run elevated) — the engine checks both stores. |
| `403` on case/search/export | App missing `eDiscovery.ReadWrite.All` (with admin consent) or not in the eDiscovery Manager role group. |
| `401` on download | The download uses the separate resource `b26e684c-...` + `X-AllowWithAADToken: true`. Ensure the app can mint that token (confidential client w/ cert). With `-Interactive` there is no cert token — use `-SkipDownload` and pull from the portal. |
| Case not visible in portal | Add the human UPN under `members` **and** ensure they're in the eDiscovery Manager role group. App-only sees only cases it created. |
| `MSAL.PS` / PackageManagement errors | Not used — the engine mints the download token with pure .NET RSA signing on purpose. |
