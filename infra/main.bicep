targetScope = 'resourceGroup'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('Azure region for all resources.')
param location string = 'swedencentral'

@minLength(2)
@maxLength(6)
@description('Short abbreviation for the Azure region used in resource names (e.g. "swc" for swedencentral, "che" for switzerlandnorth). Must be 2-6 alphanumeric chars — longer values push composite names (ACR, Key Vault) over Azure length limits.')
param locationAbbreviation string = 'swc'

@minLength(2)
@maxLength(10)
@description('Naming prefix for all resources. Must be 2-10 chars because it is combined with other components to produce ACR names (capped at 50 alphanumeric chars, e.g. cr<prefix>ghrunners<loc>) and ACA resource names (e.g. caj-linux-<prefix>-<loc>). Change only to redeploy in a separate namespace.')
param namingPrefix string

@description('Runner scope. Use "org" for organisations (recommended) or "repo" for a single repository on a personal account or when org-wide self-hosted runners are not permitted.')
@allowed([
  'org'
  'repo'
])
param runnerScope string = 'org'

@description('GitHub owner login — either an organisation name or a personal user name. Was previously named "githubOrg".')
param githubOwner string

@description('GitHub repository name (without owner). Required when runnerScope = "repo"; ignored when runnerScope = "org".')
param githubRepo string = ''

@description('GitHub App ID (numeric string).')
param githubAppId string

@description('GitHub App installation ID (numeric string).')
param githubInstallationId string

@secure()
@description('GitHub App private key, base64-encoded. See scripts/setup-github-app.ps1.')
param githubAppPemB64 string

@description('Maximum concurrent Linux runner executions.')
param linuxMaxExecutions int = 10

@description('Maximum concurrent Windows launcher (ACI) executions.')
param windowsMaxExecutions int = 10

@description('Azure region for Windows ACI runner containers. Must support Windows ACI (e.g. westeurope, eastus). Defaults to westeurope because many regions (including swedencentral) do not support Windows containers on ACI.')
param windowsAciLocation string = 'westeurope'

// ─── VMSS runner tiers (opt-in; disabled by default) ─────────────────────────
// See docs/ARCHITECTURE.md for the full tier matrix. These two flags are the
// master on/off switches — when both are false, zero VMSS/AIB/gallery/
// vmss-launcher resources are created and the deployment is a no-op vs the
// pre-VMSS baseline.

@description('Enable the vmss-linux tier (Ubuntu 22.04 on VMSS Flex with full Docker/buildx/compose). Defaults to false so the PR is a no-op for existing deployments.')
param enableVmssLinux bool = false

@description('Enable the vmss-windows tier (Windows Server 2022 on VMSS Flex with Docker CE, WSL2, Hyper-V). Defaults to false so the PR is a no-op for existing deployments.')
param enableVmssWindows bool = false

@description('Enable the Ubuntu AIB template + image definition without provisioning the VMSS tier. Used to break the VMSS-vs-AIB chicken-and-egg: bake at least one image version first (enableAibUbuntu=true, enableVmssLinux=false), then enable the VMSS tier. Defaults to enableVmssLinux so existing behaviour is preserved.')
param enableAibUbuntu bool = enableVmssLinux

@description('Enable the Windows AIB template + image definition without provisioning the VMSS tier. See enableAibUbuntu for rationale. Defaults to enableVmssWindows so existing behaviour is preserved.')
param enableAibWindows bool = enableVmssWindows

@description('Maximum concurrent VMSS instances for the Linux tier. Enforced by the launcher ACA Job replica cap, which mirrors KEDA scale-out capacity.')
param vmssLinuxMaxInstances int = 10

@description('Maximum concurrent VMSS instances for the Windows tier.')
param vmssWindowsMaxInstances int = 10

@description('Idle retention window for vmss-linux warm reuse (sliding; resets after every job). Set 0 to disable (legacy 1:1 ephemeral). Default 60 min.')
param vmssLinuxIdleRetentionMinutes int = 60

@description('Idle retention window for vmss-windows warm reuse. Set 0 to disable (legacy 1:1 ephemeral). Default 60 min.')
param vmssWindowsIdleRetentionMinutes int = 60

@description('Hard lifetime cap for a vmss-linux VM. Recycles on whichever fires first (idle or age). Default 12 h (matches GitHub\'s max job timeout). 0 = no cap.')
param vmssLinuxMaxLifetimeHours int = 12

