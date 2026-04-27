@description('Azure region.')
param location string

@description('Resource name for the ACA Job.')
param name string

@description('Container Apps environment resource ID.')
param environmentId string

@description('ACR login server (e.g. crxxx.azurecr.io).')
param acrLoginServer string

@description('Docker image name and tag stored in ACR.')
param imageName string = 'github-runner-linux:stable'

@description('User-assigned managed identity resource ID.')
param managedIdentityId string

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

@description('Base64-encoded PEM of the GitHub App private key. Decoded inline at deploy time for the KEDA github-runner scaler (which requires raw PEM for its appKey trigger parameter). The KV-backed secret is still used by the container entrypoint.')
@secure()
param githubAppPemB64 string

@description('Runner labels applied at registration, comma-separated.')
param runnerLabels string = 'self-hosted,linux,aca'

@description('vCPU per execution (decimal string, e.g. "2.0").')
param cpu string = '2.0'

@description('Memory per execution (e.g. "4Gi").')
param memory string = '4Gi'

@description('Maximum concurrent executions per KEDA polling interval (0 = scale to zero). This is the concurrency cap per poll — not a lifetime/total execution limit. See https://learn.microsoft.com/en-us/azure/container-apps/jobs?pivots=azure-cli#event-driven-jobs')
param maxExecutions int = 10

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

// KEDA github-runner scaler expects `owner` + (for repo scope) `repos` set to the
// bare repository name (not owner/repo). runnerScope must be exactly "org" or "repo".
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

resource linuxRunnerJob 'Microsoft.App/jobs@2025-07-01' = {
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
      replicaTimeout: 1800
      replicaRetryLimit: 0
      secrets: [
        {
          name: 'github-app-pem'
          keyVaultUrl: keyVaultSecretUri
          identity: managedIdentityId
        }
        // KEDA github-runner scaler requires a raw PEM-encoded RSA private key
        // for the `appKey` trigger parameter; KV stores it base64-encoded so the
        // container entrypoint can write it to a temp file. Decode here at
        // deploy time and expose as a separate inline secret consumed only by
        // the KEDA scaler. See commit e4d8134.
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
          pollingInterval: 30
          rules: [
            {
              name: 'github-runner-scaler'
              type: 'github-runner'
              // GitHub App auth: no PAT needed, no token expiry.
              // Scaler watches the org or repo queue and filters by runner labels.
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
          name: 'linux-runner'
          image: '${acrLoginServer}/${imageName}'
          resources: {
            cpu: json(cpu)
            memory: memory
          }
          env: [
            { name: 'GITHUB_APP_ID', value: githubAppId }
            { name: 'GITHUB_INSTALLATION_ID', value: githubInstallationId }
            { name: 'GITHUB_APP_PEM_B64', secretRef: 'github-app-pem' }
            { name: 'RUNNER_REGISTRATION_URL', value: runnerRegistrationUrl }
            { name: 'ACCESS_TOKEN_API_URL', value: 'https://api.github.com/app/installations/${githubInstallationId}/access_tokens' }
            { name: 'REGISTRATION_TOKEN_API_URL', value: registrationTokenApiUrl }
            { name: 'RUNNER_LABELS', value: runnerLabels }
          ]
        }
      ]
    }
  }
}

output name string = linuxRunnerJob.name
