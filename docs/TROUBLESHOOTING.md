# Troubleshooting

Symptom-driven playbook for operators of this runner infrastructure. For consumer-facing usage questions see [USAGE.md](USAGE.md).

All commands assume `$RG = $env:RESOURCE_GROUP` and an authenticated `az` session.

---

## Jobs stuck at "Waiting for a runner" — never progresses

KEDA scales 0 -> N by polling the GitHub API and matching on labels. If no runner ever appears, one of the links is broken.

### 1. Are the labels right?

Workflow `runs-on:` **must** match the labels the runners register with:

- Linux: `[self-hosted, linux, aca]`
- Windows: `[self-hosted, windows, aci]`

Typos (`acr` vs `aca`, `window` vs `windows`) are the single most common cause.

### 2. Is the runner group allowed to run this repo's jobs?

Org settings -> Actions -> Runner groups -> open the group the runners live in -> check the "Repository access" list. If the repo isn't in the allow-list, the KEDA scaler will see 0 eligible jobs and do nothing.

### 3. Is the KEDA scaler authenticating to GitHub?

The scaler uses the GitHub App (JWT -> installation access token). If `GH_APP_PEM_B64` is corrupted or the app has been uninstalled from the org, scaling stops silently.

```powershell
# Check the ACA Job scale rule errors
az containerapp job show `
  --resource-group $RG `
  --name caj-linux-gh-runners-<suffix> `
  --query "properties.configuration.triggerType" -o tsv

# Tail the KEDA scaler logs via Log Analytics
$lawId = az monitor log-analytics workspace list `
  --resource-group $RG --query "[0].customerId" -o tsv
az monitor log-analytics query `
  --workspace $lawId `
  --analytics-query "ContainerAppSystemLogs_CL | where ContainerAppName_s startswith 'caj-linux' | top 50 by TimeGenerated desc"
```

Look for `401 Unauthorized` or `Installation not found`. If present, regenerate the PEM and re-run `setup-github-app.ps1` — see [runbooks/rotate-github-app-pem.md](runbooks/rotate-github-app-pem.md).

### 4. Is the GitHub App installed on the target scope?

The app must be installed on the **organisation** (not a single repo) and granted **Self-hosted runners: Read & write** and **Administration: Read & write** at the org level. Missing permissions silently break registration-token exchange.

### 5. Is the scaler polling?

KEDA poll interval is configured at 30s (Linux) / 60s (Windows). If a job has been waiting for < 2 minutes, just wait.

---

## Job starts but dies at "Configuring the runner" / "Waiting for registration"

The runner container started, pulled a JWT, but failed to exchange it for a registration token or timed out during `./config.sh`.

### Common causes

| Symptom | Cause | Fix |
|---|---|---|
| `openssl: error loading PEM` / `ImportFromPem failed` | `GH_APP_PEM_B64` is not valid base64 of a PEM | Regenerate per `setup-github-app.ps1` docs |
| `401 Bad credentials` | GitHub App removed from org, or JWT clock skew > 1 min | Check app install, check container host time |
| Request to `actions/runner-registration` times out | Slow ACR pull, container exceeds registration-token TTL (1h) | Pre-warm by running `test-runners.yml`; consider pinning to a local ACR region |
| `Failed to create symbolic link` (Windows) | Not a privilege issue on ACI — usually disk full or corrupt download | Rebuild the image |

### Where to look

```powershell
# Linux runner console logs
az monitor log-analytics query `
  --workspace $lawId `
  --analytics-query "ContainerAppConsoleLogs_CL | where ContainerAppName_s startswith 'caj-linux' | top 100 by TimeGenerated desc | project TimeGenerated, Log_s"

# Windows launcher logs (the ACA Job that creates the ACI group)
az monitor log-analytics query `
  --workspace $lawId `
  --analytics-query "ContainerAppConsoleLogs_CL | where ContainerAppName_s startswith 'caj-win-launcher' | top 100 by TimeGenerated desc | project TimeGenerated, Log_s"

# Windows runner logs (inside the ACI group the launcher created)
az monitor log-analytics query `
  --workspace $lawId `
  --analytics-query "ContainerInstanceLog_CL | top 100 by TimeGenerated desc | project TimeGenerated, ContainerGroup_s, Message"
```

