#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Configures OIDC (Workload Identity Federation) so GitHub Actions workflows can
    authenticate to Azure without storing any client secrets.

.DESCRIPTION
    Creates an Azure AD app registration that holds exactly ONE federated
    credential named 'github-production-env', with subject
    'repo:{org}/{repo}:environment:production'. This is the only subject
    pattern used by the workflows in this repo (deploy.yml and
    build-images.yml both declare 'environment: production').

    On every run the script reconciles the app's federated credentials:
    any credential whose name differs from 'github-production-env' is
    deleted - including older 'github-main' (ref-based), 'github-prs'
    (pull_request), and any manually-added or tag-based subjects. This
    guarantees the OIDC trust surface cannot be silently widened outside
    the production environment's protection rules.

    The deploying identity needs Owner on the resource group because the Bicep
    templates create role assignments (AcrPull + Contributor) for the managed
    identity. Owner is the minimum role that grants
    Microsoft.Authorization/roleAssignments/write.

    OUTPUTS:
      This script sets the following GitHub Actions org **Variables**:
        AZURE_CLIENT_ID
        AZURE_TENANT_ID
        AZURE_SUBSCRIPTION_ID
        RESOURCE_GROUP
        AZURE_LOCATION

      GH_APP_ID, GH_INSTALLATION_ID (Variables) and GH_APP_PEM_B64 (Secret)
      are set by setup-github-app.ps1 — not by this script.

      ACR_NAME is NOT set as a GitHub Actions variable. build-images.yml
      discovers the ACR at runtime via `az acr list` against the resource
      group, so no manual or workflow-written variable is needed.

.PARAMETER GitHubOrg
    GitHub organisation or user name (default: auto-detected from git remote).

.PARAMETER SourceRepo
    Name of the **source repo** where `deploy.yml` and `build-images.yml`
    actually run (default: auto-detected from git remote).

    This is NOT the same as the runner target repo. This script uses
    SourceRepo for two things, both of which must point at the repo that
    runs the workflows:
      * The OIDC federated-credential subject
        (repo:{org}/{SourceRepo}:environment:production).
      * Where GitHub Actions variables are written when -Scope is 'repo'.

    The runner TARGET repo (where ephemeral runners register, used when
    runnerScope='repo' in Bicep) is a separate concern and is set in
    infra/main.bicepparam via the `githubRepo` parameter.

    `-GitHubRepo` is accepted as a deprecated alias for back-compat.

.PARAMETER SubscriptionId
    Azure subscription ID. Defaults to the current az login subscription.

.PARAMETER ResourceGroup
    Resource group to create and grant access to (default: yourprefix-gh-runners-REGIONABBR).

.PARAMETER Location
    Azure region for the resource group (default: swedencentral).

.PARAMETER AppName
    Display name of the Azure AD app registration (default: sp-actions-runners-az-container-apps-deploy).
    This display name must be unique in the tenant: if more than one existing
    app registration carries the same display name, the script fails rather
    than guessing which one to reuse. Rename or delete the duplicates first.

.EXAMPLE
    ./scripts/setup-oidc.ps1
    ./scripts/setup-oidc.ps1 -SubscriptionId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
#>
param(
    [Alias('GitHubOrg')]
    [string] $GitHubOwner,
    [Alias('GitHubRepo')]
    [string] $SourceRepo,
    [ValidateSet('org', 'repo')]
    [string] $Scope,
    [string] $SubscriptionId,
    [string] $NamingPrefix,
    [string] $LocationAbbreviation = 'swc',
    [string] $ResourceGroup,
    [string] $Location      = 'swedencentral',
    [string] $AppName       = 'sp-actions-runners-az-container-apps-deploy'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Keep $GitHubOrg as an internal alias for readability in the rest of the script.
$GitHubOrg = $GitHubOwner

# Helper: run an az CLI command, capture stderr, and throw on non-zero exit.
# Returns stdout (trimmed). Use this instead of '2>$null', which silently
# swallowed errors and turned transient auth/network failures into "not found"
# results.
function Invoke-AzQuery {
    param(
        [Parameter(Mandatory)] [string[]] $AzArgs,
        [string] $Context = 'az query'
    )
    $output = & az @AzArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        $joinedArgs = ($AzArgs -join ' ')
        $joinedOut  = ($output | Out-String).Trim()
        throw "[$Context] 'az $joinedArgs' failed (exit $LASTEXITCODE):`n$joinedOut"
    }
    # Filter captured stderr (ErrorRecord) lines from stdout
    $stdout = $output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
    return (($stdout | Out-String).Trim())
}

