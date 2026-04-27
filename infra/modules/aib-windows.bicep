// Azure Image Builder (AIB) imageTemplate for a Windows Server 2022 runner image
// with near-parity to the upstream actions/runner-images Windows 2022 bake
// (https://github.com/actions/runner-images/blob/bd758e8/images/windows/templates/build.windows-2022.pkr.hcl).
//
// This module is STANDALONE — it is deliberately not wired into main.bicep.
// Deploy it only when you want to bake a VM/VMSS image; the default Windows
// runner path in this repo is an ACA-Job-launched ACI container group.
//
// Parity model:
//   1. Clone actions/runner-images at the SHA in infra/runner-images-version.txt
//      into C:\runner-images on a fresh Windows Server 2022 Azure Edition base image.
//   2. Stage the upstream scripts/helpers/assets/toolsets under C:\imagegeneration
//      exactly where the Packer build expects them.
//   3. Run the upstream install scripts in PHASES that mirror the Packer
//      template's "windows-restart" boundaries. Every upstream `windows-restart`
//      provisioner maps to an AIB `WindowsRestart` customizer, followed by the
//      next `PowerShell` customizer. Getting these boundaries right matters —
//      several Install-*.ps1 scripts depend on features installed in the
//      previous phase being registered after a reboot (notably the Containers
//      feature required by Install-Docker.ps1 and the VS tooling installed
//      before the big Install-ChocolateyPackages phase).
//
// Upstream phase map (from build.windows-2022.pkr.hcl):
//   Phase 1  base config          → then RESTART (waits for Containers feature)
//   Phase 2  docker + pwsh core   → then RESTART (30m)
//   Phase 3  VisualStudio + K8s   → then RESTART (10m, check_registry)
//   Phase 4  Wix/WDK/AzureCLI etc → (no restart)
//   Phase 5  ServiceFabricSDK     → then RESTART (10m)
//   Phase 6  uninstall legacy Az PowerShell (windows-shell)
//   Phase 7  big install bundle   → (no restart)
//   Phase 8  Windows updates + configure → then RESTART (30m, check_registry)
//   Phase 9  updates-after-reboot + cleanup + tests
//   Phase 10 native images + configure + post-build validation → then RESTART (10m)
//   Phase 11 sysprep (handled by AIB distributor)

targetScope = 'resourceGroup'

@description('Name for the AIB imageTemplate resource.')
param name string

@description('Azure region for the AIB build VM and the resulting image. Must support Windows AIB.')
param location string

@description('Resource tags.')
param tags object = {}

@description('Resource ID of a user-assigned managed identity that AIB will use to write images into the gallery.')
param aibIdentityId string

@description('Resource ID of the target Shared Image Gallery image definition.')
param galleryImageId string

@description('Regions where the gallery image version is replicated.')
param replicationRegions array = [
  location
]

@description('VM size used for the AIB build VM. The Windows bake is I/O + memory heavy; D8s_v5 keeps it inside the upstream ~4-6 h window.')
param buildVmSize string = 'Standard_D8s_v5'

@description('OS disk size in GB for the AIB build VM.')
param osDiskSizeGB int = 250

@description('Build timeout in minutes. Upstream bake is typically 4-6 h; 360 min leaves headroom.')
param buildTimeoutMinutes int = 360

@description('Commit SHA of actions/runner-images to pin against. Loaded from infra/runner-images-version.txt by default.')
param vmssRunnerImagesCommit string = trim(loadTextContent('../runner-images-version.txt'))

@description('Pre-pulled actions/runner version published under C:\\actions-runner.')
param runnerVersion string = '2.333.1'

@description('Resource ID of the AIB build subnet. The build VM will be deployed into this subnet; egress is via the subnet\'s NAT Gateway. When empty, AIB uses its default MS-managed VNet.')
param buildSubnetId string = ''

@description('Resource ID of the AIB ACI (proxy/controller) subnet. Must be delegated to Microsoft.ContainerInstance/containerGroups. Required when buildSubnetId is set.')
param aciSubnetId string = ''

var imageOs = 'win22'
var imageFolder = 'C:\\imagegeneration'
var helperScriptFolder = 'C:\\imagegeneration\\helpers'
var tempDir = 'C:\\imagegeneration\\temp'
var imageDataFile = 'C:\\imagegeneration\\imagedata.json'
var agentToolsDirectory = 'C:\\hostedtoolcache\\windows'
var scriptsRoot = 'C:\\runner-images\\images\\windows\\scripts\\build'