---

## Windows launcher fails to create the ACI group

The Windows launcher (a Linux ACA Job) runs `az container create` against the runner RG. If it fails, the Windows job never registers.

### Check the launcher identity's roles

The **launcher** managed identity needs three roles:

```powershell
$launcherMi = az identity show `
  --resource-group $RG `
  --name id-<namingPrefix>-gh-runners-<locationAbbreviation>-launcher `
  --query principalId -o tsv

az role assignment list --assignee $launcherMi --all -o table
```

Expected assignments:

| Role | Scope |
|---|---|
| `AcrPull` | The runner ACR |
| `Container Instance Contributor` | The runner resource group |
| `Managed Identity Operator` | The launcher identity **itself** (required for `az container create --acr-identity`) |

Missing the Managed Identity Operator assignment manifests as **`LinkedAuthorizationFailed`** in the launcher logs. This role is created by `infra/modules/identity.bicep` — if it is missing, re-run `deploy.yml`.

### Check the Windows ACI region

`windowsAciLocation` in `main.bicepparam` must be a region that supports **Windows** ACI. Sweden Central supports Linux ACI only. Default in this repo is `westeurope`. If you change it, verify with:

```powershell
az provider show --namespace Microsoft.ContainerInstance `
  --query "resourceTypes[?resourceType=='containerGroups'].locations" -o json
```

---

## `ACI quota exceeded` when scaling Windows

Default ACI quota is approximately 100 container groups per subscription per region. If you hit it:

1. Delete any orphaned `aci-win-runner-*` groups (the launcher deletes them on success, but failed launches can leak):
   ```powershell
   az container list --resource-group $RG `
     --query "[?starts_with(name, 'aci-win-runner-')].name" -o tsv
   ```
2. Request a quota increase via **Azure support -> Quotas -> Container Instances**.

---

## Deprecated runner version warning in the Actions UI

GitHub deprecates runner versions on a ~3-month cadence. This repo pins the **Linux** base image to a specific runner version (`ghcr.io/actions/actions-runner:<version>`) and the **Windows** runner Dockerfile to a specific `mcr.microsoft.com/dotnet/sdk` tag. Both ship via `:stable`.

- The weekly scheduled build (**Sunday 22:00 UTC**) rebuilds images but does **not** automatically bump the pinned runner / base-image version.
- Bumping is a manual Dependabot PR:
  - Linux base image — see [upgrading.md § Bump the Linux runner base image](upgrading.md#bump-the-linux-runner-base-image).
  - Windows base image — see [upgrading.md § Bump the Windows runner base image](upgrading.md#bump-the-windows-runner-base-image).
- For the **VMSS tiers** the deprecation clock is driven by the AIB bake, not the container image — bump the `actions/runner-images` pinned commit SHA in `infra/modules/aib-ubuntu.bicep` / `aib-windows.bicep` and re-run `build-vhds.yml`. Old gallery versions remain available for rollback via the `vmssLinuxImageVersion` / `vmssWindowsImageVersion` params.

To check what's deployed:

```powershell
az acr repository show-tags `
  --name <acr-name> --repository github-runner-linux `
  --orderby time_desc --top 5 -o table
```

---

## `BCP081` warnings during `az bicep build`

Example:
```
Warning BCP081: Resource type "Microsoft.App/jobs@2024-10-02-preview" does not have types available.
```

**This is expected and safe.** The Bicep modules intentionally use the latest (sometimes preview) API versions to get access to current KEDA trigger shapes. BCP081 means the Bicep CLI doesn't have the type schema cached; the template still deploys correctly.

Do not "fix" by downgrading API versions — run the build, ignore the warning. Run `az bicep upgrade` occasionally to refresh the type cache.

---

## ACR image pull fails on the runner

Symptom: the ACA Job replica fails with `unauthorized: authentication required` or `manifest unknown`.

### Runner identity AcrPull check

```powershell
$runnerMi = az identity show `
  --resource-group $RG `
  --name id-<namingPrefix>-gh-runners-<locationAbbreviation> `
  --query principalId -o tsv

$acrId = az acr show --name <acr-name> --query id -o tsv
az role assignment list --assignee $runnerMi --scope $acrId -o table
```

