@description('Azure region for the identities.')
param location string

@description('Base name used for both identities. The runner uses this name as-is; the launcher appends "-launcher".')
param name string

@description('Name of the ACR instance. AcrPull is scoped to this resource (not the resource group) to respect least privilege — issue #14.')
param acrName string

@description('Resource tags.')
param tags object = {}

@description('Feature flag: create the VMSS launcher UAMI and its role assignments. Defaults to false so existing deploys are byte-for-byte identical.')
param enableVmss bool = false

@description('Feature flag: create the Azure Image Builder (AIB) UAMI and its role assignments. Defaults to false so existing deploys are byte-for-byte identical.')
param enableAib bool = false

@description('Resource IDs of the VMSS instances the vmssLauncher must manage. Role assignments are scoped to each VMSS (not the RG) for least privilege. Populated by main.bicep after the VMSS modules are created.')
param vmssResourceIds array = []

@description('Resource ID of the Azure Compute Gallery used by AIB. Required when enableAib = true.')
param galleryResourceId string = ''

@description('Resource ID of the Log Analytics workspace. Required when enableVmss = true — the vmssLauncher needs Log Analytics Contributor on the workspace to pipe shared keys to new VMSS instances.')
param logAnalyticsResourceId string = ''

@description('Resource ID of the AIB staging resource group. Currently unused — AIB auto-creates an IT_* staging RG under the subscription, and we cannot pre-create it from RG-scope Bicep. Reserved for a future subscription-scope deployment that provisions a dedicated staging RG and grants the AIB UAMI Contributor on *only* that RG (see issue #97 TODO in the AIB section).')
#disable-next-line no-unused-params
param stagingResourceGroupId string = ''

@description('Feature flag: grant the runner UAMI Virtual Machine Contributor scoped to each VMSS in vmssResourceIds so a warm VM can self-delete after the idle retention window. Defaults to false (legacy 1:1 ephemeral behaviour).')
param enableRunnerSelfDelete bool = false

// Role definition IDs
// AcrPull                         — allows image pulls from the specific ACR
// Container Instance Contributor  — allows create/read/delete of ACI container groups on the RG
// Managed Identity Operator       — allows assigning a UAMI to a resource (ACI in this case).
//                                   Required because the launcher attaches its own UAMI to the
//                                   spawned Windows ACI via --assign-identity / --acr-identity.
//                                   Without this role, ARM returns LinkedAuthorizationFailed.
// Virtual Machine Contributor     — create/delete VMs and VMSS instances; does NOT grant data-plane
//                                   access to the guest OS.
// Log Analytics Contributor       — listKeys() on a LAW; required for the launcher to forward the
//                                   shared key to new VMSS instances.
// Contributor                     — broad: used only for AIB on the Compute Gallery
//                                   (RG-wide assignment removed per issue #97).
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var containerInstanceContributorRoleId = '5d977122-f97e-4b4d-a52f-6b43003ddb4d'
var managedIdentityOperatorRoleId = 'f1a07417-d97a-45cb-824c-7a7467783830'
var virtualMachineContributorRoleId = '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
var logAnalyticsContributorRoleId = '92aaf0da-9dab-42b6-94a3-d43ce8d16293'
var contributorRoleId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'

// Reference the ACR so we can scope the AcrPull role assignment narrowly to this resource.
resource acr 'Microsoft.ContainerRegistry/registries@2025-11-01' existing = {
  name: acrName
}

// ─── Runner identity ─────────────────────────────────────────────────────────
// Used by both the Linux ACA Job and (historically) the Windows launcher for ACR pulls.
// Only gets AcrPull on the ACR itself. Nothing on the RG.
resource runnerIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: name
  location: location
  tags: tags
}

resource runnerAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(runnerIdentity.id, acr.id, acrPullRoleId)
  scope: acr
  properties: {
    principalId: runnerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    description: 'AcrPull for runner managed identity (scoped to ACR — issue #14)'
  }
}

// ─── Launcher identity ───────────────────────────────────────────────────────
// Used by the Windows launcher ACA Job. Needs to pull its own image and create/delete ACI groups.
// AcrPull is scoped to the ACR; Container Instance Contributor is scoped to the RG.
// Crucially: this identity does NOT have broad Contributor on the RG — issue #14.
resource launcherIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: '${name}-launcher'
  location: location
  tags: tags
}

resource launcherAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(launcherIdentity.id, acr.id, acrPullRoleId)
  scope: acr
  properties: {
    principalId: launcherIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    description: 'AcrPull for Windows launcher managed identity (scoped to ACR — issue #14)'
  }
}

resource launcherAciContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(launcherIdentity.id, resourceGroup().id, containerInstanceContributorRoleId)
  scope: resourceGroup()
  properties: {
    principalId: launcherIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      containerInstanceContributorRoleId
    )
    description: 'Container Instance Contributor on RG — Windows launcher only; runner identity deliberately has nothing here (issue #14).'
  }
}