# Auto-detect GitHub owner and source repo from git remote. SourceRepo MUST be
# the repo where deploy.yml / build-images.yml actually run — it drives the
# OIDC federated-credential subject and the Actions-variables write target.
# The runner TARGET repo (runnerScope='repo' in Bicep) is a different value
# and is set in infra/main.bicepparam.
$remote = git remote get-url origin 2>$null
if (-not $GitHubOrg) {
    if ($remote -match 'github\.com[/:]([^/]+)/') {
        $GitHubOrg = $Matches[1]
        Write-Host "  Detected GitHub owner : $GitHubOrg" -ForegroundColor DarkGray
    } else {
        $GitHubOrg = Read-Host '  GitHub organisation or user name'
    }
}
if (-not $SourceRepo) {
    if ($remote -match 'github\.com[/:]([^/]+)/([^/.]+?)(?:\.git)?$') {
        $SourceRepo = $Matches[2]
        Write-Host "  Detected source repo  : $SourceRepo" -ForegroundColor DarkGray
    } else {
        $SourceRepo = Read-Host '  Source repo name (where workflows run)'
    }
}

# Prompt for scope if not supplied. Scope controls where GitHub Actions
# variables are written (org-level vs repo-level). The runner scope itself
# is configured separately in main.bicepparam.
if (-not $Scope) {
    Write-Host ''
    Write-Host 'Where should GitHub Actions variables and federated credentials target?' -ForegroundColor Yellow
    Write-Host '  [O] org   — organisation-level variables, available to every repo'
    Write-Host '  [R] repo  — variables written directly on this repo (required for personal accounts)'
    $scopeChoice = Read-Host '  Choose [O/R] (default O)'
    $Scope = if ($scopeChoice -match '^[Rr]') { 'repo' } else { 'org' }
}

# Derive resource group name from naming prefix if not supplied
if (-not $ResourceGroup) {
    if ($NamingPrefix) {
        $ResourceGroup = "${NamingPrefix}-gh-runners-${LocationAbbreviation}"
    } else {
        $ResourceGroup = Read-Host "  Resource group name (e.g. myprefix-gh-runners-${LocationAbbreviation})"
    }
}

# ── Verify az CLI is available and the user is logged in ──────────────────────
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is not installed. See: https://aka.ms/install-azure-cli'
}
$null = az account show 2>&1
if ($LASTEXITCODE -ne 0) { throw 'Please run "az login" first.' }

if (-not $SubscriptionId) {
    $SubscriptionId = (az account show --query id --output tsv)
    if ($LASTEXITCODE -ne 0) { throw 'Failed to read current subscription from "az account show".' }
}
Write-Host "Setting active subscription: $SubscriptionId" -ForegroundColor Cyan
$setSubOutput = & az account set --subscription $SubscriptionId 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Failed to set active subscription to '$SubscriptionId': $(($setSubOutput | Out-String).Trim())"
}
$TenantId = (az account show --query tenantId --output tsv)
if ($LASTEXITCODE -ne 0) { throw 'Failed to read tenantId from "az account show".' }

Write-Host "`n=== OIDC Setup for GitHub Actions → Azure ===" -ForegroundColor Cyan
Write-Host "  Subscription : $SubscriptionId"
Write-Host "  Tenant       : $TenantId"
Write-Host "  Resource group: $ResourceGroup ($Location)"
Write-Host "  Source repo  : $GitHubOrg/$SourceRepo (where workflows run)"
Write-Host ''

# ── Create resource group (idempotent) ────────────────────────────────────────
Write-Host 'Creating resource group...' -ForegroundColor Cyan
$rgCreateOutput = & az group create --name $ResourceGroup --location $Location --output none 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Failed to create resource group '$ResourceGroup' in '$Location': $(($rgCreateOutput | Out-String).Trim())"
}
Write-Host "  ✅ $ResourceGroup"