Expect one `AcrPull` assignment. If absent, re-run `deploy.yml` — the Bicep in `identity.bicep` recreates it.

### Stale `:stable` tag

If the last `build-images.yml` run failed, `:stable` may still point at an old manifest that's been garbage-collected (the ACR purge task — see [upgrading.md](upgrading.md)) keeps only N tagged images). Re-run `build-images.yml` to publish a fresh `:stable`.

---

## Deployment fails with `RoleAssignmentUpdateNotPermitted` or `RoleAssignmentExists`

If you've re-run `deploy.yml` after changing an identity, Bicep may try to recreate role assignments that already exist. The cleanup step in `deploy.yml` removes legacy RG-scoped assignments from pre-#14 deployments; if it hasn't run yet, run it manually:

```powershell
# See deploy.yml for the exact cleanup commands — roles to remove from
# legacy runner identity: Contributor, AcrPull, Container Instance Contributor
# scoped to the resource group.
```

Run `deploy.yml` again after cleanup — it's idempotent.

---

## VMSS tier issues

Applies only when `enableVmssLinux` or `enableVmssWindows` is `true` (see [ARCHITECTURE.md#vmss-tiers-opt-in](ARCHITECTURE.md#vmss-tiers-opt-in)). If both are `false`, none of the resources below exist and every symptom here is non-applicable.

### AIB image build fails

`build-vhds.yml` drives [Azure Image Builder](https://learn.microsoft.com/en-us/azure/virtual-machines/image-builder-overview) bakes. Trigger a fresh bake from the CLI (useful when iterating on `aib-ubuntu.bicep` / `aib-windows.bicep` or clearing a `CustomizerFailed` state):

```powershell
# Re-run both bakes on the current branch
gh workflow run build-vhds.yml --ref $(git rev-parse --abbrev-ref HEAD)

# Watch the most recent run
gh run watch
```

Inspect active/past AIB runs directly on Azure:

```powershell
az image builder list --resource-group $RG -o table
az image builder show-runs --resource-group $RG --name <template-name> -o json
```

Common causes:

| Symptom | Cause | Fix |
|---|---|---|
| `CustomizerFailed` at the `actions/runner-images` clone step | Pinned commit SHA no longer resolvable (force-push / repo deletion) | Bump the pinned SHA in `infra/modules/aib-ubuntu.bicep` / `aib-windows.bicep`; re-run `build-vhds.yml` |
| `MarketplaceTermsNotAccepted` on the source image | Some runner-images base images (e.g. VisualStudio-preinstalled SKUs) require one-time terms acceptance per subscription | `az vm image terms accept --publisher <p> --offer <o> --plan <sku>` on the deployment subscription |
| `ResourceNotAllowedByPolicy` in the auto-created staging RG | Tenant policy blocks resource creation in ad-hoc RGs / regions | Pin `stagingResourceGroup` to an existing pre-approved RG in the AIB template, or work with policy owners to allow the AIB principal |
| Windows bake runs > 90 min and times out | Default `buildTimeoutInMinutes` too low for WS2022 tool list | Raise `buildTimeoutInMinutes` on the WS2022 template (120+) |
| AIB UAMI missing roles | `id-<base>-aib` must have `Contributor` on the staging RG and `Image Contributor` on the Compute Gallery | Re-run `deploy.yml` — these role assignments are created by `identity.bicep` |

### VMSS create fails with `OS disk size exceeds resource disk size`

Ephemeral OS on `ResourceDisk` (Windows) / `CacheDisk` (Linux) requires the VM SKU's resource/cache disk to be ≥ the image size. This commonly appears when a `vmssVmSize` override is set to a non-`d` SKU.

| VM size | Resource disk | Fits WS2022 (~90 GB) | Fits Ubuntu 22.04 (~40 GB) |
|---|---|---|---|
| `Standard_D4s_v5` (no `d`) | 0 GB (cache only, ~36 GB) | ❌ | ❌ |
| `Standard_D4ds_v5` **(default)** | ~150 GB | ✅ | ✅ |
| `Standard_E4ds_v5` | ~150 GB | ✅ | ✅ |

Fix: set `vmssVmSize` to a **`d`-suffixed SKU** (e.g. `Standard_D4ds_v5`, `Standard_D8ds_v5`, `Standard_E4ds_v5`). The `d` indicates a local temp/resource disk; ephemeral OS requires it. See [ephemeral OS disk placement](https://learn.microsoft.com/en-us/azure/virtual-machines/ephemeral-os-disks-placement).

### VMSS quota exceeded

Linux VMSS uses the `Standard DSv5 Family vCPUs` quota (or `Standard EDSv5 Family vCPUs` if you override to an E-series SKU). Check:

```powershell
az vm list-usage --location $env:AZURE_LOCATION -o table | Select-String "DSv5|EDSv5"
```

Each `Standard_D4ds_v5` costs 4 vCPUs against the family quota. With `vmssLinuxMaxInstances = 10` and `vmssWindowsMaxInstances = 10`, budget **80 vCPUs minimum**. Request an increase via **Azure support → Quotas → Compute-VM**.

### Warm runner not being reused (every job is a cold start)

Expected behaviour: once a VM finishes a job it stays online for `idleRetentionMinutes`; the next matching job should land on it within KEDA's poll window.

Diagnosis:

1. **Registration labels** — SSH to the warm VM (or check its boot log) and confirm `./config.sh` was invoked with exactly `--labels self-hosted,linux,vmss` (or `...,windows,vmss`). A missing or extra label breaks KEDA matching.

   ```powershell
   # Linux VM bootstrap log
   az vmss run-command invoke --resource-group $RG --name vmss-lnx-<suffix> `
     --command-id RunShellScript --instance-id 0 `
     --scripts "journalctl -u gh-runner-bootstrap --no-pager | tail -100"
   ```

2. **Watchdog fired prematurely** — confirm the watchdog is reading the sliding window, not just `bootTime`:

   ```powershell
   az vmss run-command invoke --resource-group $RG --name vmss-lnx-<suffix> `
     --command-id RunShellScript --instance-id 0 `
     --scripts "cat /var/run/runner-lifecycle/last-job-end /var/run/runner-lifecycle/boot 2>/dev/null; systemctl status gh-runner-watchdog.timer"
   ```

3. **KEDA scaler metrics** — if KEDA is adding a new instance when a warm one is already idle, the scaler is not counting the warm runner as available. Check the launcher ACA Job logs for the `github-runner` trigger output:

   ```powershell
   az monitor log-analytics query --workspace $lawId --analytics-query `
     "ContainerAppSystemLogs_CL | where ContainerAppName_s startswith 'caj-vmss-' | where Log_s contains 'keda' | top 50 by TimeGenerated desc"
   ```

   The scaler queries `/repos/.../actions/runners` — a warm runner should appear there with `status: online` and `busy: false`. If `busy: true` sticks after a job finishes, the runner service didn't pick up the `job-completed` hook.

4. **`idleRetentionMinutes = 0`** — this disables warm retention entirely. If you didn't intend to, fix the param and redeploy.

### VM never deletes itself (stays running past `idleRetentionMinutes`)

The watchdog self-terminates the VM via `az vmss delete-instances` using the **runner UAMI**, which must have a narrow `Virtual Machine Contributor` role scoped to the parent VMSS:

```powershell
$runnerMi = az identity show --resource-group $RG `
  --name id-<namingPrefix>-gh-runners-<locationAbbreviation> --query principalId -o tsv

$vmssId = az vmss show --resource-group $RG --name vmss-lnx-<suffix> --query id -o tsv
az role assignment list --assignee $runnerMi --scope $vmssId -o table
```

Expect a `Virtual Machine Contributor` (or custom role with `virtualMachineScaleSets/virtualMachines/delete` + `virtualMachineScaleSets/delete/action`) scoped to the VMSS. If missing, re-run `deploy.yml` — `identity.bicep` creates it.

Also check the watchdog log directly — `config.sh remove` failures (stale PEM, GitHub App uninstalled) block the self-delete:

```powershell
az vmss run-command invoke --resource-group $RG --name vmss-lnx-<suffix> `
  --command-id RunShellScript --instance-id 0 `
  --scripts "journalctl -u gh-runner-watchdog --no-pager | tail -200"
```

As a last resort the VM runs `shutdown -h now` as belt-and-braces, but a `Stopped (deallocated)` VM still costs disk — manually clean up with:

```powershell
az vmss delete-instances --resource-group $RG --name vmss-lnx-<suffix> --instance-ids <id>
```

### Reg-token leak risk via VMSS tags / extension settings

**Threat model**: VMSS tags and `CustomScriptExtension` args are readable by anyone with `Reader` on the VMSS. If the registration token were placed there plainly, it could be stolen.

**Mitigations in place**:

- Reg tokens are **short-lived (1 h) and single-use** — they cannot be reused after the runner consumes them.
- The bootstrap script wipes the delivered token immediately after consumption (tag cleared, file deleted).
- When available, tokens are delivered via a **Key Vault secret** consumed by the VM's runner MI (not via ARM-visible tags or CSE `settings`). Fallback is CSE `protectedSettings`, which is encrypted at rest and not visible to `Reader`.

Audit that no reg token is lingering:

```powershell
# Inspect VMSS instance tags for a stray reg-token key
az vmss list-instances --resource-group $RG --name vmss-lnx-<suffix> `
  --query "[].{name:name, tags:tags}" -o json

# Inspect CSE settings (should be empty after bootstrap; protectedSettings never appears here)
az vmss extension show --resource-group $RG --vmss-name vmss-lnx-<suffix> `
  --name CustomScriptExtension --query settings -o json
```

If a tag called `regToken` (or similar) persists beyond ~5 minutes after instance boot, the bootstrap wipe failed — raise an issue and manually clear the tag with `az vmss update --set tags.regToken=null`.

### NSG / VNet hardening for VMSS tiers

The VMSS tiers deploy into a default subnet with a permissive NSG suitable for demos; for production you should validate and tighten this. Baseline expectation is **egress-only**:

- **No public inbound** — runners poll GitHub Actions over HTTPS; inbound 22/3389 from `Internet` should be denied. Use `az vmss run-command` or Azure Bastion for interactive access, not direct SSH/RDP.
- **Egress allow-list** — the runner only needs HTTPS to `AzureCloud` (ACR, Key Vault, MI token endpoint, Log Analytics) and to GitHub (`GitHubActions`, `github.com`, `*.githubusercontent.com`). Consider NSG service tags `AzureCloud`, `GitHubActions`, `AzureKeyVault`, `AzureContainerRegistry` + a default deny.
- **Validate after every `deploy.yml`** — `az network nsg rule list --nsg-name <nsg> -o table` and diff against the expected baseline; flag any new `AllowAnyInbound` or `Internet`-source rules.

TODO (tracked in #98 sec#11): ship a baseline NSG module (`modules/network-nsg.bicep`) and wire it into `vmss-linux.bicep` / `vmss-windows.bicep` so the hardened ruleset is the default, not a post-deploy task.

---

## Related runbooks

- [rotate-github-app-pem.md](runbooks/rotate-github-app-pem.md) — rotating the GitHub App PEM after suspected leak or as planned maintenance.
- [incident-response.md](runbooks/incident-response.md) — full security incident playbook.
- [upgrading.md](upgrading.md) — bumping base images, Actions versions, SDKs; rollback via `:stable` retag.
