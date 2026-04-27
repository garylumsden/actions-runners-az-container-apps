using './main.bicep'

// ── Required — fill before deploying ─────────────────────────────────────────

// Numeric GitHub App ID (visible on your app's settings page)
param githubAppId = ''

// Numeric installation ID (last segment of the URL at
//   https://github.com/settings/installations/<id>  (user installs)  or
//   https://github.com/organizations/<your-org>/settings/installations/<id>  (org installs))
param githubInstallationId = ''

// Base64-encoded PEM private key. Generate with:
//   $bytes = [IO.File]::ReadAllBytes('private-key.pem')
//   [Convert]::ToBase64String($bytes) | Set-Clipboard
param githubAppPemB64 = ''

// ── Naming and location — change to match your environment ───────────────────

// Short prefix used in every resource name (e.g. 'contoso', 'myteam'). Lowercase alphanumerics.
param namingPrefix = 'yourprefix'

// Your GitHub owner — an organisation name or a personal user name.
param githubOwner = 'your-org-or-user'

// Runner scope.
//   'org'  -> runners register to the organisation; all repos in the org can target them.
//            (Organisations only — not available on personal accounts.)
//   'repo' -> runners register to a single repository; use on personal accounts or when you
//            want repo-scoped isolation. Set githubRepo below.
param runnerScope = 'org'

// Repository name (owner excluded). Required only when runnerScope = 'repo'. Leave '' for org scope.
param githubRepo = ''

// Azure region — Sweden Central is the cheapest ACA tier ($0.000024/vCPU·s)
param location = 'swedencentral'

// Short suffix appended to resource names to identify the region (e.g. 'swc', 'ne', 'weu').
// Must match the AZURE_LOCATION variable suffix used in deploy.yml / setup-oidc.ps1.
param locationAbbreviation = 'swc'

// ── Optional capacity overrides ───────────────────────────────────────────────
param linuxMaxExecutions = 10
param windowsMaxExecutions = 10

// Azure region for Windows ACI runners (must support Windows ACI).
// Sweden Central only supports Linux ACI; West Europe is the nearest Windows-capable region.
param windowsAciLocation = 'westeurope'
