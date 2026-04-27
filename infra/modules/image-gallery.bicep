@description('Azure region.')
param location string

@description('Compute Gallery name. Must be 1-80 chars, alphanumeric + periods/underscores only — no hyphens. Callers must strip hyphens before passing.')
@minLength(1)
@maxLength(80)
param name string

@description('Resource tags.')
param tags object = {}

@description('Base name used to derive image-definition offer/sku identifiers (e.g. "myprefix-gh-runners-REGIONABBR"). Appears in the image identifier, not a customer-facing name.')
param baseName string

// ─── Compute Gallery ──────────────────────────────────────────────────────────
// Holds one shared-image definition per runner OS. Image versions are produced
// out-of-band by Azure Image Builder (Stream B) and referenced by VMSS via the
// definition's ID with the "latest" alias, or by specific version ID.
resource gallery 'Microsoft.Compute/galleries@2024-03-03' = {
  name: name
  location: location
  tags: tags
  properties: {
    description: 'Shared image gallery for self-hosted GitHub Actions VMSS runner tiers.'
  }
}

// ─── Linux image definition: Ubuntu 22.04 LTS, gen2, TrustedLaunch ────────────
resource linuxImageDefinition 'Microsoft.Compute/galleries/images@2024-03-03' = {
  parent: gallery
  name: 'gh-runner-ubuntu-2204'
  location: location
  tags: tags
  properties: {
    osType: 'Linux'
    osState: 'Generalized'
    hyperVGeneration: 'V2'
    identifier: {
      publisher: 'actions-runners-az-container-apps'
      offer: 'ubuntu-2204-${baseName}'
      sku: 'gh-runner-ubuntu-2204'
    }
    features: [
      {
        name: 'SecurityType'
        value: 'TrustedLaunch'
      }
    ]
    recommended: {
      vCPUs: {
        min: 2
        max: 16
      }
      memory: {
        min: 4
        max: 64
      }
    }
  }
}

// ─── Windows image definition: Windows Server 2022 Datacenter, gen2, TrustedLaunch ──
resource windowsImageDefinition 'Microsoft.Compute/galleries/images@2024-03-03' = {
  parent: gallery
  name: 'gh-runner-ws2022'
  location: location
  tags: tags
  properties: {
    osType: 'Windows'
    osState: 'Generalized'
    hyperVGeneration: 'V2'
    identifier: {
      publisher: 'actions-runners-az-container-apps'
      offer: 'ws2022-${baseName}'
      sku: 'gh-runner-ws2022'
    }
    features: [
      {
        name: 'SecurityType'
        value: 'TrustedLaunch'
      }
    ]
    recommended: {
      vCPUs: {
        min: 2
        max: 16
      }
      memory: {
        min: 4
        max: 64
      }
    }
  }
}

output galleryId string = gallery.id
output galleryName string = gallery.name
output linuxImageDefinitionId string = linuxImageDefinition.id
output linuxImageDefinitionName string = linuxImageDefinition.name
output windowsImageDefinitionId string = windowsImageDefinition.id
output windowsImageDefinitionName string = windowsImageDefinition.name
