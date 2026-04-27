#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Interactive guide to create a GitHub App for self-hosted runner authentication,
    and upload the private key to a local base64 variable ready for GitHub Actions.

.DESCRIPTION
    GitHub App authentication replaces PATs:
      ✅ No expiry issues (JWTs are short-lived, generated at runtime)
      ✅ Scoped to your owner only (organisation or user)
      ✅ Auditable in GitHub's security log

    SCOPE
    ─────
    The runners can register at either org or repo scope:

      • org  (recommended) — requires a GitHub organisation. Runners are
        available to every repository in the org (subject to runner groups).
        Permissions required:
          Organisation → Actions: Read, Self-hosted runners: R/W, Administration: R/W

      • repo — a single repository. Works on personal GitHub accounts where
        organisation-scoped runners are not available. Must be repeated per
        target repo.
        Permissions required:
          Repository   → Administration: R/W, Actions: R, Metadata: R

    WHERE TO RUN
    ────────────
    Run this script locally (interactive). It does NOT need Azure CLI.
    The base64 PEM it outputs goes into GitHub Actions Secrets.

.EXAMPLE
    ./scripts/setup-github-app.ps1
    ./scripts/setup-github-app.ps1 -PemPath 'C:\Downloads\private-key.pem'
    ./scripts/setup-github-app.ps1 -Scope repo -GitHubOwner alice -GitHubRepo mywebapp