@description('Hard lifetime cap for a vmss-windows VM. Default 12 h. 0 = no cap.')
param vmssWindowsMaxLifetimeHours int = 12

@description('Optional sub-hour lifetime override for vmss-linux (#100). When >0, overrides vmssLinuxMaxLifetimeHours in the watchdog so VMs can be capped at minute granularity — primarily for CI tests that need to exercise the hard cap in under an hour. 0 (default) = fall through to vmssLinuxMaxLifetimeHours.')
@minValue(0)
param vmssLinuxMaxLifetimeMinutes int = 0

@description('Optional sub-hour lifetime override for vmss-windows (#100). When >0, overrides vmssWindowsMaxLifetimeHours. 0 (default) = fall through to hours.')
@minValue(0)
param vmssWindowsMaxLifetimeMinutes int = 0

@description('VM size used for the vmss-linux tier and AIB build VMs. Must support ephemeral OS on resource disk; default Standard_D4ds_v5 has a ~150 GB NVMe resource disk which fits the Ubuntu 22.04 AIB image (~50 GB).')
param vmssVmSize string = 'Standard_D4ds_v5'

@description('VM size used for the vmss-windows tier. Windows images are baked at 150 GB (see aib-windows.bicep osDiskSizeGB) and Azure rejects ephemeral OS >149 GB on Standard_D4ds_v5 with ResourceDisk. Standard_D8ds_v5 has a ~300 GB resource disk which comfortably fits. Override only if you shrink the Windows AIB image.')
param vmssWindowsVmSize string = 'Standard_D8ds_v5'

@description('VM priority for the vmss-linux tier. "Spot" yields ~60-90% cost savings but VMs may be evicted on capacity pressure. Ephemeral CI runners tolerate eviction well — KEDA simply re-launches a fresh instance. Default "Spot".')
@allowed([
  'Regular'
  'Spot'
])
param vmssLinuxPriority string = 'Spot'

@description('VM priority for the vmss-windows tier. See vmssLinuxPriority. Default "Spot".')
@allowed([
  'Regular'
  'Spot'
])
param vmssWindowsPriority string = 'Spot'

@description('Maximum hourly USD price for vmss-linux Spot VMs. -1 (default) = pay up to current on-demand price; eviction only on capacity pressure. Ignored when vmssLinuxPriority=Regular.')
param vmssLinuxSpotMaxPrice int = -1

@description('Maximum hourly USD price for vmss-windows Spot VMs. -1 (default) = pay up to current on-demand price; eviction only on capacity pressure. Ignored when vmssWindowsPriority=Regular.')
param vmssWindowsSpotMaxPrice int = -1

@description('Compute Gallery image version used by the vmss-linux tier. Default "latest" pins to the newest weekly bake. Set to a specific YYYYMMDD.HHmm (e.g. "20250419.0830") to roll back from a broken bake.')
param vmssLinuxImageVersion string = 'latest'

@description('Compute Gallery image version used by the vmss-windows tier. Default "latest" pins to the newest weekly bake. Set to a specific YYYYMMDD.HHmm to roll back from a broken bake.')
param vmssWindowsImageVersion string = 'latest'

@description('SSH public key for the vmss-linux admin user. Auto-generated fresh by deploy.yml on every run when enableVmssLinux is true; operators do not manage this value. Ignored when enableVmssLinux is false. Marked @secure() to keep the key out of deployment output objects (the public half is not confidential, but the marker prevents accidental leakage into logs).')
@secure()
param vmssLinuxAdminSshPublicKey string = ''

@description('40-character commit SHA of actions/runner-images pinned for the weekly AIB bake. Empty = fail fast at AIB run time; only needed if either VMSS tier is enabled AND you trigger build-vhds.yml.')
param vmssRunnerImagesCommit string = ''

@description('Address space (CIDR) for the shared VNet (vnet-<base>) created by this deployment. Must be at least /23 to accommodate all three non-overlapping subnets (snet-vmss 10.42.0.0/26, snet-aib-build 10.42.1.0/27, snet-aib-aci 10.42.1.32/27). Override only if 10.42.0.0/23 clashes with another network.')
param vmssVnetAddressPrefix string = '10.42.0.0/23'

@description('Address range (CIDR) for the single VMSS subnet inside the VNet above. Must be contained in vmssVnetAddressPrefix.')
param vmssSubnetAddressPrefix string = '10.42.0.0/26'

