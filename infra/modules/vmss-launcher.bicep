@description('Azure region.')
param location string

@description('Resource name for the ACA Job.')
param name string

@description('Resource tags.')
param tags object = {}

@description('OS flavour of the target VMSS — used only to shape KEDA labels and log markers. The launcher image is OS-agnostic.')
@allowed([
  'linux'
  'windows'
])
param runnerOs string

@description('Name of the VMSS this launcher scales. Passed to the container as VMSS_NAME.')
param vmssName string

@description('Container Apps environment resource ID.')
param containerAppEnvironmentId string

@description('ACR login server (e.g. crxxx.azurecr.io).')
param acrLoginServer string

@description('Image tag for the vmss-launcher image in ACR. Defaults to "stable".')
param imageTag string = 'stable'

@description('Resource ID of the launcher user-assigned managed identity. Must have Virtual Machine Contributor on the target VMSS, Managed Identity Operator on itself and on the runner UAMI, Log Analytics Contributor on the workspace, and AcrPull on the ACR.')
param launcherIdentityId string

@description('Client ID of the launcher user-assigned managed identity (used by `az login --identity`).')
param launcherIdentityClientId string

@description('Resource ID of the runner user-assigned managed identity. Assigned to each VMSS instance the launcher creates.')
param runnerIdentityResourceId string

@description('Client ID of the runner user-assigned managed identity. Stamped as the `ghRunnerIdentityClientId` tag on each new VMSS instance so the VM bootstrap can `az login --identity --username <clientId>` without a second ARM round trip to resolve it.')
param runnerIdentityClientId string

@description('Key Vault base URL (https://<vault>.vault.azure.net). Required by the ACA Job secret reference (keyVaultUrl must be the versionless secret URI, not the vault URL; kept for parity with other launcher modules).')
param keyVaultUrl string

@description('Key Vault name (short name, not URL). Surfaced to the launcher entrypoint as KV_NAME so it can `az keyvault secret set/delete` the per-instance runner-token secret (issue #92).')
param keyVaultName string

@description('Versionless Key Vault secret URI for the base64-encoded GitHub App PEM. The ACA Job resolves this at replica start via the launcher identity (requires Key Vault Secrets User on the vault).')
param pemSecretUri string

@description('Resource ID of the Log Analytics workspace. Used to resolve listKeys() at deploy time so the launcher entrypoint can enrol new VMSS instances in the same workspace.')
param logAnalyticsWorkspaceResourceId string

@description('Base64-encoded PEM of the GitHub App private key. Decoded inline at deploy time for the KEDA github-runner scaler (which requires raw PEM for its appKey trigger parameter). The KV-backed secret is still used by the launcher entrypoint.')
@secure()
param githubAppPemB64 string

@description('Runner scope ("org" or "repo"). Controls which GitHub registration-token endpoint is used and which KEDA scaler metadata is emitted.')
@allowed([
  'org'
  'repo'
])
param runnerScope string = 'org'

@description('GitHub owner login (organisation or user).')
param githubOrg string

@description('GitHub repository name. Required when runnerScope = "repo".')
param githubRepo string = ''

@description('GitHub App ID (numeric string).')
param githubAppId string

@description('GitHub App installation ID (numeric string).')
param githubInstallationId string

@description('Maximum concurrent launcher executions per KEDA polling interval.')
param maxExecutions int = 10

@description('Idle retention window, in minutes, stamped as the ghRunnerIdleRetentionMinutes tag onto each new VMSS instance. 0 means ephemeral (single-job, deregister on job completion). The VM watchdog reads this tag via IMDS to decide when to self-delete.')
@minValue(0)
param idleRetentionMinutes int = 0

@description('Maximum VM lifetime, in hours, stamped as the ghRunnerMaxLifetimeHours tag onto each new VMSS instance. 0 means no hard cap. The VM watchdog reads this tag via IMDS and forces a self-delete once the age exceeds this value.')
@minValue(0)
param maxLifetimeHours int = 0

@description('Optional sub-hour override (#100): maximum VM lifetime in minutes, stamped as the ghRunnerMaxLifetimeMinutes tag. When >0 it takes precedence over maxLifetimeHours in the watchdog, enabling CI scenarios that need to exercise the hard cap in under an hour. 0 (default) falls through to maxLifetimeHours.')
@minValue(0)
param maxLifetimeMinutes int = 0

@description('Optional suffix appended to the VMSS runner label list for tenancy / test isolation. When non-empty, labels become e.g. "self-hosted,linux,vmss,<suffix>" on both the KEDA scaler filter and the runner registration. Default empty = unchanged from pre-#99 behaviour.')
param runnerLabelSuffix string = ''

// ─── Derived values ──────────────────────────────────────────────────────────
var isLinux = runnerOs == 'linux'
var baseRunnerLabels = isLinux ? 'self-hosted,linux,vmss' : 'self-hosted,windows,vmss'
var runnerLabels = empty(runnerLabelSuffix) ? baseRunnerLabels : '${baseRunnerLabels},${runnerLabelSuffix}'

// Polling interval mirrors the existing launcher tuning: 30s for Linux (fast
// cold start), 60s for Windows (slower boot, avoids double-scaling while a
// new instance is registering).
var pollingInterval = isLinux ? 30 : 60

var isOrgScope = runnerScope == 'org'
var runnerRegistrationUrl = isOrgScope
  ? 'https://github.com/${githubOrg}'
  : 'https://github.com/${githubOrg}/${githubRepo}'
var registrationTokenApiUrl = isOrgScope
  ? 'https://api.github.com/orgs/${githubOrg}/actions/runners/registration-token'
  : 'https://api.github.com/repos/${githubOrg}/${githubRepo}/actions/runners/registration-token'