#>
param(
    [string] $PemPath,
    [Alias('GitHubOrg')]
    [string] $GitHubOwner,
    [ValidateSet('org', 'repo')]
    [string] $Scope,
    [string] $GitHubRepo
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Auto-detect owner from git remote if not provided
if (-not $GitHubOwner) {
    $remote = git remote get-url origin 2>$null
    if ($remote -match 'github\.com[/:]([^/]+)/') {
        $GitHubOwner = $Matches[1]
        Write-Host "  Detected GitHub owner: $GitHubOwner" -ForegroundColor DarkGray
    } else {
        $GitHubOwner = Read-Host '  GitHub owner (organisation or user)'
    }
}

# Auto-detect source repo name from git remote (used for naming the GitHub App itself)
$SourceRepoName = 'actions-runners-az-container-apps'
$remote = git remote get-url origin 2>$null
if ($remote -match 'github\.com[/:]([^/]+)/([^/.]+?)(?:\.git)?$') {
    $SourceRepoName = $Matches[2]
}

# Ask for scope if not supplied
if (-not $Scope) {
    Write-Host ''
    Write-Host 'Which scope should these runners register at?' -ForegroundColor Yellow
    Write-Host '  [O] org   — available to every repo in a GitHub organisation (recommended)'
    Write-Host '  [R] repo  — single repository (required for personal GitHub accounts)'
    $scopeChoice = Read-Host '  Choose [O/R] (default O)'
    $Scope = if ($scopeChoice -match '^[Rr]') { 'repo' } else { 'org' }
}

if ($Scope -eq 'repo' -and -not $GitHubRepo) {
    $defaultRepo = if ($SourceRepoName -and $SourceRepoName -ne 'actions-runners-az-container-apps') { $SourceRepoName } else { '' }
    $prompt = if ($defaultRepo) { "  Target repository name [$defaultRepo]" } else { '  Target repository name (no owner)' }
    $GitHubRepo = Read-Host $prompt
    if (-not $GitHubRepo) { $GitHubRepo = $defaultRepo }
    if (-not $GitHubRepo) { throw 'A repository name is required when Scope = repo.' }
}

# Target spec for display
$targetSpec = if ($Scope -eq 'org') { $GitHubOwner } else { "$GitHubOwner/$GitHubRepo" }

Write-Host ''
Write-Host '════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host '  GitHub App Setup for Self-Hosted Runners' -ForegroundColor Cyan
Write-Host '════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''
Write-Host ("  Scope : {0}" -f $Scope)  -ForegroundColor DarkGray
Write-Host ("  Target: {0}" -f $targetSpec) -ForegroundColor DarkGray
Write-Host ''
Write-Host 'STEP 1 — Create the GitHub App' -ForegroundColor Yellow
Write-Host ''
if ($Scope -eq 'org') {
    Write-Host "  1. Open: https://github.com/organizations/$GitHubOwner/settings/apps/new"
} else {
    Write-Host "  1. Open: https://github.com/settings/apps/new"
}
Write-Host '  2. Fill in:'
Write-Host "       GitHub App name : $SourceRepoName-$Scope"
if ($Scope -eq 'org') {
    Write-Host "       Homepage URL    : https://github.com/$GitHubOwner"
} else {
    Write-Host "       Homepage URL    : https://github.com/$GitHubOwner/$GitHubRepo"
}
Write-Host '       Webhook         : ☐ Uncheck "Active" (not needed)'
Write-Host ''
if ($Scope -eq 'org') {
    Write-Host '  3. Set ORGANISATION permissions:'
    Write-Host '       Actions             : Read              (KEDA uses this to query queued workflow runs)'
    Write-Host '       Self-hosted runners : Read and write'
    Write-Host '       Administration      : Read and write'
} else {
    Write-Host '  3. Set REPOSITORY permissions:'
    Write-Host '       Administration      : Read and write   (needed to register runners on the repo)'
    Write-Host '       Actions             : Read              (KEDA uses this to query queued workflow runs)'
    Write-Host '       Metadata            : Read              (auto-selected)'
}
Write-Host ''
Write-Host '  4. Set "Where can this GitHub App be installed?" to "Only on this account"'
Write-Host '  5. Click "Create GitHub App"'
Write-Host ''
Read-Host '  Press Enter once the App is created'

Write-Host ''
Write-Host 'STEP 2 — Get the App ID' -ForegroundColor Yellow
Write-Host ''
Write-Host '  On the App settings page you will see "App ID: XXXXXX"'
Write-Host '  Copy it below.'
do {
    $AppId = (Read-Host '  GitHub App ID').Trim()
    if ($AppId -notmatch '^\d+$') {
        Write-Host "  ⚠️  App ID must be a positive integer (digits only). Please try again." -ForegroundColor Yellow
    }
} while ($AppId -notmatch '^\d+$')

Write-Host ''
Write-Host ("STEP 3 — Install the App on {0}" -f $targetSpec) -ForegroundColor Yellow
Write-Host ''
Write-Host "  1. On the App settings page click 'Install App'"
if ($Scope -eq 'org') {
    Write-Host "  2. Choose the '$GitHubOwner' organisation"
    Write-Host '  3. Select "All repositories" (or specific repos)'
    Write-Host '  4. After installation, the URL will contain the installation ID:'
    Write-Host "       https://github.com/organizations/$GitHubOwner/settings/installations/<INSTALLATION_ID>"
} else {
    Write-Host "  2. Choose your user account ($GitHubOwner)"
    Write-Host "  3. Select 'Only select repositories' and pick: $GitHubRepo"
    Write-Host '  4. After installation, the URL will contain the installation ID:'
    Write-Host "       https://github.com/settings/installations/<INSTALLATION_ID>"
}
Write-Host '  Copy that number below.'
do {
    $InstallationId = (Read-Host '  Installation ID').Trim()
    if ($InstallationId -notmatch '^\d+$') {
        Write-Host "  ⚠️  Installation ID must be a positive integer (digits only). Please try again." -ForegroundColor Yellow
    }
} while ($InstallationId -notmatch '^\d+$')

Write-Host ''
Write-Host 'STEP 4 — Generate a private key' -ForegroundColor Yellow
Write-Host ''
Write-Host '  On the App settings page, scroll to "Private keys" and click'
Write-Host '  "Generate a private key". A .pem file will download.'

if (-not $PemPath) {
    $PemPath = Read-Host '  Path to the downloaded .pem file'
}
$PemPath = $PemPath.Trim('"').Trim("'")

if (-not (Test-Path -LiteralPath $PemPath)) {
    throw "File not found: $PemPath"
}

# ── Validate PEM before encoding ─────────────────────────────────────────────
# Catch malformed / wrong-file / empty-content problems here at setup time
# rather than at runtime inside the runner container, where the failure is a
# cryptic 'unable to load Private Key' far from the misconfiguration.
$pemText = Get-Content -Raw -LiteralPath $PemPath
if ([string]::IsNullOrWhiteSpace($pemText)) {
    throw "PEM file is empty: $PemPath"
}

$hasRsaHeader  = $pemText.Contains('-----BEGIN RSA PRIVATE KEY-----') -and $pemText.Contains('-----END RSA PRIVATE KEY-----')
$hasPkcs8Header = $pemText.Contains('-----BEGIN PRIVATE KEY-----')     -and $pemText.Contains('-----END PRIVATE KEY-----')
if (-not ($hasRsaHeader -or $hasPkcs8Header)) {
    throw "PEM file does not contain a recognised private-key header. Expected '-----BEGIN RSA PRIVATE KEY-----' or '-----BEGIN PRIVATE KEY-----'. Path: $PemPath"
}

# Parse the key to confirm it is actually a usable RSA private key. This uses
# .NET 5+ RSA.ImportFromPem which handles both PKCS#1 (RSA PRIVATE KEY) and
# PKCS#8 (PRIVATE KEY). Runs in PowerShell 7 / .NET 6+.
try {
    $rsa = [System.Security.Cryptography.RSA]::Create()
    $rsa.ImportFromPem($pemText.ToCharArray())
    $keySize = $rsa.KeySize
    $rsa.Dispose()
} catch {
    throw "PEM file failed RSA parse ('$($_.Exception.Message)'). The file at '$PemPath' is not a valid RSA private key."
}
Write-Host "  ✅ PEM validated (RSA $keySize-bit)." -ForegroundColor Green

$bytes  = [IO.File]::ReadAllBytes($PemPath)
$pemB64 = [Convert]::ToBase64String($bytes)

Write-Host ''
Write-Host '════════════════════════════════════════════════════════' -ForegroundColor Green
Write-Host '  GitHub App setup complete!' -ForegroundColor Green
Write-Host '════════════════════════════════════════════════════════' -ForegroundColor Green
Write-Host ''

# ── Set variables and secret automatically via gh CLI ─────────────────────────
# We require gh CLI. The previous fallback printed the base64 PEM to the
# terminal, which leaks the secret into scrollback/transcripts.
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Error "GitHub CLI ('gh') is required to set the secret securely. Install from https://cli.github.com and re-run."
    exit 1
}