// Managed Identity Operator on the launcher UAMI itself. Required so that when the
// launcher calls `az container create --assign-identity/--acr-identity <this UAMI>`,
// ARM allows the linked Microsoft.ManagedIdentity/userAssignedIdentities/assign/action.
// Without this, ACI creation fails with LinkedAuthorizationFailed.
resource launcherSelfMiOperator 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(launcherIdentity.id, managedIdentityOperatorRoleId, 'self')
  scope: launcherIdentity
  properties: {
    principalId: launcherIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      managedIdentityOperatorRoleId
    )
    description: 'Managed Identity Operator on self — required for ACI --assign-identity / --acr-identity to succeed (avoids LinkedAuthorizationFailed).'
  }
}

output runnerId string = runnerIdentity.id
output runnerPrincipalId string = runnerIdentity.properties.principalId
output runnerClientId string = runnerIdentity.properties.clientId
output launcherId string = launcherIdentity.id
output launcherPrincipalId string = launcherIdentity.properties.principalId
output launcherClientId string = launcherIdentity.properties.clientId

// ─── Consolidated launcher identity — VMSS-specific RBAC extensions ──────────
// The VMSS launcher ACA Jobs (Linux + Windows tiers) now reuse the same
// `launcherIdentity` UAMI as the Windows ACI launcher. Originally we had a
// dedicated `id-<base>-vmss-launcher` UAMI, but ACA KV secret resolution
// consistently failed validation against freshly created UAMIs even with
// identical RBAC and 15+ minute propagation waits — a platform-side caching
// behaviour we could not work around. The shared launcher UAMI has a battle-
// tested KV role assignment and works reliably.
//
// Blast-radius trade-off: the unified launcher now holds ACI Contributor on
// the RG AND VM Contributor on each VMSS. A compromised container could, in
// theory, create ACI groups from the VMSS launcher or mutate VMSS instances
// from the ACI launcher. Both paths stay within the same RG (no elevation),
// and the two launcher containers only execute their own OS-specific code,
// so we accept this in exchange for a simpler identity model (3 UAMIs instead
// of 4) and an unblocked VMSS deploy.
//
// When enableVmss is true we additionally grant the shared launcher:
//   - Virtual Machine Contributor on each target VMSS (scoped, not RG)
//   - Managed Identity Operator on the runner UAMI (so `az vmss ... --assign-identity`
//     can attach the runner UAMI to new instances without LinkedAuthorizationFailed)
//   - Log Analytics Contributor on the LAW (so the entrypoint can listKeys()
//     and forward the shared key to new VMSS instances)

// Referenced VMSS resources — declared as existing so we can scope role assignments
// to each VMSS. Names are derived from the resource IDs passed in by main.bicep.
// Loop is a no-op when vmssResourceIds is empty (the default when enableVmss is false).
resource vmssRefs 'Microsoft.Compute/virtualMachineScaleSets@2024-07-01' existing = [for id in vmssResourceIds: {
  name: last(split(id, '/'))
}]

resource launcherVmssVmContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (id, i) in vmssResourceIds: if (enableVmss) {
  name: guid(id, 'launcher', virtualMachineContributorRoleId)
  scope: vmssRefs[i]
  properties: {
    principalId: launcherIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', virtualMachineContributorRoleId)
    description: 'Virtual Machine Contributor for the shared launcher UAMI — scoped to this specific VMSS so the launcher can add/remove instances.'
  }
}]

// Flex VMSS instances are also exposed as first-class Microsoft.Compute/virtualMachines
// resources, and PATCH against that path (for tag stamping) requires RBAC on the VM
// scope — the VMSS-scoped assignment above does NOT propagate because the child VMs
// live under a separate ARM resource hierarchy. Grant Virtual Machine Contributor at
// RG scope so the launcher can PATCH tags on VMSS instances created in Flex mode.
// Scope is RG (not subscription), and the role only grants compute VM/VMSS actions,
// so blast radius is bounded to compute resources in this RG.
resource launcherRgVmContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableVmss) {
  name: guid(resourceGroup().id, 'launcher', virtualMachineContributorRoleId)
  scope: resourceGroup()
  properties: {
    principalId: launcherIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', virtualMachineContributorRoleId)
    description: 'Virtual Machine Contributor on RG — required so the launcher can PATCH tags on Flex VMSS instances via the Microsoft.Compute/virtualMachines/{name} path (the per-VMSS assignment does not cover this alternative ARM surface).'
  }
}

resource launcherRunnerMiOperator 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableVmss) {
  name: guid(runnerIdentity.id, 'launcher', managedIdentityOperatorRoleId)
  scope: runnerIdentity
  properties: {
    principalId: launcherIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', managedIdentityOperatorRoleId)
    description: 'Managed Identity Operator on the runner UAMI — required so the launcher can attach the runner UAMI to new VMSS instances.'
  }
}