@description('Optional suffix appended to the VMSS runner label list (both Linux and Windows tiers) for tenancy / test isolation. When non-empty, registered labels become e.g. "self-hosted,linux,vmss,<suffix>" and the KEDA scaler only matches queued jobs carrying that same suffix. Default empty = pre-#99 behaviour (labels unchanged). Does not affect the ACA (aca-linux / aci-windows) tiers.')
param vmssRunnerLabelSuffix string = ''

// ─── Parameter validation ────────────────────────────────────────────────────
// runnerScope='repo' requires a non-empty githubRepo. Without it, downstream
// modules emit broken registration URLs (https://github.com/OWNER/), broken
// token endpoints (POST /repos/OWNER//actions/runners/registration-token)
// and KEDA metadata with repos=''. substring() with an out-of-range index is
// a deterministic deploy-time error in ARM; multiplying a deploy-time value
// keeps the index opaque to Bicep's static analyser so it fails at deploy
// time (as intended) rather than being caught by BCP327 at compile time.
// The message is embedded in the source string so it appears in ARM's error
// output. The guard is embedded in the `tags` variable below so that ARM
// evaluates it during template-expansion/preflight (before any resource is
// created), not only at post-deployment output evaluation.
var _guardOutOfRangeIndex = length(resourceGroup().id) * 999
var _assertRunnerScopeHasRepoName = (runnerScope == 'repo' && empty(githubRepo))
  ? substring('ERROR_runnerScope_repo_requires_non_empty_githubRepo_see_docs_SCOPES_md', _guardOutOfRangeIndex, 1)
  : 'ok'

var _assertVmssLinuxHasSshKey = (enableVmssLinux && empty(vmssLinuxAdminSshPublicKey))
  ? substring('ERROR_enableVmssLinux_requires_non_empty_vmssLinuxAdminSshPublicKey_deploy_yml_should_auto_generate', _guardOutOfRangeIndex, 1)
  : 'ok'

// ─── Variables ────────────────────────────────────────────────────────────────

var baseName = '${namingPrefix}-gh-runners-${locationAbbreviation}'

// ACR names must be lowercase alphanumeric, 5–50 chars, globally unique.
var acrName = toLower(replace(replace('cr${namingPrefix}ghrunners${locationAbbreviation}', '-', ''), '_', ''))

// Key Vault names must be 3-24 chars, lowercase alphanumeric + hyphens, globally unique,
// start with a letter and end with a letter or digit. We strip separators and truncate to
// 24 chars; with the 10-char namingPrefix cap the untruncated form is at most 24 chars.
var kvFullName = toLower(replace(replace('kv${namingPrefix}ghrunners${locationAbbreviation}', '-', ''), '_', ''))
var kvName = length(kvFullName) > 24 ? substring(kvFullName, 0, 24) : kvFullName

var tags = {
  project: 'actions-runners-az-container-apps'
  managedBy: 'bicep'
}

// Convenience flag — any VMSS tier enabled means we need the shared gallery,
// the vmss-launcher UAMI, the AIB UAMI, and the runner self-delete role.
var vmssEnabled = enableVmssLinux || enableVmssWindows || enableAibUbuntu || enableAibWindows

// Compute Gallery names disallow hyphens; strip them from baseName.
var galleryName = 'gal_${replace(baseName, '-', '_')}'

// Parameter validation must be evaluated at template-expansion/preflight time
// (before any resource is created). We achieve this by merging the guarded
// variable into a single module's tags — referencing the variable forces ARM
// to evaluate the substring() guard during preflight. Keeping it on a single
// resource (the LAW module) avoids polluting every resource's tags with an
// internal validation marker.
var tagsWithValidation = union(tags, {
  _parameterValidation: _assertRunnerScopeHasRepoName
  _vmssLinuxSshGuard: _assertVmssLinuxHasSshKey
})

