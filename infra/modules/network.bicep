// ─────────────────────────────────────────────────────────────────────────────
// Shared network for VMSS runners + Azure Image Builder (AIB) bakes.
//
// Single VNet, single NAT Gateway, three subnets with strong east-west NSG
// isolation. Replaces the previous split (`vmss-network.bicep` +
// `aib-network.bicep`) and per-VM instance-level public IPs on VMSS NICs.
//
// Topology:
//   VNet 10.42.0.0/23
//     ├── snet-vmss        10.42.0.0/26   (64 IPs)  → VMSS runner NICs
//     ├── snet-aib-build   10.42.1.0/27   (32 IPs)  → AIB build VM
//     └── snet-aib-aci     10.42.1.32/27 (32 IPs)  → AIB ACI controller,
//                                                    delegated to
//                                                    Microsoft.ContainerInstance
//
//   One Standard SKU NAT Gateway + one Standard SKU public IP attached to
//   ALL three subnets. All outbound traffic (runner jobs + AIB bakes) shares
//   a single audit-able egress IP.
//
// East-west isolation (defence-in-depth — AIB executes internet-fetched
// install scripts as root, so we treat it as a distinct trust zone from
// runners):
//   - VMSS NSG denies ALL traffic to/from both AIB subnets
//   - AIB build NSG denies ALL traffic to/from the VMSS subnet
//   - AIB ACI NSG denies ALL traffic to/from the VMSS subnet
//   - AIB Network Contributor role is scoped to the two AIB subnets only,
//     NOT the VNet, so a compromised AIB identity cannot modify the VMSS
//     subnet's NSG / route table / delegation.
//
// Design notes:
//   - Default Outbound Access (DOA) was retired 30 Sept 2025; all three
//     subnets explicitly set defaultOutboundAccess: false. Egress is
//     solely via the NAT Gateway.
//   - NAT Gateway SKU is **Standard** (NOT StandardV2). StandardV2 is
//     incompatible with subnets delegated to Microsoft.ContainerInstance,
//     which is exactly what snet-aib-aci requires.
//   - Keeping one VNet means AIB subnets and VMSS subnets share the same
//     address space root. Cross-subnet traffic is denied by NSG on both
//     sides; there is no route-table hop that could bypass the NSG.
//   - Cost: one Standard NAT GW (~$32/mo fixed + $0.045/GB processed) shared
//     across both workloads. Cheaper than the previous split (two NAT GWs /
//     per-instance PIPs) once both tiers are in use, and — for AIB only
//     (~2 hrs/week) — paid even when idle, but the simplicity and east-west
//     audit story outweigh the roughly $32/mo overhead.
// ─────────────────────────────────────────────────────────────────────────────

@description('Base name used to derive resource names (vnet, subnets, NAT GW, public IP, NSGs).')
@minLength(1)
@maxLength(48)
param name string

@description('Azure region. All resources in this module must be co-located; AIB imageTemplate and VMSS resources referencing these subnets must match.')
param location string

@description('Resource tags applied to every resource created by this module.')
param tags object = {}

@description('VNet address space. Must not overlap with any peered network. Default /23 gives room for the three required subnets plus headroom for future growth.')
param vnetAddressPrefix string = '10.42.0.0/23'

@description('Address prefix for the VMSS runner subnet. Default /26 (64 IPs, ~59 usable) fits vmssLinuxMaxInstances + vmssWindowsMaxInstances = 20 with plenty of headroom. Must be contained in vnetAddressPrefix.')
param vmssSubnetAddressPrefix string = '10.42.0.0/26'

@description('Address prefix for the AIB build subnet. Must be contained in vnetAddressPrefix, non-overlapping with all other subnets, and at least /28 (documented minimum for AIB build subnets).')
param aibBuildSubnetAddressPrefix string = '10.42.1.0/27'

@description('Address prefix for the AIB ACI controller subnet. Must be contained in vnetAddressPrefix, non-overlapping with all other subnets, and at least /28 because Microsoft.ContainerInstance delegated subnets are documented as /28-minimum.')
param aibAciSubnetAddressPrefix string = '10.42.1.32/27'

@description('Principal ID of the AIB build identity (id-<base>-aib). Granted Network Contributor scoped to the two AIB subnets only so AIB can attach the build VM and ACI controller. Pass an empty string when no AIB tier is enabled; the role assignment is then skipped.')
param aibPrincipalId string = ''

// ─── Public IP for NAT Gateway egress ────────────────────────────────────────

resource natPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-${name}-natgw'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
  }
}