// Env vars every PowerShell customizer exports so upstream scripts find their
// install roots. The upstream Packer template passes these per provisioner
// block; AIB lacks per-customizer env, so we prepend them via a shared
// header emitted by a helper.
var envHeader = [
  '$env:IMAGE_FOLDER = "${imageFolder}"'
  '$env:TEMP_DIR = "${tempDir}"'
  '$env:IMAGE_VERSION = "${vmssRunnerImagesCommit}"'
  '$env:IMAGE_OS = "${imageOs}"'
  '$env:AGENT_TOOLSDIRECTORY = "${agentToolsDirectory}"'
  '$env:IMAGEDATA_FILE = "${imageDataFile}"'
  '$env:HELPER_SCRIPT_FOLDER = "${helperScriptFolder}"'
  '$ErrorActionPreference = "Stop"'
]

var phase1Scripts = concat(envHeader, [
  '& "${scriptsRoot}\\Configure-WindowsDefender.ps1"'
  '& "${scriptsRoot}\\Configure-PowerShell.ps1"'
  '& "${scriptsRoot}\\Install-PowerShellModules.ps1"'
  '& "${scriptsRoot}\\Install-WindowsFeatures.ps1"'
  '& "${scriptsRoot}\\Install-Chocolatey.ps1"'
  '& "${scriptsRoot}\\Configure-BaseImage.ps1"'
  '& "${scriptsRoot}\\Configure-ImageDataFile.ps1"'
  '& "${scriptsRoot}\\Configure-SystemEnvironment.ps1"'
  '& "${scriptsRoot}\\Configure-DotnetSecureChannel.ps1"'
])

var phase2Scripts = concat(envHeader, [
  '& "${scriptsRoot}\\Install-Docker.ps1"'
  '& "${scriptsRoot}\\Install-DockerWinCred.ps1"'
  '& "${scriptsRoot}\\Install-DockerCompose.ps1"'
  '& "${scriptsRoot}\\Install-PowershellCore.ps1"'
  '& "${scriptsRoot}\\Install-WebPlatformInstaller.ps1"'
  '& "${scriptsRoot}\\Install-TortoiseSvn.ps1"'
])

var phase3Scripts = concat(envHeader, [
  '& "${scriptsRoot}\\Install-VisualStudio.ps1"'
  '& "${scriptsRoot}\\Install-KubernetesTools.ps1"'
])

var phase4Scripts = concat(envHeader, [
  '& "${scriptsRoot}\\Install-Wix.ps1"'
  '& "${scriptsRoot}\\Install-WDK.ps1"'
  '& "${scriptsRoot}\\Install-VSExtensions.ps1"'
  '& "${scriptsRoot}\\Install-AzureCli.ps1"'
  '& "${scriptsRoot}\\Install-AzureDevOpsCli.ps1"'
  '& "${scriptsRoot}\\Install-ChocolateyPackages.ps1"'
  '& "${scriptsRoot}\\Install-JavaTools.ps1"'
  '& "${scriptsRoot}\\Install-Kotlin.ps1"'
  '& "${scriptsRoot}\\Install-OpenSSL.ps1"'
])

var phase5Scripts = concat(envHeader, [
  '& "${scriptsRoot}\\Install-ServiceFabricSDK.ps1"'
])