// ─── VMSS Linux cloud-init (customData) ──────────────────────────────────────
// Self-contained cloud-init payload injected into each VMSS Linux instance via
// osProfile.customData. Because the AIB base image is minimal (docker, jq,
// curl, git only), cloud-init is responsible for installing azure-cli, the
// actions-runner binary, the bootstrap/watchdog scripts, systemd units, and
// the ghrunner user on first boot. See scripts/vm-bootstrap/linux/cloud-init-full.yml
// and firstboot.sh for the on-instance orchestration. The __*_B64__ markers
// below are replaced with base64-encoded file contents so cloud-init can write
// them verbatim via `encoding: b64`.
var vmssLinuxCloudInit = replace(replace(replace(replace(replace(replace(replace(
  loadTextContent('../scripts/vm-bootstrap/linux/cloud-init-full.yml'),
  '__BOOTSTRAP_SH_B64__',              base64(loadTextContent('../scripts/vm-bootstrap/linux/bootstrap.sh'))),
  '__WATCHDOG_SH_B64__',               base64(loadTextContent('../scripts/vm-bootstrap/linux/watchdog.sh'))),
  '__HOOK_STARTED_SH_B64__',           base64(loadTextContent('../scripts/vm-bootstrap/linux/hooks/job-started.sh'))),
  '__HOOK_COMPLETED_SH_B64__',         base64(loadTextContent('../scripts/vm-bootstrap/linux/hooks/job-completed.sh'))),
  '__GH_RUNNER_SERVICE_B64__',         base64(loadTextContent('../scripts/vm-bootstrap/linux/systemd/gh-runner.service'))),
  '__GH_RUNNER_WATCHDOG_SERVICE_B64__', base64(loadTextContent('../scripts/vm-bootstrap/linux/systemd/gh-runner-watchdog.service'))),
  '__GH_RUNNER_WATCHDOG_TIMER_B64__',  base64(loadTextContent('../scripts/vm-bootstrap/linux/systemd/gh-runner-watchdog.timer')))
var vmssLinuxCustomDataB64 = base64(vmssLinuxCloudInit)

// ─── Modules ─────────────────────────────────────────────────────────────────

module law 'modules/law.bicep' = {
  name: 'law-deploy'
  params: {
    name: 'law-${baseName}'
    location: location
    tags: tagsWithValidation
  }
}

module acr 'modules/acr.bicep' = {
  name: 'acr-deploy'
  params: {
    name: acrName
    location: location
    tags: tags
    logAnalyticsWorkspaceId: law.outputs.id
  }
}

module acrPurge 'modules/acr-purge-task.bicep' = {
  name: 'acr-purge-task-deploy'
  params: {
    acrName: acr.outputs.name
    location: location
    tags: tags
  }
}

// Azure Compute Gallery — shared across both VMSS tiers. Created only when at
// least one VMSS tier is enabled. Declared before identity so identity can
// receive the real gallery resource ID for the AIB "Image Contributor" role
// assignment without a forward reference.
module gallery 'modules/image-gallery.bicep' = if (vmssEnabled) {
  name: 'image-gallery-deploy'
  params: {
    name: galleryName
    location: location
    tags: tags
    baseName: baseName
  }
}

module identity 'modules/identity.bicep' = {
  name: 'identity-deploy'
  params: {
    name: 'id-${baseName}'
    location: location
    tags: tags
    acrName: acr.outputs.name
    enableVmss: vmssEnabled
    enableAib: vmssEnabled
    enableRunnerSelfDelete: vmssEnabled
    // VMSS-scoped role assignments are handled by modules/vmss-rbac.bicep
    // per tier, to avoid a chicken-and-egg dependency between identity
    // outputs and the VMSS resource IDs themselves.
    vmssResourceIds: []
    galleryResourceId: vmssEnabled ? gallery.outputs.galleryId : ''
    logAnalyticsResourceId: law.outputs.id
  }
}

// NOTE: legacy RG-scoped role cleanup (Contributor, AcrPull, Container Instance Contributor)
// previously lived in modules/cleanup-stale-roles.bicep as a deploymentScript. That approach
// requires a storage account with key-based auth, which tenant policy blocks on this
// subscription. Cleanup of any pre-#14 stale role assignments is now performed by the
// "Cleanup legacy role assignments" step in .github/workflows/deploy.yml using the
// OIDC-authenticated deployment SP (issue: deployment-script storage key policy).

// Key Vault holds the base64-encoded GitHub App PEM. Both runner ACA Jobs reference
// the secret via keyVaultUrl + identity, so the decoded secret never appears as an
// inline value in the compiled ARM template. Must be deployed after identity.bicep
// because the two runner/launcher managed identities need Key Vault Secrets User
// role assignments on the vault before the jobs try to resolve the secret.
module keyvault 'modules/keyvault.bicep' = {
  name: 'keyvault-deploy'
  params: {
    name: kvName
    location: location
    tags: tags
    githubAppPemB64: githubAppPemB64
    runnerPrincipalId: identity.outputs.runnerPrincipalId
    launcherPrincipalId: identity.outputs.launcherPrincipalId
  }
}

