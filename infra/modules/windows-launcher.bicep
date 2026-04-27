@description('Azure region.')
param location string

@description('Resource name for the ACA Job.')
param name string

@description('Container Apps environment resource ID.')
param environmentId string

@description('ACR login server (e.g. crxxx.azurecr.io).')
param acrLoginServer string

@description('Launcher image name and tag stored in ACR.')
param launcherImageName string = 'windows-runner-launcher:stable'

@description('Windows runner image name and tag stored in ACR (pulled inside ACI).')
param windowsRunnerImageName string = 'github-runner-windows:stable'

@description('User-assigned managed identity resource ID.')
param managedIdentityId string

@description('User-assigned managed identity client ID (for az login --identity).')
param managedIdentityClientId string

@description('Azure subscription ID (passed to launcher so it can create ACI).')
param subscriptionId string

@description('Resource group name (passed to launcher so it can create ACI in the same RG).')
param resourceGroupName string

@description('Runner scope ("org" or "repo"). Controls which GitHub registration-token endpoint is used and which KEDA scaler metadata is emitted.')
@allowed([
  'org'
  'repo'
])
param runnerScope string = 'org'

@description('GitHub owner login (organisation or user).')
param githubOwner string

@description('GitHub repository name. Required when runnerScope = "repo".')
param githubRepo string = ''

@description('GitHub App ID (numeric string).')
param githubAppId string

@description('GitHub App installation ID (numeric string).')
param githubInstallationId string

@description('Versionless Key Vault secret URI for the base64-encoded GitHub App PEM. The ACA Job resolves this at replica start using its managed identity (requires Key Vault Secrets User on the vault).')
param keyVaultSecretUri string

@description('Base64-encoded PEM of the GitHub App private key. Decoded inline at deploy time for the KEDA github-runner scaler (which requires raw PEM for its appKey trigger parameter). The KV-backed secret is still used by the launcher entrypoint.')
@secure()
param githubAppPemB64 string

@description('Runner labels applied to the Windows ACI runner, comma-separated.')
param runnerLabels string = 'self-hosted,windows,aci'

@description('vCPU for each Windows ACI runner (passed to az container create).')
param windowsCpu string = '4'

@description('Memory in GB for each Windows ACI runner (passed to az container create).')
param windowsMemoryGb string = '8'

@description('Maximum concurrent launcher executions per KEDA polling interval (= max parallel Windows runners active at once). This is the concurrency cap per poll — not a lifetime/total execution limit. See https://learn.microsoft.com/en-us/azure/container-apps/jobs?pivots=azure-cli#event-driven-jobs')
param maxExecutions int = 10

@description('Azure region where Windows ACI containers are created. Must support Windows ACI.')
param windowsAciLocation string = 'westeurope'

@description('Log Analytics workspace customer ID / GUID (used for ACI log analytics attachment).')
param logAnalyticsCustomerId string

@description('Log Analytics workspace name. The launcher uses its managed identity at runtime to list the primary shared key (via Log Analytics Contributor scoped to this workspace) and pipe it to `az container create --log-analytics-workspace-key @file`, so the key is never baked into a Bicep secret or the ACA job spec.')
param logAnalyticsWorkspaceName string

@description('Principal ID of the Windows launcher managed identity. Granted Log Analytics Contributor on the workspace so it can call listKeys() at runtime.')
param launcherPrincipalId string

@description('Resource tags.')
param tags object = {}

// ─── Derived URLs (scope-aware) ──────────────────────────────────────────────
var isOrgScope = runnerScope == 'org'
var runnerRegistrationUrl = isOrgScope
  ? 'https://github.com/${githubOwner}'
  : 'https://github.com/${githubOwner}/${githubRepo}'
var registrationTokenApiUrl = isOrgScope
  ? 'https://api.github.com/orgs/${githubOwner}/actions/runners/registration-token'
  : 'https://api.github.com/repos/${githubOwner}/${githubRepo}/actions/runners/registration-token'