# ── Create the Azure AD app registration ─────────────────────────────────────
# Display names in Entra ID are NOT unique. If more than one app registration
# carries the same display name, pick-first is unsafe — we cannot tell which
# one the operator actually intended to reuse. Fail fast and list every match
# so the duplicates can be resolved by hand before re-running.
Write-Host 'Creating app registration...' -ForegroundColor Cyan
$existingAppsJson = Invoke-AzQuery -Context 'app lookup' -AzArgs @(
    'ad','app','list','--display-name',$AppName,'--query','[].appId','--output','json'
)
$existingApps = if ([string]::IsNullOrWhiteSpace($existingAppsJson)) {
    @()
} else {
    @($existingAppsJson | ConvertFrom-Json)
}
if ($existingApps.Count -gt 1) {
    $ambiguous = ($existingApps | ForEach-Object { "    - $_" }) -join "`n"
    throw "Multiple Azure AD app registrations found with display name '$AppName' (display names are not unique in Entra ID). Refusing to guess which one to reuse. Resolve by deleting or renaming the duplicates, then re-run.`nMatching appIds:`n$ambiguous"
}
if ($existingApps.Count -eq 1) {
    $AppId = $existingApps[0]
    Write-Host "  ℹ️  App '$AppName' already exists (appId: $AppId). Reusing."
} else {
    $AppId = (az ad app create --display-name $AppName --query appId --output tsv)
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create app registration.' }
    Write-Host "  ✅ Created (appId: $AppId)"
}

# ── Create service principal (idempotent) ─────────────────────────────────────
# NOTE: 'az ad sp show' returns non-zero when the SP is missing, making it
# indistinguishable from a real failure. Use 'az ad sp list --filter' instead,
# which returns exit 0 with an empty string when the SP does not exist.
Write-Host 'Creating service principal...' -ForegroundColor Cyan
$SpObjectId = Invoke-AzQuery -Context 'sp lookup' -AzArgs @(
    'ad','sp','list','--filter',"appId eq '$AppId'",'--query','[0].id','--output','tsv'
)
if (-not $SpObjectId) {
    $SpObjectId = (az ad sp create --id $AppId --query id --output tsv)
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create service principal.' }
    Write-Host "  ✅ Created (objectId: $SpObjectId)"
} else {
    Write-Host "  ℹ️  Service principal already exists."
}

# ── Assign Owner on the resource group ───────────────────────────────────────
# Owner is required (not just Contributor) because the Bicep creates role assignments.
Write-Host 'Assigning Owner role on resource group...' -ForegroundColor Cyan
$rgScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
$existingRole = Invoke-AzQuery -Context 'role-assignment lookup' -AzArgs @(
    'role','assignment','list','--assignee',$AppId,'--role','Owner','--scope',$rgScope,
    '--query','[0].id','--output','tsv'
)
if ($existingRole) {
    Write-Host '  ℹ️  Owner assignment already exists.'
} else {
    az role assignment create `
        --assignee-object-id  $SpObjectId `
        --assignee-principal-type ServicePrincipal `
        --role  Owner `
        --scope $rgScope `
        --output none
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create Owner role assignment.' }
    Write-Host '  ✅ Assigned.'
}

# ── Federated credentials: reconcile to a single credential ──────────────────
# The app must hold exactly ONE federated credential:
#   name    = github-production-env
#   subject = repo:{org}/{repo}:environment:production
# Any other credential — older 'github-main' (ref-based), 'github-prs'
# (pull_request), tag-based subjects, or anything added out-of-band — is
# deleted on every run. This keeps the OIDC trust surface pinned to the
# environment's protection rules and prevents silent widening.
$desiredCredName    = 'github-production-env'
$desiredSubject     = "repo:${GitHubOrg}/${SourceRepo}:environment:production"
$desiredIssuer      = 'https://token.actions.githubusercontent.com'
$desiredAudiences   = @('api://AzureADTokenExchange')
$desiredDescription = 'GitHub Actions — production environment (sole credential)'

Write-Host 'Reconciling federated credentials (OIDC)...' -ForegroundColor Cyan

$existingJson = Invoke-AzQuery -Context 'fed-cred list' -AzArgs @(
    'ad','app','federated-credential','list','--id',$AppId,'--output','json'
)
$existingCreds = if ([string]::IsNullOrWhiteSpace($existingJson)) {
    @()
} else {
    @($existingJson | ConvertFrom-Json)
}

# Match existing credentials by (subject, issuer) — not by name. The NAME is
# just a local label and can drift (portal edits, older runs of this script,
# import tooling). The security-relevant identity is the issuer+subject pair,
# because that is what Entra ID actually validates the incoming OIDC token
# against. Matching by name risks leaving a duplicate credential with the
# desired subject but a different name, which silently widens the trust
# surface this reconcile loop exists to pin down.
$matchingCreds = @($existingCreds | Where-Object {
    $_.subject -eq $desiredSubject -and $_.issuer -eq $desiredIssuer
})
$keepCred = if ($matchingCreds.Count -gt 0) { $matchingCreds[0] } else { $null }

# Delete every credential that does not match desired subject+issuer.
# (If multiple matched, we keep the first and delete the rest — duplicates of
# the same subject are still duplicates.)
# Delete failures are collected and raised as a hard error after the loop:
# leaving a stale broad-subject credential in place would silently re-widen
# the OIDC trust surface that this reconcile loop exists to enforce.
$deleteFailures = @()
$deletedCount = 0
foreach ($cred in $existingCreds) {
    if ($keepCred -and $cred.id -eq $keepCred.id) { continue }

    $deleteOutput = & az ad app federated-credential delete `
        --id $AppId `
        --federated-credential-id $cred.id `
        --output none 2>&1
    if ($LASTEXITCODE -ne 0) {
        $deleteFailures += "$($cred.name) (id=$($cred.id)): $(($deleteOutput | Out-String).Trim())"
    } else {
        Write-Host "  🧹 Removed stale credential '$($cred.name)' (subject: $($cred.subject))."
        $deletedCount++
    }
}