// Resolve the LAW shared key to pass to the Container Apps environment.
// Using an existing reference so we can call listKeys() without storing the key as an output.
resource lawRef 'Microsoft.OperationalInsights/workspaces@2025-02-01' existing = {
  name: 'law-${baseName}'
}

// Cache the LAW shared key once. ARM treats listKeys() results as secret and
// redacts them in deployment outputs/logs; Bicep `var` preserves that redaction
// when assigned to @secure() module params.
var logAnalyticsSharedKey = lawRef.listKeys().primarySharedKey

module cae 'modules/cae.bicep' = {
  name: 'cae-deploy'
  params: {
    name: 'cae-${baseName}'
    location: location
    tags: tags
    logAnalyticsCustomerId: law.outputs.customerId
    logAnalyticsSharedKey: logAnalyticsSharedKey
    logAnalyticsWorkspaceId: law.outputs.id
  }
}

module linuxRunner 'modules/linux-runner.bicep' = {
  name: 'linux-runner-deploy'
  params: {
    name: 'caj-linux-${namingPrefix}-${locationAbbreviation}'
    location: location
    tags: tags
    environmentId: cae.outputs.id
    acrLoginServer: acr.outputs.loginServer
    managedIdentityId: identity.outputs.runnerId
    githubOwner: githubOwner
    githubRepo: githubRepo
    runnerScope: runnerScope
    githubAppId: githubAppId
    githubInstallationId: githubInstallationId
    keyVaultSecretUri: keyvault.outputs.pemSecretUri
    githubAppPemB64: githubAppPemB64
    maxExecutions: linuxMaxExecutions
  }
}

module windowsLauncher 'modules/windows-launcher.bicep' = {
  name: 'windows-launcher-deploy'
  params: {
    name: 'caj-win-launcher-${namingPrefix}-${locationAbbreviation}'
    location: location
    tags: tags
    environmentId: cae.outputs.id
    acrLoginServer: acr.outputs.loginServer
    managedIdentityId: identity.outputs.launcherId
    managedIdentityClientId: identity.outputs.launcherClientId
    subscriptionId: subscription().subscriptionId
    resourceGroupName: resourceGroup().name
    githubOwner: githubOwner
    githubRepo: githubRepo
    runnerScope: runnerScope
    githubAppId: githubAppId
    githubInstallationId: githubInstallationId
    keyVaultSecretUri: keyvault.outputs.pemSecretUri
    githubAppPemB64: githubAppPemB64
    maxExecutions: windowsMaxExecutions
    windowsAciLocation: windowsAciLocation
    logAnalyticsCustomerId: law.outputs.customerId
    logAnalyticsWorkspaceName: law.outputs.name
    launcherPrincipalId: identity.outputs.launcherPrincipalId
  }
}

// ─── Shared network (VMSS + AIB) ─────────────────────────────────────────────
// Single VNet + single NAT Gateway + three subnets with strong east-west NSG
// isolation. Used by both VMSS runner tiers and both AIB image-bake tiers.
// Created only when at least one VMSS or AIB tier is enabled, so a fully ACA
// deploy still has zero network footprint.

module network 'modules/network.bicep' = if (vmssEnabled) {
  name: 'network-deploy'
  params: {
    name: baseName
    location: location
    tags: tags
    vnetAddressPrefix: vmssVnetAddressPrefix
    vmssSubnetAddressPrefix: vmssSubnetAddressPrefix
    aibPrincipalId: (enableAibUbuntu || enableAibWindows) ? identity.outputs.aibPrincipalId : ''
  }
}

// ─── VMSS tier: Linux ────────────────────────────────────────────────────────
// Bakes an Ubuntu 22.04 image via AIB, runs VMSS Flex with ephemeral OS, and
// scales via a dedicated ACA Job launcher. All wiring gated by enableVmssLinux.

