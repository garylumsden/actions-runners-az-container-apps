// Azure Image Builder (AIB) imageTemplate for an Ubuntu 22.04 runner image
// with near-parity to the upstream actions/runner-images Ubuntu 22.04 bake
// (https://github.com/actions/runner-images/blob/bd758e8/images/ubuntu/templates/build.ubuntu-22_04.pkr.hcl).
//
// This module is STANDALONE — it is deliberately not wired into main.bicep.
// Deploy it only when you want to bake a VM/VMSS image; the default runner
// path in this repo remains ACA Jobs (Linux) + ACI (Windows).
//
// Parity model:
//   1. Clone actions/runner-images at the SHA in infra/runner-images-version.txt
//      into /opt/runner-images on a fresh Ubuntu 22.04 Gen2 base image.
//   2. Re-enable the `universe` apt pocket. Azure's Ubuntu 22.04 Gen2 base image
//      ships with only `main` + `restricted`; many upstream install-*.sh scripts
//      pull packages from `universe` (e.g. unzip, jq, zstd dependencies) and
//      fail fast without it. This MUST survive any refactor.
//   3. Export the exact env vars the upstream Packer template sets
//      (HELPER_SCRIPTS, INSTALLER_SCRIPT_FOLDER, DEBIAN_FRONTEND, IMAGE_VERSION,
//      IMAGE_OS, IMAGEDATA_FILE, AGENT_TOOLSDIRECTORY, IMAGE_FOLDER).
//   4. Iterate every executable shell script in the upstream scripts/build
//      directory in lexical order and run it via bash.
//   5. Pre-pull the actions/runner binary to /opt/actions-runner so the first
//      job on a fresh VM does not pay the cold download cost.

targetScope = 'resourceGroup'

@description('Name for the AIB imageTemplate resource.')
param name string

@description('Azure region for the AIB build VM and the resulting image.')
param location string

@description('Resource tags.')
param tags object = {}

@description('Resource ID of a user-assigned managed identity that AIB will use to write images into the gallery. The identity needs contributor on the gallery resource group.')
param aibIdentityId string

@description('Resource ID of the target Shared Image Gallery image definition (Microsoft.Compute/galleries/images). The baked image is published as a new version here.')
param galleryImageId string

@description('Regions where the gallery image version is replicated.')
param replicationRegions array = [
  location
]

@description('VM size used for the AIB build VM. Default balances build speed vs cost for the ~45-90 min Ubuntu bake.')
param buildVmSize string = 'Standard_D4s_v5'

@description('OS disk size in GB for the AIB build VM.')
param osDiskSizeGB int = 120

@description('Build timeout in minutes. Upstream bake is typically 60-90 min; 240 leaves headroom.')
param buildTimeoutMinutes int = 240

@description('Commit SHA of actions/runner-images to pin against. Loaded from infra/runner-images-version.txt by default.')
param vmssRunnerImagesCommit string = trim(loadTextContent('../runner-images-version.txt'))

@description('Pre-pulled actions/runner version published under /opt/actions-runner.')
param runnerVersion string = '2.333.1'

@description('Resource ID of the AIB build subnet. The build VM will be deployed into this subnet; egress is via the subnet\'s NAT Gateway. When empty, AIB uses its default MS-managed VNet.')
param buildSubnetId string = ''

@description('Resource ID of the AIB ACI (proxy/controller) subnet. Must be delegated to Microsoft.ContainerInstance/containerGroups. Required when buildSubnetId is set.')
param aciSubnetId string = ''

var imageOs = 'ubuntu22'
var imageFolder = '/imagegeneration'
var helperScripts = '${imageFolder}/helpers'
var installerScriptFolder = '${imageFolder}/installers'
var agentToolsDirectory = '/opt/hostedtoolcache'
var imageDataFile = '${imageFolder}/imagedata.json'
var metadataFile = '${imageFolder}/metadata.json'

