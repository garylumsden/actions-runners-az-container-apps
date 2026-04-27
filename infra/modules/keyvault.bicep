@description('Key Vault name. Must be 3-24 chars, lowercase alphanumeric + hyphens, globally unique.')
@minLength(3)
@maxLength(24)
param name string

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object = {}

@secure()
@description('Base64-encoded PEM private key for the GitHub App. Stored as-is in Key Vault; container entrypoints decode at runtime.')
param githubAppPemB64 string

@description('Principal ID of the runner managed identity. Granted Key Vault Secrets User on this vault.')
param runnerPrincipalId string

@description('Principal ID of the Windows launcher managed identity. Granted Key Vault Secrets User on this vault.')
param launcherPrincipalId string

@description('Key Vault public network access. Set to "Disabled" to require private endpoint access only. Default is "Enabled" (combined with defaultAction=Deny and bypass=AzureServices this still restricts public traffic unless explicit ipRules/vnetRules are supplied).')
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Enabled'

@description('Optional public IP allow-list for the Key Vault firewall. Each entry is an IP or CIDR (e.g. {value: "203.0.113.5"} or {value: "203.0.113.0/24"}). Empty by default — only trusted Azure services (bypass=AzureServices) can reach the vault over the public endpoint.')
param ipRules array = []

@description('Optional VNet subnet allow-list for the Key Vault firewall. Each entry takes the form {id: "<subnetResourceId>"}. Empty by default.')
param virtualNetworkRules array = []

// Key Vault Secrets User — minimal RBAC role required to read secret values at runtime.
// ACA's Key Vault-backed secret reference pattern uses the job's managed identity to fetch
// the secret on replica start; it does not need List or any management permissions.
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

// Key Vault Secrets Officer — full management of secrets (read + write + delete + list).
// The launcher UAMI needs this because the VMSS launcher writes per-instance
// runner-token secrets (`az keyvault secret set`) and deletes them after use
// (issue #92 / B1). Scoped to this vault only — launcher cannot touch other vaults.
var keyVaultSecretsOfficerRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    // RBAC-only: the legacy vault access policy model is disabled. All access goes
    // through Azure RBAC role assignments scoped to this vault.
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    // Purge protection is permanent once enabled. Accepting this tradeoff because
    // it is a hard requirement for production-grade secret storage and prevents
    // accidental (or malicious) purges during the soft-delete window.
    enablePurgeProtection: true
    publicNetworkAccess: publicNetworkAccess
    networkAcls: {
      bypass: 'AzureServices'
      // RBAC (enableRbacAuthorization: true) is the authoritative access gate:
      // only the runner and launcher UAMIs hold Key Vault Secrets User on this vault.
      // Network-level Deny was blocking ACA's keyVaultUrl fetch on new Job creation
      // even with bypass=AzureServices. Switched to Allow to unblock ACA secret binding;
      // re-harden via private endpoint + CAE VNet integration in a follow-up if needed.
      defaultAction: 'Allow'
      ipRules: ipRules
      virtualNetworkRules: virtualNetworkRules
    }
  }
}

resource pemSecret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: keyVault
  name: 'gh-app-pem-b64'
  properties: {
    value: githubAppPemB64
    contentType: 'text/plain; base64-encoded PEM'
  }
}

resource runnerKvSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, runnerPrincipalId, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    principalId: runnerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    description: 'Key Vault Secrets User for Linux runner managed identity — needed for ACA KV-backed secret resolution at replica start.'
  }
}

resource launcherKvSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, launcherPrincipalId, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    principalId: launcherPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    description: 'Key Vault Secrets User for Windows launcher managed identity — needed for ACA KV-backed secret resolution at replica start.'
  }
}

// VMSS launcher writes per-instance runner-token secrets (issue #92 / B1 — keep
// registration tokens out of VMSS instance tags / IMDS). Secrets Officer is the
// minimum role that grants both setSecret and deleteSecret actions. Scoped to
// this vault only. The shared launcher UAMI is reused by the Windows ACI
// launcher too, so it also gains write on this vault — acceptable because the
// vault only holds PEM + short-lived runner-tokens, and write access is
// required for the VMSS-launcher path.
resource launcherKvSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, launcherPrincipalId, keyVaultSecretsOfficerRoleId)
  scope: keyVault
  properties: {
    principalId: launcherPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsOfficerRoleId)
    description: 'Key Vault Secrets Officer for shared launcher UAMI — VMSS launcher needs setSecret/deleteSecret for per-instance runner-token secrets (issue #92).'
  }
}

// Note: the VMSS launcher ACA Jobs reuse the shared `launcherPrincipalId` UAMI
// (see identity.bicep consolidation). A dedicated VMSS-launcher KV role
// assignment existed here previously but was removed when the UAMI was folded
// into the shared launcher identity — the existing `launcherKvSecretsUser` RA
// above already grants the necessary access.

output keyVaultId string = keyVault.id
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri

// Versionless secret URI. ACA Jobs resolve the latest enabled version at replica start,
// so rotating the secret in Key Vault is picked up without redeploying the template.
output pemSecretUri string = '${keyVault.properties.vaultUri}secrets/${pemSecret.name}'