var phase7Scripts = concat(envHeader, [
  '& "${scriptsRoot}\\Install-ActionsCache.ps1"'
  '& "${scriptsRoot}\\Install-Ruby.ps1"'
  '& "${scriptsRoot}\\Install-PyPy.ps1"'
  '& "${scriptsRoot}\\Install-Toolset.ps1"'
  '& "${scriptsRoot}\\Configure-Toolset.ps1"'
  '& "${scriptsRoot}\\Install-NodeJS.ps1"'
  '& "${scriptsRoot}\\Install-AndroidSDK.ps1"'
  '& "${scriptsRoot}\\Install-PowershellAzModules.ps1"'
  '& "${scriptsRoot}\\Install-Pipx.ps1"'
  '& "${scriptsRoot}\\Install-Git.ps1"'
  '& "${scriptsRoot}\\Install-GitHub-CLI.ps1"'
  '& "${scriptsRoot}\\Install-PHP.ps1"'
  '& "${scriptsRoot}\\Install-Rust.ps1"'
  '& "${scriptsRoot}\\Install-Sbt.ps1"'
  '& "${scriptsRoot}\\Install-Chrome.ps1"'
  '& "${scriptsRoot}\\Install-EdgeDriver.ps1"'
  '& "${scriptsRoot}\\Install-Firefox.ps1"'
  '& "${scriptsRoot}\\Install-Selenium.ps1"'
  '& "${scriptsRoot}\\Install-IEWebDriver.ps1"'
  '& "${scriptsRoot}\\Install-Apache.ps1"'
  '& "${scriptsRoot}\\Install-Nginx.ps1"'
  '& "${scriptsRoot}\\Install-Msys2.ps1"'
  '& "${scriptsRoot}\\Install-WinAppDriver.ps1"'
  '& "${scriptsRoot}\\Install-R.ps1"'
  '& "${scriptsRoot}\\Install-AWSTools.ps1"'
  '& "${scriptsRoot}\\Install-DACFx.ps1"'
  '& "${scriptsRoot}\\Install-MysqlCli.ps1"'
  '& "${scriptsRoot}\\Install-SQLPowerShellTools.ps1"'
  '& "${scriptsRoot}\\Install-SQLOLEDBDriver.ps1"'
  '& "${scriptsRoot}\\Install-DotnetSDK.ps1"'
  '& "${scriptsRoot}\\Install-Mingw64.ps1"'
  '& "${scriptsRoot}\\Install-Haskell.ps1"'
  '& "${scriptsRoot}\\Install-Stack.ps1"'
  '& "${scriptsRoot}\\Install-Miniconda.ps1"'
  '& "${scriptsRoot}\\Install-AzureCosmosDbEmulator.ps1"'
  '& "${scriptsRoot}\\Install-Mercurial.ps1"'
  '& "${scriptsRoot}\\Install-Zstd.ps1"'
  '& "${scriptsRoot}\\Install-NSIS.ps1"'
  '& "${scriptsRoot}\\Install-Vcpkg.ps1"'
  '& "${scriptsRoot}\\Install-PostgreSQL.ps1"'
  '& "${scriptsRoot}\\Install-Bazel.ps1"'
  '& "${scriptsRoot}\\Install-AliyunCli.ps1"'
  '& "${scriptsRoot}\\Install-RootCA.ps1"'
  '& "${scriptsRoot}\\Install-MongoDB.ps1"'
  '& "${scriptsRoot}\\Install-CodeQLBundle.ps1"'
  '& "${scriptsRoot}\\Configure-Diagnostics.ps1"'
])

var phase8Scripts = concat(envHeader, [
  '& "${scriptsRoot}\\Install-WindowsUpdates.ps1"'
  '& "${scriptsRoot}\\Configure-DynamicPort.ps1"'
  '& "${scriptsRoot}\\Configure-GDIProcessHandleQuota.ps1"'
  '& "${scriptsRoot}\\Configure-Shell.ps1"'
  '& "${scriptsRoot}\\Configure-DeveloperMode.ps1"'
  '& "${scriptsRoot}\\Install-LLVM.ps1"'
])

var phase9Scripts = concat(envHeader, [
  '& "${scriptsRoot}\\Install-WindowsUpdatesAfterReboot.ps1"'
  '& "${scriptsRoot}\\Invoke-Cleanup.ps1"'
])

var phase10Scripts = concat(envHeader, [
  '& "${scriptsRoot}\\Install-NativeImages.ps1"'
  '& "${scriptsRoot}\\Configure-System.ps1"'
  '& "${scriptsRoot}\\Post-Build-Validation.ps1"'
])

// ── VMSS-Windows bootstrap baking (issue #51) ────────────────────────────
// Bake the bootstrap scripts into the image and register an AtStartup
// Scheduled Task that invokes bootstrap.ps1 on first boot. Mirrors the
// Linux cloud-init/customData approach.
var bootstrapPs1B64       = loadFileAsBase64('../../scripts/vm-bootstrap/windows/bootstrap.ps1')
var watchdogPs1B64        = loadFileAsBase64('../../scripts/vm-bootstrap/windows/watchdog.ps1')
var setupTasksPs1B64      = loadFileAsBase64('../../scripts/vm-bootstrap/windows/setup-scheduled-tasks.ps1')
var hookJobStartedB64     = loadFileAsBase64('../../scripts/vm-bootstrap/windows/hooks/job-started.cmd')
var hookJobCompletedCmdB64 = loadFileAsBase64('../../scripts/vm-bootstrap/windows/hooks/job-completed.cmd')
var hookJobCompletedPs1B64 = loadFileAsBase64('../../scripts/vm-bootstrap/windows/hooks/job-completed.ps1')