resource imageTemplate 'Microsoft.VirtualMachineImages/imageTemplates@2024-02-01' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${aibIdentityId}': {}
    }
  }
  properties: {
    buildTimeoutInMinutes: buildTimeoutMinutes
    vmProfile: {
      vmSize: buildVmSize
      osDiskSizeGB: osDiskSizeGB
      vnetConfig: empty(buildSubnetId) ? null : {
        subnetId: buildSubnetId
        containerInstanceSubnetId: aciSubnetId
      }
    }
    source: {
      type: 'PlatformImage'
      publisher: 'Canonical'
      offer: '0001-com-ubuntu-server-jammy'
      sku: '22_04-lts-gen2'
      version: 'latest'
    }
    customize: [
      // Prepare working directories that the upstream scripts expect.
      {
        type: 'Shell'
        name: 'prepare-image-folder'
        inline: [
          'sudo mkdir -p ${imageFolder} ${helperScripts} ${installerScriptFolder} ${agentToolsDirectory}'
          'sudo chmod -R 0777 ${imageFolder} ${agentToolsDirectory}'
        ]
      }
      // Re-enable the universe pocket. Azure's Ubuntu 22.04 Gen2 base image
      // ships with only main+restricted enabled; many upstream install scripts
      // require universe packages (e.g. jq, unzip, zstd deps, certain libs).
      // This step is intentionally preserved — do not remove.
      {
        type: 'Shell'
        name: 'enable-universe-pocket'
        inline: [
          'sudo apt-get update'
          'sudo DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common ca-certificates curl gnupg git jq'
          'sudo add-apt-repository -y universe'
          'sudo apt-get update'
        ]
      }
      // Clone actions/runner-images at the pinned SHA.
      {
        type: 'Shell'
        name: 'clone-runner-images'
        inline: [
          'sudo git clone --no-checkout https://github.com/actions/runner-images.git /opt/runner-images'
          'sudo git -C /opt/runner-images -c advice.detachedHead=false checkout ${vmssRunnerImagesCommit}'
          'sudo cp -R /opt/runner-images/images/ubuntu/scripts/helpers/. ${helperScripts}/'
          'sudo cp -R /opt/runner-images/images/ubuntu/scripts/build/. ${installerScriptFolder}/'
          'sudo cp -R /opt/runner-images/images/ubuntu/assets ${imageFolder}/assets || true'
          'sudo cp /opt/runner-images/images/ubuntu/toolsets/toolset-2204.json ${installerScriptFolder}/toolset.json'
          'sudo chmod -R +x ${installerScriptFolder}'
        ]
      }
      // Seed the imagedata.json file the upstream configure-image-data.sh expects.
      {
        type: 'Shell'
        name: 'seed-image-data'
        inline: [
          'echo \'{"image":{"os":"${imageOs}","version":"${vmssRunnerImagesCommit}"}}\' | sudo tee ${imageDataFile} > /dev/null'
          'echo \'{"commit":"${vmssRunnerImagesCommit}","os":"${imageOs}"}\' | sudo tee ${metadataFile} > /dev/null'
        ]
      }
      // Run every install script in lexical order. Mirrors the upstream
      // Packer "shell" provisioner that lists ~60 install-*.sh scripts.
      {
        type: 'Shell'
        name: 'run-upstream-installers'
        inline: [
          'set -euo pipefail'
          'export HELPER_SCRIPTS=${helperScripts}'
          'export INSTALLER_SCRIPT_FOLDER=${installerScriptFolder}'
          'export IMAGE_FOLDER=${imageFolder}'
          'export IMAGE_OS=${imageOs}'
          'export IMAGE_VERSION=${vmssRunnerImagesCommit}'
          'export IMAGEDATA_FILE=${imageDataFile}'
          'export METADATAFILE=${metadataFile}'
          'export AGENT_TOOLSDIRECTORY=${agentToolsDirectory}'
          'export DEBIAN_FRONTEND=noninteractive'
          'for script in $(ls "${installerScriptFolder}"/*.sh | sort); do'
          '  echo "--- Running $script ---"'
          '  sudo -E bash "$script"'
          'done'
        ]
      }
      // Pre-pull the actions/runner binary so cold-start time on the baked VM
      // is not dominated by a ~75 MB download on first job.
      {
        type: 'Shell'
        name: 'pre-pull-runner-binary'
        inline: [
          'sudo mkdir -p /opt/actions-runner'
          'curl -fsSL -o /tmp/actions-runner.tar.gz "https://github.com/actions/runner/releases/download/v${runnerVersion}/actions-runner-linux-x64-${runnerVersion}.tar.gz"'
          'sudo tar -xzf /tmp/actions-runner.tar.gz -C /opt/actions-runner'
          'sudo rm -f /tmp/actions-runner.tar.gz'
          'sudo chown -R 1000:1000 /opt/actions-runner'
        ]
      }
    ]
    distribute: [
      {
        type: 'SharedImage'
        runOutputName: '${name}-sig'
        galleryImageId: galleryImageId
        replicationRegions: replicationRegions
        excludeFromLatest: false
        storageAccountType: 'Standard_LRS'
        artifactTags: {
          runnerImagesCommit: vmssRunnerImagesCommit
          imageOs: imageOs
        }
      }
    ]
  }
}

output id string = imageTemplate.id
output name string = imageTemplate.name
output pinnedCommit string = vmssRunnerImagesCommit
