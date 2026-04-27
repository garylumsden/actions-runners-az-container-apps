@description('Azure region for the workspace.')
param location string

@description('Resource name.')
param name string

@description('Resource tags.')
param tags object = {}

resource workspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

output id string = workspace.id
output name string = workspace.name
output customerId string = workspace.properties.customerId
