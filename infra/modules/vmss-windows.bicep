@description('Azure region.')
param location string

@description('VMSS resource name.')
param name string

@description('Resource tags.')
param tags object = {}

@description('VM size. Default Standard_D4ds_v5 — 4 vCPU / 16 GB, supports ephemeral OS on ResourceDisk (~150 GB NVMe, fits the ~127 GB Windows image) and nested virtualisation for WSL2/Hyper-V.')
param vmSize string = 'Standard_D4ds_v5'

@description('Compute Gallery image reference ID. Can be a specific image version ID (.../versions/{ver}) or an image-definition ID with the "latest" alias used by VMSS to pin the newest version.')
param imageReferenceId string

@description('Compute Gallery image version to pin to. Default "latest" resolves the newest bake via the image-definition ID. Set to a specific version (e.g. "20250419.0830") to roll back from a broken weekly bake.')
param imageVersion string = 'latest'

@description('User-assigned managed identity resource ID for the runner VM (used for ACR pull, Key Vault reads, and self-delete on watchdog expiry).')
param runnerIdentityId string

@description('Optional subnet resource ID to attach each VM NIC to. Empty string means no subnet attached.')
param subnetId string = ''

@description('Maximum number of instances the scale set may hold. Scaling is driven externally (launcher job); this is only the upper bound.')
@minValue(0)
@maxValue(1000)
param maxInstances int = 10

@description('Admin username for the runner VMs. Ignored beyond initial provisioning; we do not use password login and do not persist credentials.')
param adminUsername string = 'runneradmin'

@description('Admin password. Defaults to newGuid() which means a fresh, never-recorded password is generated at each deploy. Rotation policy: reimage the scale set to invalidate. Never log, never output — the intent is that no human or workflow ever uses this password.')
@secure()
param adminPassword string = newGuid()

@description('Optional HTTPS URI to a CustomScriptExtension payload (PowerShell bootstrap). When empty, no extension is attached — bootstrap is expected to be baked into the AIB image. When non-empty, the extension runs once at first boot.')
param customScriptUri string = ''

@description('Optional PowerShell command line to execute with the fetched script. Example: "powershell -ExecutionPolicy Unrestricted -File bootstrap.ps1". Required if customScriptUri is provided. Marked @secure() because callers may embed a registration token or other sensitive argument in the command line; the existing TODO below notes that sensitive values should be passed via protectedSettings, but the @secure() decorator prevents accidental capture in deployment outputs/logs until that refactor lands (#98 H3).')
@secure()
param customScriptCommand string = ''

@description('VM priority. "Spot" yields ~60-90% cost savings vs "Regular" but VMs may be evicted when Azure needs the capacity back. Ephemeral CI runners are well-suited to Spot because each VM is single-use and KEDA simply re-launches a fresh instance after eviction. Default "Spot".')
@allowed([
  'Regular'
  'Spot'
])
param priority string = 'Spot'

@description('Eviction policy when priority=Spot. Must be "Delete" because ephemeral OS disks are incompatible with "Deallocate" (the local disk is destroyed on stop). Ignored when priority=Regular.')
@allowed([
  'Delete'
  'Deallocate'
])
param evictionPolicy string = 'Delete'

@description('Maximum hourly price (USD) you are willing to pay per VM when priority=Spot. -1 (default) means "pay up to the current on-demand price" — VM is only evicted on capacity pressure, never on price. Ignored when priority=Regular.')
param spotMaxPrice int = -1

// TODO: wire bootstrap via Stream E output — the Windows bootstrap stream will
// provide customScriptUri/customScriptCommand (likely pointing at an ACR-hosted
// or storage-hosted bootstrap.ps1) once available. Sensitive values (reg
// token, PEM) should be passed through protectedSettings, not this module's
// public parameters.

var hasSubnet = !empty(subnetId)
var hasCustomScript = !empty(customScriptUri) && !empty(customScriptCommand)

// When imageVersion is 'latest', use the image-definition ID directly — VMSS
// resolves this as the newest version at instance creation. Otherwise append
// /versions/{imageVersion} to pin to a specific bake for rollback.
var effectiveImageReferenceId = toLower(imageVersion) == 'latest' ? imageReferenceId : '${imageReferenceId}/versions/${imageVersion}'

resource vmss 'Microsoft.Compute/virtualMachineScaleSets@2024-11-01' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${runnerIdentityId}': {}
    }
  }
  sku: {
    name: vmSize
    capacity: 0
  }
  properties: {
    orchestrationMode: 'Flexible'
    platformFaultDomainCount: 1
    singlePlacementGroup: false
    // Flexible orchestration only accepts Manual. We reimage via ephemeral OS
    // (delete instance → launcher creates a fresh one) rather than upgrade.
    upgradePolicy: {
      mode: 'Manual'
    }
    virtualMachineProfile: {
      osProfile: {
        // computerNamePrefix ≤ 9 chars for Windows (leaves room for a 6-char
        // instance suffix without exceeding the 15-char NetBIOS limit).
        computerNamePrefix: 'ghwin'
        adminUsername: adminUsername
        adminPassword: adminPassword
        windowsConfiguration: {
          provisionVMAgent: true
          enableAutomaticUpdates: false
        }
      }
      storageProfile: {
        imageReference: {
          id: effectiveImageReferenceId
        }
        osDisk: {
          createOption: 'FromImage'
          caching: 'ReadOnly'
          // Ephemeral OS on ResourceDisk: Windows images are ~127 GB and do
          // not fit on the ~75 GB cache disk of Standard_D*ds_v5, so the
          // placement must be ResourceDisk (~150 GB NVMe).
          diffDiskSettings: {
            option: 'Local'
            placement: 'ResourceDisk'
          }
        }
      }
      securityProfile: {
        securityType: 'TrustedLaunch'
        uefiSettings: {
          secureBootEnabled: true
          vTpmEnabled: true
        }
      }
      networkProfile: hasSubnet ? {
        networkApiVersion: '2022-11-01'
        networkInterfaceConfigurations: [
          {
            name: '${name}-nic'
            properties: {
              primary: true
              ipConfigurations: [
                {
                  name: 'ipconfig1'
                  properties: {
                    subnet: {
                      id: subnetId
                    }
                    primary: true
                    // Egress via shared NAT Gateway on the VMSS subnet
                    // (infra/modules/network.bicep). No per-instance PIP.
                  }
                }
              ]
            }
          }
        ]
      } : null
      extensionProfile: hasCustomScript ? {
        extensions: [
          {
            name: 'windowsBootstrap'
            properties: {
              publisher: 'Microsoft.Compute'
              type: 'CustomScriptExtension'
              typeHandlerVersion: '1.10'
              autoUpgradeMinorVersion: true
              settings: {
                fileUris: [
                  customScriptUri
                ]
              }
              protectedSettings: {
                commandToExecute: customScriptCommand
              }
            }
          }
        ]
      } : null
      priority: priority
      evictionPolicy: priority == 'Spot' ? evictionPolicy : null
      billingProfile: priority == 'Spot' ? {
        maxPrice: json(string(spotMaxPrice))
      } : null
    }
  }
}

output vmssId string = vmss.id
output vmssName string = vmss.name
#disable-next-line outputs-should-not-contain-secrets
output maxInstances int = maxInstances
