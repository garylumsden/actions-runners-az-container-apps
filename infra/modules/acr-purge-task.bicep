@description('Name of the parent ACR.')
param acrName string

@description('Azure region (must match the ACR).')
param location string

@description('Resource tags.')
param tags object = {}

@description('Purge tags older than this duration (Go duration syntax, e.g. 30d, 720h).')
param purgeAgo string = '30d'

@description('Always keep at least this many of the most recent tags per repository, even if older than purgeAgo. Protects rollback capability if builds pause.')
param keepMostRecent int = 3

@description('CRON schedule (UTC) for the purge run. Default: Mondays at 04:00 UTC (after the Sunday image build).')
param cronSchedule string = '0 4 * * 1'

@description('Repositories to purge. Tags matching the default YYYYMMDD / YYYYMMDD-HHmm / YYYYMMDD-<sha7> pattern are targeted; the "stable" tag is preserved.')
param repositories array = [
  'github-runner-linux'
  'github-runner-windows'
]

// Build a filter argument per repository. Regex matches the exact tag patterns
// produced by build-images.yml: YYYYMMDD, YYYYMMDD-HHmm, YYYYMMDD-<7-char sha>.
// The "stable" tag is NOT matched and will be preserved.
var tagRegex = '^[0-9]{8}(-[0-9]{4})?(-[a-f0-9]{7})?$'
var filterArgs = join(map(repositories, r => '--filter \'${r}:${tagRegex}\''), ' ')

// The acr purge command; --keep preserves the N most recent matching tags per
// repo (so rollback is possible even if builds pause); --untagged removes
// manifests orphaned when "stable" is reassigned to a newer image.
var purgeCmd = 'acr purge ${filterArgs} --ago ${purgeAgo} --keep ${keepMostRecent} --untagged'

// ACR Tasks expect an EncodedTask payload (base64-encoded YAML task file).
var encodedTaskYaml = base64('version: v1.1.0\nsteps:\n  - cmd: ${purgeCmd}\n    disableWorkingDirectoryOverride: true\n    timeout: 3600\n')

resource registry 'Microsoft.ContainerRegistry/registries@2025-11-01' existing = {
  name: acrName
}

resource purgeTask 'Microsoft.ContainerRegistry/registries/tasks@2019-04-01' = {
  parent: registry
  name: 'purge-old-runner-images'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    timeout: 3600
    platform: {
      os: 'Linux'
      architecture: 'amd64'
    }
    agentConfiguration: {
      cpu: 2
    }
    step: {
      type: 'EncodedTask'
      encodedTaskContent: encodedTaskYaml
    }
    trigger: {
      timerTriggers: [
        {
          name: 'weekly'
          schedule: cronSchedule
          status: 'Enabled'
        }
      ]
    }
  }
}

output taskName string = purgeTask.name