module aibUbuntu 'modules/aib-ubuntu.bicep' = if (enableAibUbuntu) {
  name: 'aib-ubuntu-deploy'
  params: {
    name: 'aib-ubuntu-${baseName}'
    location: location
    tags: tags
    aibIdentityId: identity.outputs.aibId
    galleryImageId: gallery.outputs.linuxImageDefinitionId
    buildVmSize: vmssVmSize
    vmssRunnerImagesCommit: vmssRunnerImagesCommit
    buildSubnetId: network.outputs.aibBuildSubnetId
    aciSubnetId: network.outputs.aibAciSubnetId
  }
}

module vmssLinux'modules/vmss-linux.bicep' = if (enableVmssLinux) {
  name: 'vmss-linux-deploy'
  params: {
    name: 'vmss-lnx-${namingPrefix}-${locationAbbreviation}'
    location: location
    tags: union(tags, {
      ghRunnerIdleRetentionMinutes: string(vmssLinuxIdleRetentionMinutes)
      ghRunnerMaxLifetimeHours: string(vmssLinuxMaxLifetimeHours)
      ghRunnerMaxLifetimeMinutes: string(vmssLinuxMaxLifetimeMinutes)
    })
    vmSize: vmssVmSize
    imageReferenceId: gallery.outputs.linuxImageDefinitionId
    imageVersion: vmssLinuxImageVersion
    runnerIdentityId: identity.outputs.runnerId
    subnetId: network.outputs.vmssSubnetId
    maxInstances: vmssLinuxMaxInstances
    adminSshPublicKey: vmssLinuxAdminSshPublicKey
    customDataBase64: vmssLinuxCustomDataB64
    priority: vmssLinuxPriority
    spotMaxPrice: vmssLinuxSpotMaxPrice
  }
}

module vmssLinuxRbac'modules/vmss-rbac.bicep' = if (enableVmssLinux) {
  name: 'vmss-linux-rbac-deploy'
  params: {
    vmssName: vmssLinux.outputs.vmssName
    launcherPrincipalId: identity.outputs.launcherPrincipalId
    runnerPrincipalId: identity.outputs.runnerPrincipalId
    enableRunnerSelfDelete: vmssLinuxIdleRetentionMinutes > 0 || vmssLinuxMaxLifetimeHours > 0 || vmssLinuxMaxLifetimeMinutes > 0
  }
}

module vmssLinuxLauncher 'modules/vmss-launcher.bicep' = if (enableVmssLinux) {
  name: 'vmss-linux-launcher-deploy'
  params: {
    name: 'caj-vmss-lnx-launcher-${namingPrefix}-${locationAbbreviation}'
    location: location
    tags: tags
    runnerOs: 'linux'
    vmssName: vmssLinux.outputs.vmssName
    containerAppEnvironmentId: cae.outputs.id
    acrLoginServer: acr.outputs.loginServer
    launcherIdentityId: identity.outputs.launcherId
    launcherIdentityClientId: identity.outputs.launcherClientId
    runnerIdentityResourceId: identity.outputs.runnerId
    runnerIdentityClientId: identity.outputs.runnerClientId
    keyVaultUrl: keyvault.outputs.keyVaultUri
    keyVaultName: keyvault.outputs.keyVaultName
    pemSecretUri: keyvault.outputs.pemSecretUri
    logAnalyticsWorkspaceResourceId: law.outputs.id
    githubAppPemB64: githubAppPemB64
    runnerScope: runnerScope
    githubOrg: githubOwner
    githubRepo: githubRepo
    githubAppId: githubAppId
    githubInstallationId: githubInstallationId
    maxExecutions: vmssLinuxMaxInstances
    idleRetentionMinutes: vmssLinuxIdleRetentionMinutes
    maxLifetimeHours: vmssLinuxMaxLifetimeHours
    maxLifetimeMinutes: vmssLinuxMaxLifetimeMinutes
    runnerLabelSuffix: vmssRunnerLabelSuffix
  }
}

// ─── VMSS tier: Windows ──────────────────────────────────────────────────────

module aibWindows 'modules/aib-windows.bicep' = if (enableAibWindows) {
  name: 'aib-windows-deploy'
  params: {
    name: 'aib-windows-${baseName}'
    location: location
    tags: tags
    aibIdentityId: identity.outputs.aibId
    galleryImageId: gallery.outputs.windowsImageDefinitionId
    buildVmSize: vmssVmSize
    vmssRunnerImagesCommit: vmssRunnerImagesCommit
    buildSubnetId: network.outputs.aibBuildSubnetId
    aciSubnetId: network.outputs.aibAciSubnetId
  }
}