if ($Scope -eq 'org') {
    Write-Host 'Ensuring gh CLI has admin:org scope (a browser window may open)...' -ForegroundColor Cyan
    gh auth refresh -h github.com -s admin:org
    if ($LASTEXITCODE -ne 0) { throw 'gh auth refresh failed. Re-run after logging in.' }

    Write-Host 'Setting organisation variables and secret...' -ForegroundColor Cyan

    gh variable set GH_APP_ID --body $AppId --org $GitHubOwner --visibility all
    if ($LASTEXITCODE -ne 0) { throw 'Failed to set GH_APP_ID.' }
    Write-Host '  ✅ GH_APP_ID set.'

    gh variable set GH_INSTALLATION_ID --body $InstallationId --org $GitHubOwner --visibility all
    if ($LASTEXITCODE -ne 0) { throw 'Failed to set GH_INSTALLATION_ID.' }
    Write-Host '  ✅ GH_INSTALLATION_ID set.'

    # Pipe base64 PEM via stdin so it never appears in argv/process list.
    # gh secret set reads from stdin when --body is omitted.
    $pemB64 | gh secret set GH_APP_PEM_B64 --org $GitHubOwner --visibility all
    if ($LASTEXITCODE -ne 0) { throw 'Failed to set GH_APP_PEM_B64.' }
    Write-Host '  ✅ GH_APP_PEM_B64 set as org secret.'
} else {
    # Repo scope: write variables and secret directly to the single target repo.
    # admin:org is not needed; default gh auth scopes are sufficient.
    $repoSpec = "$GitHubOwner/$GitHubRepo"
    Write-Host "Setting repository variables and secret on $repoSpec..." -ForegroundColor Cyan

    gh variable set GH_APP_ID --body $AppId --repo $repoSpec
    if ($LASTEXITCODE -ne 0) { throw 'Failed to set GH_APP_ID.' }
    Write-Host '  ✅ GH_APP_ID set.'

    gh variable set GH_INSTALLATION_ID --body $InstallationId --repo $repoSpec
    if ($LASTEXITCODE -ne 0) { throw 'Failed to set GH_INSTALLATION_ID.' }
    Write-Host '  ✅ GH_INSTALLATION_ID set.'

    $pemB64 | gh secret set GH_APP_PEM_B64 --repo $repoSpec
    if ($LASTEXITCODE -ne 0) { throw 'Failed to set GH_APP_PEM_B64.' }
    Write-Host '  ✅ GH_APP_PEM_B64 set as repo secret.'
}

Write-Host ''
Write-Host 'SECURITY REMINDER' -ForegroundColor Yellow
Write-Host '  Delete the downloaded .pem file — it is now stored as a GitHub secret.'
Write-Host '  GitHub App private keys can be revoked at:'
if ($Scope -eq 'org') {
    Write-Host "  https://github.com/organizations/$GitHubOwner/settings/apps"
} else {
    Write-Host '  https://github.com/settings/apps'
}
Write-Host ''