// ─── Shared NAT Gateway ──────────────────────────────────────────────────────
// Standard SKU (NOT StandardV2) — required for subnets delegated to
// Microsoft.ContainerInstance/containerGroups (snet-aib-aci).
resource natGateway 'Microsoft.Network/natGateways@2024-05-01' = {
  name: 'natgw-${name}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [
      {
        id: natPublicIp.id
      }
    ]
  }
}

// ─── NSGs ────────────────────────────────────────────────────────────────────
// Cross-subnet deny rules are authored as a consolidated cluster of CIDRs so
// the rule count stays low. Each NSG carries one explicit deny vs both other
// trust zones (priorities 100/110) — these sit above any allow rules so
// cross-zone traffic can never be permitted by a lower-priority allow.

// VMSS subnet: no inbound from Internet, no east-west to AIB, permissive
// outbound to Internet via NAT GW.
resource vmssNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${name}-vmss'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Deny-FromAib-Build-In'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: aibBuildSubnetAddressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: vmssSubnetAddressPrefix
          destinationPortRange: '*'
          description: 'East-west isolation: AIB build VM cannot reach runner VMs.'
        }
      }
      {
        name: 'Deny-FromAib-Aci-In'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: aibAciSubnetAddressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: vmssSubnetAddressPrefix
          destinationPortRange: '*'
          description: 'East-west isolation: AIB ACI controller cannot reach runner VMs.'
        }
      }
      {
        name: 'Deny-ToAib-Build-Out'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: vmssSubnetAddressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: aibBuildSubnetAddressPrefix
          destinationPortRange: '*'
          description: 'East-west isolation: runner VMs cannot reach the AIB build subnet.'
        }
      }
      {
        name: 'Deny-ToAib-Aci-Out'
        properties: {
          priority: 110
          direction: 'Outbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: vmssSubnetAddressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: aibAciSubnetAddressPrefix
          destinationPortRange: '*'
          description: 'East-west isolation: runner VMs cannot reach the AIB ACI subnet.'
        }
      }
      {
        // Explicit named deny for portal/audit clarity on top of the built-in
        // 65500 DenyAllInBound. Prevents accidental override via an operator-
        // added low-priority allow.
        name: 'Deny-Internet-In'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
          description: 'Runners are outbound-only. Explicit deny in addition to the default 65500 DenyAllInBound.'
        }
      }
    ]
  }
}

// AIB build subnet: inbound 22/5986 from the ACI subnet only (AIB controller
// drives the build VM); deny VMSS; default-deny inbound; permissive outbound
// except VMSS zone.
resource aibBuildNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${name}-aib-build'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Deny-FromVmss-In'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: vmssSubnetAddressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: aibBuildSubnetAddressPrefix
          destinationPortRange: '*'
          description: 'East-west isolation: runner VMs cannot reach the AIB build VM.'
        }
      }
      {
        name: 'Allow-AciToBuild-SSH-In'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: aibAciSubnetAddressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: aibBuildSubnetAddressPrefix
          destinationPortRange: '22'
          description: 'AIB ACI controller -> Linux build VM (SSH).'
        }
      }
      {
        name: 'Allow-AciToBuild-WinRM-In'
        properties: {
          priority: 210
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: aibAciSubnetAddressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: aibBuildSubnetAddressPrefix
          destinationPortRange: '5986'
          description: 'AIB ACI controller -> Windows build VM (WinRM HTTPS).'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Default-deny inbound; SSH/WinRM allowed only from the ACI subnet above.'
        }
      }
      {
        name: 'Deny-ToVmss-Out'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: aibBuildSubnetAddressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: vmssSubnetAddressPrefix
          destinationPortRange: '*'
          description: 'East-west isolation: AIB build VM cannot reach runner VMs.'
        }
      }
    ]
  }
}