var kedaBaseMetadata = {
  githubAPIURL: 'https://api.github.com'
  owner: githubOrg
  runnerScope: runnerScope
  targetWorkflowQueueLength: '1'
  labels: runnerLabels
  applicationID: githubAppId
  installationID: githubInstallationId
}
var kedaMetadata = isOrgScope ? kedaBaseMetadata : union(kedaBaseMetadata, {
  repos: githubRepo
})

// ─── LAW resolution (deploy-time listKeys — same pattern as windows-launcher) ─
resource lawRef 'Microsoft.OperationalInsights/workspaces@2025-02-01' existing = {
  name: last(split(logAnalyticsWorkspaceResourceId, '/'))
}

resource vmssLauncherJob 'Microsoft.App/jobs@2025-07-01' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${launcherIdentityId}': {}
    }
  }
  properties: {
    environmentId: containerAppEnvironmentId
    configuration: {
      triggerType: 'Event'
      // 13 minutes: enough to provision one VM (cold start ~3-5 min for Windows)
      // but short enough that the launcher doesn't linger after the VM registers.
      //
      // Invariant (see #93): replicaTimeout MUST exceed the launcher's
      // PROVISION_TIMEOUT_SECONDS (currently ~720s, in
      // docker/vmss-launcher/entrypoint.sh) with ~60s of headroom. If
      // LAUNCHER_POLL_BUDGET >= replicaTimeout, ACA SIGTERMs the launcher
      // while a VM is still provisioning; the launcher exits, KEDA
      // considers the queue serviced, and the VM -- which eventually
      // registers with GitHub -- is orphaned with no work because the
      // scaler thinks capacity is already there.
      replicaTimeout: 780
      replicaRetryLimit: 0
      secrets: [
        {
          name: 'github-app-pem'
          keyVaultUrl: pemSecretUri
          identity: launcherIdentityId
        }
        // KEDA github-runner scaler requires a raw PEM-encoded RSA private key
        // for the `appKey` trigger parameter; KV stores it base64-encoded so the
        // launcher entrypoint can hand it to `az vmss` commands as a secure env
        // variable. Decode here at deploy time and expose as a separate inline
        // secret consumed only by the KEDA scaler — mirrors windows-launcher.
        {
          name: 'github-app-pem-decoded'
          #disable-next-line use-secure-value-for-secure-inputs
          value: base64ToString(githubAppPemB64)
        }
        {
          name: 'law-shared-key'
          #disable-next-line use-secure-value-for-secure-inputs
          value: lawRef.listKeys().primarySharedKey
        }
      ]
      registries: [
        {
          server: acrLoginServer
          identity: launcherIdentityId
        }
      ]
      eventTriggerConfig: {
        replicaCompletionCount: 1
        parallelism: 1
        scale: {
          minExecutions: 0
          maxExecutions: maxExecutions
          pollingInterval: pollingInterval
          rules: [
            {
              name: 'github-runner-scaler'
              type: 'github-runner'
              metadata: kedaMetadata
              auth: [
                {
                  triggerParameter: 'appKey'
                  secretRef: 'github-app-pem-decoded'
                }
              ]
            }
          ]
        }
      }
    }
    template: {
      containers: [
        {
          name: 'vmss-launcher'
          image: '${acrLoginServer}/vmss-launcher:${imageTag}'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            { name: 'AZURE_CLIENT_ID', value: launcherIdentityClientId }
            { name: 'AZURE_SUBSCRIPTION_ID', value: subscription().subscriptionId }
            { name: 'RESOURCE_GROUP', value: resourceGroup().name }
            { name: 'VMSS_NAME', value: vmssName }
            { name: 'RUNNER_OS', value: runnerOs }
            { name: 'RUNNER_LABELS', value: runnerLabels }
            { name: 'GITHUB_ORG', value: githubOrg }
            { name: 'GITHUB_REPO', value: githubRepo }
            { name: 'RUNNER_SCOPE', value: runnerScope }
            { name: 'GITHUB_APP_ID', value: githubAppId }
            { name: 'GITHUB_INSTALLATION_ID', value: githubInstallationId }
            { name: 'GITHUB_APP_PEM_B64', secretRef: 'github-app-pem' }
            { name: 'RUNNER_REGISTRATION_URL', value: runnerRegistrationUrl }
            { name: 'ACCESS_TOKEN_API_URL', value: 'https://api.github.com/app/installations/${githubInstallationId}/access_tokens' }
            { name: 'REGISTRATION_TOKEN_API_URL', value: registrationTokenApiUrl }
            { name: 'KEY_VAULT_URL', value: keyVaultUrl }
            { name: 'KV_NAME', value: keyVaultName }
            { name: 'LAW_WORKSPACE_ID', value: lawRef.properties.customerId }
            { name: 'LAW_SHARED_KEY', secretRef: 'law-shared-key' }
            { name: 'RUNNER_IDENTITY_RESOURCE_ID', value: runnerIdentityResourceId }
            { name: 'RUNNER_IDENTITY_CLIENT_ID', value: runnerIdentityClientId }
            { name: 'IDLE_RETENTION_MINUTES', value: string(idleRetentionMinutes) }
            { name: 'MAX_LIFETIME_HOURS', value: string(maxLifetimeHours) }
            { name: 'MAX_LIFETIME_MINUTES', value: string(maxLifetimeMinutes) }
          ]
        }
      ]
    }
  }
}

output jobId string = vmssLauncherJob.id
output jobName string = vmssLauncherJob.name