if ($deleteFailures.Count -gt 0) {
    throw "Failed to delete stale federated credentials (the single-credential guarantee cannot be enforced): $($deleteFailures -join '; ')"
}

# Three outcomes: create (nothing matched), update-in-place (a matching
# subject+issuer already existed but the name had drifted), or leave-as-is
# (name already matches too). Prefer updating in place over delete-and-recreate
# to minimise the window where the app has zero federated credentials.
$created  = $false
$updated  = $false
$leftAsIs = $false

if ($keepCred) {
    if ($keepCred.name -ne $desiredCredName) {
        $body = @{
            name        = $desiredCredName
            issuer      = $desiredIssuer
            subject     = $desiredSubject
            description = $desiredDescription
            audiences   = $desiredAudiences
        } | ConvertTo-Json
        $tmp = New-TemporaryFile
        Set-Content -Path $tmp.FullName -Value $body -Encoding UTF8

        $updateOutput = & az ad app federated-credential update `
            --id $AppId `
            --federated-credential-id $keepCred.id `
            --parameters "@$($tmp.FullName)" `
            --output none 2>&1
        $exit = $LASTEXITCODE
        Remove-Item $tmp.FullName -Force
        if ($exit -ne 0) {
            throw "Failed to update federated credential '$($keepCred.name)' → '$desiredCredName': $(($updateOutput | Out-String).Trim())"
        }
        Write-Host "  🔁 Renamed in place: '$($keepCred.name)' → '$desiredCredName' (subject preserved: $desiredSubject)."
        $updated = $true
    } else {
        Write-Host "  ℹ️  Federated credential '$desiredCredName' already matches desired subject/issuer."
        $leftAsIs = $true
    }
} else {
    $body = @{
        name        = $desiredCredName
        issuer      = $desiredIssuer
        subject     = $desiredSubject
        description = $desiredDescription
        audiences   = $desiredAudiences
    } | ConvertTo-Json
    $tmp = New-TemporaryFile
    Set-Content -Path $tmp.FullName -Value $body -Encoding UTF8

    $createOutput = & az ad app federated-credential create `
        --id $AppId `
        --parameters "@$($tmp.FullName)" `
        --output none 2>&1
    $exit = $LASTEXITCODE
    Remove-Item $tmp.FullName -Force
    if ($exit -ne 0) {
        throw "Failed to create federated credential '$desiredCredName': $(($createOutput | Out-String).Trim())"
    }
    Write-Host "  ✅ '$desiredCredName' created (subject: $desiredSubject)."
    $created = $true
}

Write-Host ("  Summary: created={0}, updated={1}, left-as-is={2}, deleted={3}" -f `
    $created, $updated, $leftAsIs, $deletedCount)

# ── Readback: print final federated credential list ──────────────────────────
# Ensures the reconcile loop above actually produced the intended single-
# credential state. If anything slipped past (API eventual consistency, a
# concurrent edit in the portal, a delete that silently failed) the operator
# sees it here instead of hitting AADSTS700016 at deploy time.
Write-Host 'Federated credentials on app (readback):' -ForegroundColor Cyan
$finalCredsJson = Invoke-AzQuery -Context 'fed-cred readback' -AzArgs @(
    'ad','app','federated-credential','list','--id',$AppId,'--output','json'
)
$finalCreds = if ([string]::IsNullOrWhiteSpace($finalCredsJson)) {
    @()
} else {
    @($finalCredsJson | ConvertFrom-Json)
}
foreach ($c in $finalCreds) {
    Write-Host ("    • {0,-28} subject={1}" -f $c.name, $c.subject)
}
if ($finalCreds.Count -ne 1 -or $finalCreds[0].name -ne $desiredCredName -or $finalCreds[0].subject -ne $desiredSubject) {
    throw "Federated credential readback does not match desired state. Expected exactly one credential '$desiredCredName' with subject '$desiredSubject'. Got $($finalCreds.Count) credential(s). See list above."
}
Write-Host "  ✅ Exactly one credential present and matches desired subject."