// AIB ACI subnet: no inbound required (controller is client-only); outbound
// to build subnet (22/5986) + Internet HTTPS/SMB; deny VMSS.
resource aibAciNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${name}-aib-aci'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Deny-FromVmss-In'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: vmssSubnetAddressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: aibAciSubnetAddressPrefix
          destinationPortRange: '*'
          description: 'East-west isolation: runner VMs cannot reach the AIB ACI controller.'
        }
      }
      {
        name: 'Deny-ToVmss-Out'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: aibAciSubnetAddressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: vmssSubnetAddressPrefix
          destinationPortRange: '*'
          description: 'East-west isolation: AIB ACI controller cannot reach runner VMs.'
        }
      }
      {
        name: 'Allow-AciToBuild-SSH-Out'
        properties: {
          priority: 200
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: aibAciSubnetAddressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: aibBuildSubnetAddressPrefix
          destinationPortRange: '22'
          description: 'AIB ACI controller -> Linux build VM (SSH).'
        }
      }
      {
        name: 'Allow-AciToBuild-WinRM-Out'
        properties: {
          priority: 210
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: aibAciSubnetAddressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: aibBuildSubnetAddressPrefix
          destinationPortRange: '5986'
          description: 'AIB ACI controller -> Windows build VM (WinRM HTTPS).'
        }
      }
      {
        name: 'Allow-Internet-Https-Out'
        properties: {
          priority: 300
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: aibAciSubnetAddressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '443'
          description: 'AIB ACI controller -> Azure ARM, image distribution (HTTPS).'
        }
      }
      {
        name: 'Allow-Internet-Smb-Out'
        properties: {
          priority: 310
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: aibAciSubnetAddressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '445'
          description: 'AIB ACI controller -> Azure Files / staging SA (SMB) used by some AIB internal staging operations.'
        }
      }
    ]
  }
}

// ─── VNet + subnets ──────────────────────────────────────────────────────────

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-${name}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'snet-vmss'
        properties: {
          addressPrefix: vmssSubnetAddressPrefix
          networkSecurityGroup: {
            id: vmssNsg.id
          }
          natGateway: {
            id: natGateway.id
          }
          defaultOutboundAccess: false
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'snet-aib-build'
        properties: {
          addressPrefix: aibBuildSubnetAddressPrefix
          networkSecurityGroup: {
            id: aibBuildNsg.id
          }
          natGateway: {
            id: natGateway.id
          }
          defaultOutboundAccess: false
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'snet-aib-aci'
        properties: {
          addressPrefix: aibAciSubnetAddressPrefix
          networkSecurityGroup: {
            id: aibAciNsg.id
          }
          natGateway: {
            id: natGateway.id
          }
          defaultOutboundAccess: false
          privateEndpointNetworkPolicies: 'Disabled'
          delegations: [
            {
              name: 'aci-delegation'
              properties: {
                serviceName: 'Microsoft.ContainerInstance/containerGroups'
              }
            }
          ]
        }
      }
    ]
  }
}

// ─── RBAC: AIB build identity → Network Contributor on AIB subnets only ──────
// AIB needs Microsoft.Network/virtualNetworks/subnets/join/action on the two
// AIB subnets to attach the build VM and ACI controller. Scope is restricted
// to the two AIB subnets — NOT the VNet — so a compromised AIB identity
// cannot modify the VMSS subnet's NSG, route table, or delegation.
//
// Role assignment is skipped when aibPrincipalId is empty (i.e. no AIB tier
// enabled, so identity.outputs.aibPrincipalId is '').

var networkContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7')

// Re-read the two AIB subnets as `existing` children so we can target
// roleAssignments at them individually (Bicep doesn't let us target a subnet
// authored inline inside a VNet resource as a role-assignment scope without
// an explicit reference).
resource aibBuildSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: 'snet-aib-build'
}

resource aibAciSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: 'snet-aib-aci'
}

resource aibBuildSubnetNetworkContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(aibPrincipalId)) {
  name: guid(vnet.id, 'snet-aib-build', aibPrincipalId, 'NetworkContributor')
  scope: aibBuildSubnet
  properties: {
    roleDefinitionId: networkContributorRoleId
    principalId: aibPrincipalId
    principalType: 'ServicePrincipal'
    description: 'AIB build identity: subnet/join on the AIB build subnet so AIB can attach the build VM.'
  }
}

resource aibAciSubnetNetworkContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(aibPrincipalId)) {
  name: guid(vnet.id, 'snet-aib-aci', aibPrincipalId, 'NetworkContributor')
  scope: aibAciSubnet
  properties: {
    roleDefinitionId: networkContributorRoleId
    principalId: aibPrincipalId
    principalType: 'ServicePrincipal'
    description: 'AIB build identity: subnet/join on the AIB ACI subnet so AIB can attach the ACI controller.'
  }
}

// ─── Outputs ─────────────────────────────────────────────────────────────────

output vnetId string = vnet.id
output vnetName string = vnet.name
output vmssSubnetId string = '${vnet.id}/subnets/snet-vmss'
output aibBuildSubnetId string = '${vnet.id}/subnets/snet-aib-build'
output aibAciSubnetId string = '${vnet.id}/subnets/snet-aib-aci'
output natGatewayPublicIp string = natPublicIp.properties.ipAddress
