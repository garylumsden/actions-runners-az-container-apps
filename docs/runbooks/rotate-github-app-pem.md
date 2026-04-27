# Runbook: Rotate the GitHub App PEM

**Applies to:** the GitHub App used by `actions-runners-az-container-apps` to register ephemeral
Linux (ACA Job), Windows (ACI), and — when enabled — `vmss-linux` / `vmss-windows`
runners.

**When to use:** scheduled rotation, suspected key leak, or when a team member
with access to the PEM leaves the project.

**Expected duration:** ~15 minutes, including one deploy.

**Pre-requisites:**

- `az login` as a principal with access to the target resource group.
- `gh` CLI authenticated against this repo (`gh auth status`).
- PowerShell 7+.
- Permission to manage the GitHub App (org owner or app manager).

---

## 1. Generate a new PEM in the GitHub App settings

1. Go to **GitHub org** -> **Settings** -> **Developer settings** -> **GitHub Apps**.
2. Open the app used by this repo (the one referenced by `GH_APP_ID`).
3. Scroll to **Private keys**.
4. Click **Generate a private key**. A `.pem` file will download.

> WARNING: Do **not** revoke the existing key yet. Keeping the old key valid
> until the new one is deployed avoids a window where runners cannot register.

## 2. Re-run the setup script

This base64-encodes the PEM, updates the repo variables
(`GH_APP_ID`, `GH_INSTALLATION_ID`) and rewrites the secret `GH_APP_PEM_B64`.

```powershell
cd C:\path\to\actions-runners-az-container-apps
.\scripts\setup-github-app.ps1 -PemPath "<path-to-newly-downloaded>.pem"
```

The script is idempotent. Confirm it reports that `GH_APP_PEM_B64` was
updated. `setup-github-app.ps1` writes these at **organisation** scope
(using `gh secret set --org` and `gh variable set --org`), so the
verification commands must pass `--org` too — otherwise `gh` defaults to
repo scope and shows nothing:

```powershell
# Replace <your-org> with the GitHub org that owns the GitHub App.
gh secret list --org <your-org> | Select-String GH_APP_PEM_B64
gh variable list --org <your-org> | Select-String -Pattern 'GH_APP_ID|GH_INSTALLATION_ID'
```

## 3. Redeploy via Actions

Trigger `deploy.yml` from `main` so the new PEM is written to the ACA secret
`github-app-pem` on both the Linux and Windows-launcher jobs:

```powershell
gh workflow run deploy.yml --ref main
gh run watch
```

Wait until the run completes successfully (`conclusion: success`).

## 4. Verify

> **VMSS tiers.** The PEM is stored in Key Vault at a **versionless URI**; both
> the Linux and Windows-launcher ACA Jobs, and the two VMSS launcher ACA Jobs
> (when `enableVmssLinux` / `enableVmssWindows` are true), resolve it at each
> replica start — so the next launcher execution picks up the new PEM
> automatically. VMSS VMs that are **already warm** at rotation time continue
> to hold the old installation-access token in memory until their current idle
> window expires; any new registration / remove-token minting they do goes
> through the next launcher execution, which will have the new PEM. To force a
> refresh of warm VMs, either wait for `idleRetentionMinutes` to elapse or
> run `az vmss delete-instances --instance-ids <ids>` to recycle them.

### 4a. Confirm the ACA secret was updated

```powershell
az containerapp job show ``
  --resource-group $env:RESOURCE_GROUP ``
  --name "caj-linux-<namingPrefix>-gh-runners-<locAbbr>" ``
  --query "properties.configuration.secrets[?name=='github-app-pem']"
```

The secret should be present. Its value is not returned (by design); the
important check is that it exists and was updated by the latest deploy.

### 4b. Trigger a test workflow that targets the runners

From any consumer repo:

```powershell
gh workflow run <a-workflow-using-self-hosted-runners>.yml
```

### 4c. Watch an ACA Job execution register a runner

```powershell
# List recent executions of the Linux ACA job
az containerapp job execution list ``
  --resource-group $env:RESOURCE_GROUP ``
  --name "caj-linux-<namingPrefix>-gh-runners-<locAbbr>" ``
  --query "[].{name:name, status:properties.status, start:properties.startTime}" -o table

# Stream logs for the most recent execution
az containerapp job logs show ``
  --resource-group $env:RESOURCE_GROUP ``
  --name "caj-linux-<namingPrefix>-gh-runners-<locAbbr>" ``
  --container "linux-runner" --follow
```

You should see: JWT generated -> installation token obtained -> registration
token obtained -> `Runner successfully added` -> the job executing -> `Runner
removed successfully`.

### 4d. Query Log Analytics

```powershell
$law = az monitor log-analytics workspace show ``
  --resource-group $env:RESOURCE_GROUP ``
  --workspace-name "law-<namingPrefix>-gh-runners-<locAbbr>" ``
  --query customerId -o tsv

az monitor log-analytics query ``
  --workspace $law ``
  --analytics-query "ContainerAppConsoleLogs_CL
    | where TimeGenerated > ago(30m)
    | where ContainerName_s == 'linux-runner'
    | where Log_s has_any ('Runner successfully added','authentication failed','401','403')
    | project TimeGenerated, ContainerAppName_s, Log_s
    | order by TimeGenerated desc" -o table
```

A healthy rotation shows `Runner successfully added` entries with no `401` /
`403` / `authentication failed` errors after the deploy completed.

## 5. Revoke the old PEM

Once verification passes:

1. GitHub org -> **Settings** -> **Developer settings** -> **GitHub Apps** -> the app.
2. **Private keys** -> find the previous key (not the one generated in step 1).
3. Click **Delete**.
4. Confirm. The old PEM can no longer be used to mint JWTs.

## 6. Post-rotation hygiene

- Delete the local `.pem` file you downloaded in step 1:
  ```powershell
  Remove-Item "<path-to-newly-downloaded>.pem" -Force
  ```
- If the rotation was triggered by a **suspected leak**, continue with the
  [incident response runbook](incident-response.md).

## References

- [Managing private keys for GitHub Apps](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/managing-private-keys-for-github-apps)
- [Azure Container Apps - secrets](https://learn.microsoft.com/en-us/azure/container-apps/manage-secrets)