// Existing LAW reference — only resolved when enableVmss is true.
resource launcherLawRef 'Microsoft.OperationalInsights/workspaces@2025-02-01' existing = if (enableVmss) {
  name: last(split(logAnalyticsResourceId, '/'))
}

resource launcherLawContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableVmss) {
  name: guid(logAnalyticsResourceId, 'launcher', logAnalyticsContributorRoleId)
  scope: launcherLawRef
  properties: {
    principalId: launcherIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', logAnalyticsContributorRoleId)
    description: 'Log Analytics Contributor for the shared launcher UAMI — required to listKeys() on the workspace so new VMSS instances can be enrolled in LAW without baking the key into a Bicep secret.'
  }
}

// ─── Runner self-delete (warm retention, issue: VMSS runner tiers) ───────────
// When enabled, the runner UAMI attached to each VMSS instance is granted
// Virtual Machine Contributor on its parent VMSS only. This lets the in-VM
// watchdog deregister from GitHub and then delete its own VM via the instance
// metadata service once the idle retention window elapses. Scope is deliberately
// the VMSS (not the RG) so one VM cannot act on siblings in other tiers.
resource runnerVmssContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (id, i) in vmssResourceIds: if (enableRunnerSelfDelete) {
  name: guid(id, 'runner-self-delete', virtualMachineContributorRoleId)
  scope: vmssRefs[i]
  properties: {
    principalId: runnerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', virtualMachineContributorRoleId)
    description: 'Virtual Machine Contributor for runner UAMI — scoped to this VMSS so a warm VM can self-delete after idle retention expires.'
  }
}]

// ─── AIB identity (issue: VMSS runner tiers, hardened per issue #97) ─────────
// Used by Azure Image Builder to stage VHDs and publish image versions to the
// Compute Gallery.
//
// Previously this UAMI held Contributor on the entire resource group (LOW
// severity finding in #97). That is far broader than needed: AIB only needs
// rights on (a) its own image template resources, (b) the target Compute
// Gallery, and (c) the staging resource group where it provisions the build
// VM/disk/NIC.
//
// The current hardening (what's implemented here):
//   - Contributor is scoped to each image template resource passed in via
//     aibImageTemplateIds — this lets AIB mutate/run the templates themselves.
//   - Contributor stays scoped to the Compute Gallery — AIB needs to publish
//     image versions there (there is no narrower built-in; "Gallery Image
//     Version Contributor" does not exist as a built-in role as of 2026-04).
//
// TODO (issue #97, remaining hardening — requires subscription-scope Bicep):
//   When `stagingResourceGroup` is left empty on the image templates (current
//   default), AIB auto-creates an `IT_<rg>_<template>_<guid>` staging RG under
//   the subscription at image build time. The AIB UAMI needs Contributor on
//   that RG to stage the build VM. Because the RG name is generated by the AIB
//   service at runtime, we cannot pre-create it from Bicep. Options:
//     1. Switch main.bicep to subscription-scope and deploy a dedicated
//        staging RG, then set `stagingResourceGroup` on the image templates
//        and grant Contributor only on that RG.
//     2. Grant Contributor at subscription scope (worse than the RG-wide
//        assignment we just removed — do NOT do this).
//     3. Have an operator grant Contributor manually on the IT_* RG after the
//        first image build fails and the RG is created.
//   Option 1 is the correct long-term fix. Until it lands, image builds that
//   need staging rights will fail unless the operator performs a one-time
//   manual role assignment on the auto-created staging RG.
resource aibIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = if (enableAib) {
  name: 'id-${name}-aib'
  location: location
  tags: tags
}

resource galleryRef 'Microsoft.Compute/galleries@2024-03-03' existing = if (enableAib) {
  name: last(split(galleryResourceId, '/'))
}

resource aibGalleryContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableAib) {
  name: guid(galleryResourceId, 'aib', contributorRoleId)
  scope: galleryRef
  properties: {
    principalId: aibIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', contributorRoleId)
    description: 'Contributor on the Compute Gallery — AIB publishes image versions here. Built-in Contributor used because Azure has no narrower gallery-image-publish built-in role. Replaces the prior RG-wide assignment (issue #97).'
  }
}

// ─── Outputs ─────────────────────────────────────────────────────────────────
// Note: vmssLauncher* outputs were removed in the UAMI-consolidation refactor.
// Callers previously using `identity.outputs.vmssLauncher*` should use the
// shared `launcher*` outputs instead — the VMSS launcher ACA Jobs now share
// the same UAMI as the Windows ACI launcher.
output aibId string = enableAib ? aibIdentity.id : ''
output aibPrincipalId string = enableAib ? aibIdentity.properties.principalId : ''
