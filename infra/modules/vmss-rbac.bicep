// VMSS-scoped role assignments. Split out of identity.bicep to break the
// chicken-and-egg between identity outputs (needed by VMSS modules for
// runnerIdentityId) and the VMSS resource IDs themselves (needed by
// VMSS-scoped role assignments). Call this once per VMSS, after both identity
// and the VMSS modules have declared their resources.

@description('Name of the existing VMSS to scope role assignments to.')
param vmssName string

@description('Principal ID of the shared launcher user-assigned managed identity. Granted Virtual Machine Contributor so the launcher can add/remove instances on this VMSS. (Named `launcherPrincipalId` rather than `vmssLauncherPrincipalId` since the UAMI was consolidated with the Windows ACI launcher UAMI.)')
param launcherPrincipalId string

@description('Principal ID of the runner user-assigned managed identity. Granted Virtual Machine Contributor only when enableRunnerSelfDelete is true, so a warm VM can delete itself once idle retention elapses.')
param runnerPrincipalId string

@description('Feature flag mirroring identity.bicep — grants the runner UAMI VM Contributor on this VMSS so in-VM watchdog can self-delete. Defaults to false (legacy 1:1 ephemeral behaviour).')
param enableRunnerSelfDelete bool = false

// Virtual Machine Contributor — sufficient to add/remove VMSS instances and to
// delete individual VMs within the scale set. Does not grant guest OS access.
// Retained for the launcher identity, which legitimately needs to manage the
// entire VMSS (create, delete, reimage any instance) to scale the tier.
var vmContributorRoleId = '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'

resource vmss 'Microsoft.Compute/virtualMachineScaleSets@2024-11-01' existing = {
  name: vmssName
}

resource launcherVmContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vmss.id, launcherPrincipalId, vmContributorRoleId)
  scope: vmss
  properties: {
    principalId: launcherPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', vmContributorRoleId)
    description: 'Virtual Machine Contributor for the shared launcher UAMI — scoped to this VMSS so the launcher can add/remove instances (issue: VMSS runner tiers).'
  }
}

// ─── Runner self-management custom role (issue #97) ──────────────────────────
// Previously the runner UAMI was granted the built-in Virtual Machine
// Contributor role scoped to this VMSS so the in-VM watchdog could self-delete
// after idle retention elapsed. That role is far broader than needed: it
// includes write/action permissions on every instance in the set (start, stop,
// reimage, deallocate, run-command, etc.). A compromised runner VM could abuse
// any of those verbs against siblings.
//
// This custom role narrows the runner's authority to exactly the three
// operations the watchdog actually calls:
//   - .../virtualMachineScaleSets/virtualMachines/delete  (delete self)
//   - .../virtualMachineScaleSets/virtualMachines/read    (look up self by name)
//   - .../virtualMachineScaleSets/read                    (needed on parent by IMDS/API lookups)
//
// WARNING — residual risk: Azure RBAC cannot scope a role assignment to a
// single VMSS *instance*. Every VMSS-instance role assignment applies to the
// entire set. A compromised runner therefore still has delete authority over
// its siblings' VMs within the same VMSS. We accept this inherent limitation
// because (a) runners are ephemeral and isolated per-tier, (b) the blast
// radius is capped at one VMSS tier, and (c) deleting a sibling instance is
// self-healing — the launcher simply provisions a replacement. We do NOT grant
// any write/action verbs (reimage, run-command, start, stop) that would allow
// a compromised runner to *persist* code on siblings or exfiltrate data from
// them. Tracking: issue #97.
var runnerSelfManagementRoleName = guid(vmss.id, 'runner-self-management-v1')

resource runnerSelfManagementRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = if (enableRunnerSelfDelete) {
  name: runnerSelfManagementRoleName
  properties: {
    roleName: 'Runner VMSS Instance Self-Management (${vmssName})'
    description: 'Custom role for GitHub runner UAMIs on a VMSS tier: read parent VMSS, read/delete own instance only. Replaces built-in Virtual Machine Contributor to eliminate reimage/run-command/power-control verbs against sibling instances. Issue #97.'
    type: 'CustomRole'
    assignableScopes: [
      vmss.id
    ]
    permissions: [
      {
        actions: [
          'Microsoft.Compute/virtualMachineScaleSets/read'
          'Microsoft.Compute/virtualMachineScaleSets/virtualMachines/read'
          'Microsoft.Compute/virtualMachineScaleSets/virtualMachines/delete'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
  }
}

resource runnerSelfDelete 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableRunnerSelfDelete) {
  name: guid(vmss.id, runnerPrincipalId, 'runner-self-management-v1')
  scope: vmss
  properties: {
    principalId: runnerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: runnerSelfManagementRole.id
    description: 'Custom "Runner VMSS Instance Self-Management" role for runner UAMI — scoped to this VMSS so a warm VM can read/delete itself via watchdog after idle retention. Replaces VM Contributor to drop reimage/run-command/power verbs (issue #97). Residual risk: role still applies to sibling instances (Azure RBAC cannot scope per-VM-instance); acceptable because delete is self-healing via launcher.'
  }
}