module vmssWindows'modules/vmss-windows.bicep' = if (enableVmssWindows) {
  name: 'vmss-windows-deploy'
  params: {
    name: 'vmss-win-${namingPrefix}-${locationAbbreviation}'
    location: location
    tags: union(tags, {
      ghRunnerIdleRetentionMinutes: string(vmssWindowsIdleRetentionMinutes)
      ghRunnerMaxLifetimeHours: string(vmssWindowsMaxLifetimeHours)
      ghRunnerMaxLifetimeMinutes: string(vmssWindowsMaxLifetimeMinutes)
    })
    vmSize: vmssWindowsVmSize
    imageReferenceId: gallery.outputs.windowsImageDefinitionId
    imageVersion: vmssWindowsImageVersion
    runnerIdentityId: identity.outputs.runnerId
    subnetId: network.outputs.vmssSubnetId
    maxInstances: vmssWindowsMaxInstances
    priority: vmssWindowsPriority
    spotMaxPrice: vmssWindowsSpotMaxPrice
  }
}

module vmssWindowsRbac 'modules/vmss-rbac.bicep' = if (enableVmssWindows) {
  name: 'vmss-windows-rbac-deploy'
  params: {
    vmssName: vmssWindows.outputs.vmssName
    launcherPrincipalId: identity.outputs.launcherPrincipalId
    runnerPrincipalId: identity.outputs.runnerPrincipalId
    enableRunnerSelfDelete: vmssWindowsIdleRetentionMinutes > 0 || vmssWindowsMaxLifetimeHours > 0 || vmssWindowsMaxLifetimeMinutes > 0
  }
}

module vmssWindowsLauncher 'modules/vmss-launcher.bicep' = if (enableVmssWindows) {
  name: 'vmss-windows-launcher-deploy'
  params: {
    name: 'caj-vmss-win-launcher-${namingPrefix}-${locationAbbreviation}'
    location: location
    tags: tags
    runnerOs: 'windows'
    vmssName: vmssWindows.outputs.vmssName
    containerAppEnvironmentId: cae.outputs.id
    acrLoginServer: acr.outputs.loginServer
    launcherIdentityId: identity.outputs.launcherId
    launcherIdentityClientId: identity.outputs.launcherClientId
    runnerIdentityResourceId: identity.outputs.runnerId
    runnerIdentityClientId: identity.outputs.runnerClientId
    keyVaultUrl: keyvault.outputs.keyVaultUri
    keyVaultName: keyvault.outputs.keyVaultName
    pemSecretUri: keyvault.outputs.pemSecretUri
    logAnalyticsWorkspaceResourceId: law.outputs.id
    githubAppPemB64: githubAppPemB64
    runnerScope: runnerScope
    githubOrg: githubOwner
    githubRepo: githubRepo
    githubAppId: githubAppId
    githubInstallationId: githubInstallationId
    maxExecutions: vmssWindowsMaxInstances
    idleRetentionMinutes: vmssWindowsIdleRetentionMinutes
    maxLifetimeHours: vmssWindowsMaxLifetimeHours
    maxLifetimeMinutes: vmssWindowsMaxLifetimeMinutes
    runnerLabelSuffix: vmssRunnerLabelSuffix
  }
}

// ─── Outputs ─────────────────────────────────────────────────────────────────

output acrLoginServer string = acr.outputs.loginServer
output acrName string = acr.outputs.name
output keyVaultName string = keyvault.outputs.keyVaultName
output keyVaultUri string = keyvault.outputs.keyVaultUri
output runnerIdentityClientId string = identity.outputs.runnerClientId
output launcherIdentityClientId string = identity.outputs.launcherClientId
output linuxRunnerJobName string = linuxRunner.outputs.name
output windowsLauncherJobName string = windowsLauncher.outputs.name
output galleryName string = vmssEnabled ? gallery.outputs.galleryName : ''
output vmssLinuxName string = enableVmssLinux ? vmssLinux.outputs.vmssName : ''
output vmssWindowsName string = enableVmssWindows ? vmssWindows.outputs.vmssName : ''
output vmssLinuxLauncherJobName string = enableVmssLinux ? vmssLinuxLauncher.outputs.jobName : ''
output vmssWindowsLauncherJobName string = enableVmssWindows ? vmssWindowsLauncher.outputs.jobName : ''
output vmssSubnetId string = vmssEnabled ? network.outputs.vmssSubnetId : ''