# ── Set variables automatically via gh CLI ────────────────────────────────────
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Host '  ⚠️  gh CLI not found — set these variables manually instead.' -ForegroundColor Yellow
} else {
    if ($Scope -eq 'org') {
        Write-Host 'Ensuring gh CLI has admin:org scope (a browser window may open)...' -ForegroundColor Cyan
        gh auth refresh -h github.com -s admin:org
        if ($LASTEXITCODE -ne 0) { throw 'gh auth refresh failed. Re-run after logging in.' }

        Write-Host 'Setting organisation variables...' -ForegroundColor Cyan
    } else {
        Write-Host "Setting repository variables on $GitHubOrg/$SourceRepo..." -ForegroundColor Cyan
    }

    # Set a variable at the chosen scope and then read it back to confirm.
    # Readback guards against: transient gh API failures that returned exit 0,
    # org-level visibility policies that silently downscope the set, and
    # propagation lag where a later deploy would read a stale value.
    function Set-GhVariableChecked {
        param(
            [Parameter(Mandatory)] [string] $Name,
            [Parameter(Mandatory)] [string] $Value,
            [Parameter(Mandatory)] [string] $Scope,
            [Parameter(Mandatory)] [string] $Owner,
            [string] $Repo
        )
        if ($Scope -eq 'org') {
            $setOutput = & gh variable set $Name --body $Value --org $Owner --visibility all 2>&1
        } else {
            $repoSpec = "$Owner/$Repo"
            $setOutput = & gh variable set $Name --body $Value --repo $repoSpec 2>&1
        }
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to set $Scope variable '$Name': $(($setOutput | Out-String).Trim())"
        }
        if ($Scope -eq 'org') {
            $readOutput = & gh variable get $Name --org $Owner 2>&1
        } else {
            $readOutput = & gh variable get $Name --repo "$Owner/$Repo" 2>&1
        }
        if ($LASTEXITCODE -ne 0) {
            throw "Set '$Name' but readback failed: $(($readOutput | Out-String).Trim())"
        }
        $actual = ($readOutput | Out-String).Trim()
        if ($actual -ne $Value) {
            throw "Readback mismatch for '$Name'. Expected='$Value' Actual='$actual'."
        }
        Write-Host "  ✅ $Name set and verified."
    }

    Set-GhVariableChecked -Name 'AZURE_CLIENT_ID'       -Value $AppId          -Scope $Scope -Owner $GitHubOrg -Repo $SourceRepo
    Set-GhVariableChecked -Name 'AZURE_TENANT_ID'       -Value $TenantId       -Scope $Scope -Owner $GitHubOrg -Repo $SourceRepo
    Set-GhVariableChecked -Name 'AZURE_SUBSCRIPTION_ID' -Value $SubscriptionId -Scope $Scope -Owner $GitHubOrg -Repo $SourceRepo
    Set-GhVariableChecked -Name 'RESOURCE_GROUP'        -Value $ResourceGroup  -Scope $Scope -Owner $GitHubOrg -Repo $SourceRepo
    Set-GhVariableChecked -Name 'AZURE_LOCATION'        -Value $Location       -Scope $Scope -Owner $GitHubOrg -Repo $SourceRepo
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '════════════════════════════════════════════════════════' -ForegroundColor Green
Write-Host '  OIDC setup complete!' -ForegroundColor Green
Write-Host '════════════════════════════════════════════════════════' -ForegroundColor Green
Write-Host ''
$scopeLabel = if ($Scope -eq 'org') { 'Organisation' } else { 'Repository' }
Write-Host "${scopeLabel} variables set (or set manually if gh was not available):" -ForegroundColor Yellow
Write-Host "  AZURE_CLIENT_ID       = $AppId"
Write-Host "  AZURE_TENANT_ID       = $TenantId"
Write-Host "  AZURE_SUBSCRIPTION_ID = $SubscriptionId"
Write-Host ''
Write-Host 'Run setup-github-app.ps1 next to set GH_APP_ID, GH_INSTALLATION_ID, and GH_APP_PEM_B64.'
Write-Host ''
Write-Host 'No AZURE_CLIENT_SECRET is needed — OIDC is fully passwordless.' -ForegroundColor Green