var kedaBaseMetadata = {
  githubAPIURL: 'https://api.github.com'
  owner: githubOwner
  runnerScope: runnerScope
  targetWorkflowQueueLength: '1'
  labels: runnerLabels
  applicationID: githubAppId
  installationID: githubInstallationId
}
var kedaMetadata = isOrgScope ? kedaBaseMetadata : union(kedaBaseMetadata, {
  repos: githubRepo
})

resource windowsLauncherJob 'Microsoft.App/jobs@2025-07-01' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentityId}': {}
    }
  }
  properties: {
    environmentId: environmentId
    configuration: {
      triggerType: 'Event'
      // Generous timeout: the launcher lives for the full duration of the Windows job.
      replicaTimeout: 14400
      replicaRetryLimit: 0
      secrets: [
        {
          name: 'github-app-pem'
          keyVaultUrl: keyVaultSecretUri
          identity: managedIdentityId
        }
        // KEDA github-runner scaler requires a raw PEM-encoded RSA private key
        // for the `appKey` trigger parameter; KV stores it base64-encoded so the
        // launcher entrypoint can hand it verbatim to `az container create` as a
        // secure environment variable. Decode here at deploy time and expose as
        // a separate inline secret consumed only by the KEDA scaler. See commit
        // e4d8134.
        {
          name: 'github-app-pem-decoded'
          #disable-next-line use-secure-value-for-secure-inputs
          value: base64ToString(githubAppPemB64)
        }
      ]
      registries: [
        {
          server: acrLoginServer
          identity: managedIdentityId
        }
      ]
      eventTriggerConfig: {
        replicaCompletionCount: 1
        parallelism: 1
        scale: {
          minExecutions: 0
          maxExecutions: maxExecutions
          // Slightly longer polling to give ACI runners time to register before
          // the next evaluation cycle counts the same job again.
          pollingInterval: 60
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
          name: 'windows-launcher'
          image: '${acrLoginServer}/${launcherImageName}'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            { name: 'AZURE_CLIENT_ID', value: managedIdentityClientId }
            { name: 'SUBSCRIPTION_ID', value: subscriptionId }
            { name: 'RESOURCE_GROUP', value: resourceGroupName }
            { name: 'ACR_SERVER', value: acrLoginServer }
            { name: 'MANAGED_IDENTITY_ID', value: managedIdentityId }
            { name: 'WINDOWS_RUNNER_IMAGE', value: windowsRunnerImageName }
            { name: 'WINDOWS_CPU', value: windowsCpu }
            { name: 'WINDOWS_MEMORY_GB', value: windowsMemoryGb }
            { name: 'GITHUB_APP_ID', value: githubAppId }
            { name: 'GITHUB_INSTALLATION_ID', value: githubInstallationId }
            { name: 'GITHUB_APP_PEM_B64', secretRef: 'github-app-pem' }
            { name: 'RUNNER_REGISTRATION_URL', value: runnerRegistrationUrl }
            { name: 'ACCESS_TOKEN_API_URL', value: 'https://api.github.com/app/installations/${githubInstallationId}/access_tokens' }
            { name: 'REGISTRATION_TOKEN_API_URL', value: registrationTokenApiUrl }
            { name: 'RUNNER_LABELS', value: runnerLabels }
            { name: 'ACI_LOCATION', value: windowsAciLocation }
            { name: 'LOG_ANALYTICS_WORKSPACE_ID', value: logAnalyticsCustomerId }
            { name: 'LOG_ANALYTICS_WORKSPACE_NAME', value: logAnalyticsWorkspaceName }
          ]
        }
      ]
    }
  }
}

output name string = windowsLauncherJob.name

// Log Analytics Contributor for the launcher UAMI is now declared in
// `identity.bicep` (shared launcher UAMI consolidation). Keeping this module
// free of RA declarations avoids duplicate deterministic-GUID conflicts
// (RoleAssignmentExists) when both modules target the same principal/scope.
