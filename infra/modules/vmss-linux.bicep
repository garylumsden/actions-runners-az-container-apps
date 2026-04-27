@description('Azure region.')
param location string

@description('VMSS resource name.')
param name string

@description('Resource tags.')
param tags object = {}

@description('VM size. Default Standard_D4ds_v5 — 4 vCPU / 16 GB, supports ephemeral OS on CacheDisk and nested virtualisation.')
param vmSize string = 'Standard_D4ds_v5'

@description('Compute Gallery image reference ID. Can be a specific image version ID (.../versions/{ver}) or an image-definition ID with the "latest" alias used by VMSS to pin the newest version.')
param imageReferenceId string

@description('Compute Gallery image version to pin to. Default "latest" resolves the newest bake via the image-definition ID. Set to a specific version (e.g. "20250419.0830") to roll back from a broken weekly bake.')
param imageVersion string = 'latest'

@description('User-assigned managed identity resource ID for the runner VM (used for ACR pull, Key Vault reads, and self-delete on watchdog expiry).')
param runnerIdentityId string

@description('Optional subnet resource ID to attach each VM NIC to. Empty string means no subnet attached; the VMSS will still be created but cannot reach GitHub until a subnet is wired. MVP supports public-IP-less private deployment only — pass a subnet or accept zero-capacity no-op.')
param subnetId string = ''

@description('Maximum number of instances the scale set may hold. Scaling is driven externally (launcher job); this is only the upper bound.')
@minValue(0)
@maxValue(1000)
param maxInstances int = 10

@description('Admin username for the runner VMs. SSH key authentication is enforced (password auth disabled); keys are expected to be baked into the AIB image or provided via adminSshPublicKey.')
param adminUsername string = 'runneradmin'

@description('Optional SSH public key for the admin user. When empty, no SSH keys are injected via ARM and authentication is expected to be pre-baked into the AIB image (authorized_keys via cloud-init in the base image). Azure may reject deployment if neither is provided.')
param adminSshPublicKey string = ''

@description('Base64-encoded cloud-init / user-data payload injected as osProfile.customData. Caller is responsible for base64 encoding. Empty default means no customData is set and bootstrap is assumed to be baked into the AIB image.')
@secure()
param customDataBase64 string = ''

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

// TODO: wire bootstrap via Stream E output — replace default customDataBase64
// with the real runner bootstrap cloud-init (systemd unit, watchdog, hooks).

var hasSubnet = !empty(subnetId)
var hasSshKey = !empty(adminSshPublicKey)

// When imageVersion is 'latest', use the image-definition ID directly — VMSS
// resolves this as the newest version at instance creation. Otherwise append
// /versions/{imageVersion} to pin to a specific bake for rollback.
var effectiveImageReferenceId = toLower(imageVersion) == 'latest' ? imageReferenceId : '${imageReferenceId}/versions/${imageVersion}'

var sshConfig = {
  publicKeys: [
    {
      path: '/home/${adminUsername}/.ssh/authorized_keys'
      keyData: adminSshPublicKey
    }
  ]
}

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
    // Flexible orchestration rejects Automatic/Rolling upgrade modes — Manual is
    // the only permitted value. We reimage by deleting instances rather than
    // upgrading, so Manual is functionally correct as well.
    upgradePolicy: {
      mode: 'Manual'
    }
    virtualMachineProfile: {
      osProfile: {
        // adminUsername is required by ARM even when auth is SSH-key only.
        // The computer name prefix must be ≤ 9 chars for Linux.
        computerNamePrefix: 'ghlnx'
        adminUsername: adminUsername
        #disable-next-line adminusername-should-not-be-literal
        linuxConfiguration: {
          disablePasswordAuthentication: true
          ssh: hasSshKey ? sshConfig : null
          provisionVMAgent: true
        }
        customData: empty(customDataBase64) ? null : customDataBase64
      }
      storageProfile: {
        imageReference: {
          id: effectiveImageReferenceId
        }
        osDisk: {
          createOption: 'FromImage'
          caching: 'ReadOnly'
          // Ephemeral OS on ResourceDisk: the disk lives on the VM's local
          // NVMe (~150 GB on D4ds_v5), not a remote blob. CacheDisk placement
          // is NOT supported on D*ds_v5 — Azure rejects provisioning with
          // "The Diff Disk Placement of type 'CacheDisk' is not supported
          // for VM size Standard_D4ds_v5". ResourceDisk fits the Ubuntu
          // 22.04 AIB image (~50 GB) comfortably. If you override `vmSize`,
          // pick a `ds`/`ads` SKU with a resource disk larger than the
          // gallery image's osDiskSizeGB. See TROUBLESHOOTING.md
          // "OS disk size exceeds resource disk size".
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
                    // Egress is via the shared NAT Gateway on the VMSS subnet
                    // (see infra/modules/network.bicep). No per-instance
                    // public IP — NICs are private-only.
                  }
                }
              ]
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