var bakeBootstrapScripts = [
  '$ProgressPreference = "SilentlyContinue"'
  'New-Item -ItemType Directory -Force -Path C:\\gh-runner-bootstrap | Out-Null'
  'New-Item -ItemType Directory -Force -Path C:\\gh-runner-bootstrap\\hooks | Out-Null'
  '[IO.File]::WriteAllBytes(\'C:\\gh-runner-bootstrap\\bootstrap.ps1\', [Convert]::FromBase64String(\'${bootstrapPs1B64}\'))'
  '[IO.File]::WriteAllBytes(\'C:\\gh-runner-bootstrap\\watchdog.ps1\', [Convert]::FromBase64String(\'${watchdogPs1B64}\'))'
  '[IO.File]::WriteAllBytes(\'C:\\gh-runner-bootstrap\\setup-scheduled-tasks.ps1\', [Convert]::FromBase64String(\'${setupTasksPs1B64}\'))'
  '[IO.File]::WriteAllBytes(\'C:\\gh-runner-bootstrap\\hooks\\job-started.cmd\', [Convert]::FromBase64String(\'${hookJobStartedB64}\'))'
  '[IO.File]::WriteAllBytes(\'C:\\gh-runner-bootstrap\\hooks\\job-completed.cmd\', [Convert]::FromBase64String(\'${hookJobCompletedCmdB64}\'))'
  '[IO.File]::WriteAllBytes(\'C:\\gh-runner-bootstrap\\hooks\\job-completed.ps1\', [Convert]::FromBase64String(\'${hookJobCompletedPs1B64}\'))'
  'Write-Host "[bake] bootstrap files written to C:\\gh-runner-bootstrap"'
  '$pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source; if (-not $pwsh) { $pwsh = "C:\\Program Files\\PowerShell\\7\\pwsh.exe" }'
  'if (-not (Test-Path $pwsh)) { throw "pwsh.exe not found — bootstrap.ps1 needs PowerShell 7 (RSA.ImportFromPem requires .NET 6+)" }'
  '$action = New-ScheduledTaskAction -Execute $pwsh -Argument \'-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\\gh-runner-bootstrap\\bootstrap.ps1"\''
  '$trigger = New-ScheduledTaskTrigger -AtStartup'
  '$principal = New-ScheduledTaskPrincipal -UserId \'SYSTEM\' -LogonType ServiceAccount -RunLevel Highest'
  '$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries'
  'Register-ScheduledTask -TaskName \'GhRunnerFirstBoot\' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null'
  'Write-Host "[bake] GhRunnerFirstBoot scheduled task registered"'
]

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
      publisher: 'MicrosoftWindowsServer'
      offer: 'WindowsServer'
      sku: '2022-datacenter-azure-edition'
      version: 'latest'
    }
    customize: [
      // Prepare directory layout and clone upstream.
      {
        type: 'PowerShell'
        name: 'prepare-image-folder'
        runElevated: true
        runAsSystem: true
        inline: [
          'New-Item -ItemType Directory -Force -Path "${imageFolder}" | Out-Null'
          'New-Item -ItemType Directory -Force -Path "${helperScriptFolder}" | Out-Null'
          'New-Item -ItemType Directory -Force -Path "${tempDir}" | Out-Null'
          'New-Item -ItemType Directory -Force -Path "${agentToolsDirectory}" | Out-Null'
          '[Environment]::SetEnvironmentVariable("AGENT_TOOLSDIRECTORY", "${agentToolsDirectory}", "Machine")'
          '[Environment]::SetEnvironmentVariable("ImageOS", "${imageOs}", "Machine")'
        ]
      }
      {
        type: 'PowerShell'
        name: 'clone-runner-images'
        runElevated: true
        runAsSystem: true
        inline: [
          '$ProgressPreference = "SilentlyContinue"'
          'if (-not (Get-Command git -ErrorAction SilentlyContinue)) {'
          '  Invoke-WebRequest -UseBasicParsing -Uri "https://chocolatey.org/install.ps1" -OutFile "${tempDir}\\choco-install.ps1"'
          '  Set-ExecutionPolicy Bypass -Scope Process -Force'
          '  & "${tempDir}\\choco-install.ps1"'
          '  & "$env:ALLUSERSPROFILE\\chocolatey\\bin\\choco.exe" install git -y --no-progress'
          '  $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine")'
          '}'
          'git clone --no-checkout https://github.com/actions/runner-images.git C:\\runner-images'
          'git -C C:\\runner-images -c advice.detachedHead=false checkout ${vmssRunnerImagesCommit}'
          'Copy-Item -Recurse -Force C:\\runner-images\\images\\windows\\scripts\\helpers\\* "${helperScriptFolder}\\"'
          'Copy-Item -Recurse -Force C:\\runner-images\\images\\windows\\assets "${imageFolder}\\assets"'
          'Copy-Item -Force C:\\runner-images\\images\\windows\\toolsets\\toolset-2022.json "${imageFolder}\\toolset.json"'
          '@{ image = @{ os = "${imageOs}"; version = "${vmssRunnerImagesCommit}" } } | ConvertTo-Json | Out-File -FilePath "${imageDataFile}" -Encoding utf8 -Force'
        ]
      }
      // ── Phase 1 ──────────────────────────────────────────────────────────
      {
        type: 'PowerShell'
        name: 'phase-1-base-config'
        runElevated: true
        runAsSystem: true
        inline: phase1Scripts
      }
      {
        type: 'WindowsRestart'
        restartTimeout: 'PT10M'
      }
      // ── Phase 2 ──────────────────────────────────────────────────────────
      {
        type: 'PowerShell'
        name: 'phase-2-docker-pwsh'
        runElevated: true
        runAsSystem: true
        inline: phase2Scripts
      }
      {
        type: 'WindowsRestart'
        restartTimeout: 'PT30M'
      }
      // ── Phase 3 ──────────────────────────────────────────────────────────
      {
        type: 'PowerShell'
        name: 'phase-3-visualstudio-k8s'
        runElevated: true
        runAsSystem: true
        validExitCodes: [
          0
          3010
        ]
        inline: phase3Scripts
      }
      {
        type: 'WindowsRestart'
        restartTimeout: 'PT10M'
      }
      // ── Phase 4 (no restart per upstream) ────────────────────────────────
      {
        type: 'PowerShell'
        name: 'phase-4-choco-cli-bundle'
        runElevated: true
        runAsSystem: true
        inline: phase4Scripts
      }
      // ── Phase 5 ──────────────────────────────────────────────────────────
      {
        type: 'PowerShell'
        name: 'phase-5-servicefabric-sdk'
        runElevated: true
        runAsSystem: true
        inline: phase5Scripts
      }
      {
        type: 'WindowsRestart'
        restartTimeout: 'PT10M'
      }
      // ── Phase 6 ─ uninstall legacy Azure PowerShell (windows-shell in upstream)
      {
        type: 'PowerShell'
        name: 'phase-6-uninstall-legacy-azps'
        runElevated: true
        runAsSystem: true
        inline: [
          'cmd /c "wmic product where \\"name like \'%%microsoft azure powershell%%\'\\" call uninstall /nointeractive" | Out-Null'
          'exit 0'
        ]
      }
      // ── Phase 7 ─ big bundle ─────────────────────────────────────────────
      {
        type: 'PowerShell'
        name: 'phase-7-install-bundle'
        runElevated: true
        runAsSystem: true
        inline: phase7Scripts
      }
      // ── Phase 8 ──────────────────────────────────────────────────────────
      {
        type: 'PowerShell'
        name: 'phase-8-updates-configure'
        runElevated: true
        runAsSystem: true
        inline: phase8Scripts
      }
      {
        type: 'WindowsRestart'
        restartTimeout: 'PT30M'
      }
      // ── Phase 9 ──────────────────────────────────────────────────────────
      {
        type: 'PowerShell'
        name: 'phase-9-post-reboot-cleanup'
        runElevated: true
        runAsSystem: true
        inline: phase9Scripts
      }
      // ── Pre-pull actions-runner binary ───────────────────────────────────
      {
        type: 'PowerShell'
        name: 'pre-pull-runner-binary'
        runElevated: true
        runAsSystem: true
        inline: [
          '$ProgressPreference = "SilentlyContinue"'
          'New-Item -ItemType Directory -Force -Path C:\\actions-runner | Out-Null'
          'Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/actions/runner/releases/download/v${runnerVersion}/actions-runner-win-x64-${runnerVersion}.zip" -OutFile "${tempDir}\\runner.zip"'
          'Expand-Archive -Path "${tempDir}\\runner.zip" -DestinationPath C:\\actions-runner -Force'
          'Remove-Item "${tempDir}\\runner.zip" -Force'
        ]
      }
      // ── Bake VMSS bootstrap scripts + AtStartup Scheduled Task ───────────
      {
        type: 'PowerShell'
        name: 'bake-vmss-bootstrap'
        runElevated: true
        runAsSystem: true
        inline: bakeBootstrapScripts
      }
      // ── Phase 10 ─ final native-image pass + validation ──────────────────
      {
        type: 'PowerShell'
        name: 'phase-10-native-images-validate'
        runElevated: true
        runAsSystem: true
        inline: phase10Scripts
      }
      {
        type: 'WindowsRestart'
        restartTimeout: 'PT10M'
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
