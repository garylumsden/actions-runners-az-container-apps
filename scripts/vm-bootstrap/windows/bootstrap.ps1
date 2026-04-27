#Requires -Version 7.0
<#
.SYNOPSIS
    Bootstrap a GitHub Actions self-hosted runner on a VMSS Windows instance.

.DESCRIPTION
    Invoked by Custom Script Extension on first boot. Reads VMSS tags via IMDS,
    registers the runner, wires up job hooks, and installs Scheduled Tasks for
    (a) the 60s watchdog (SYSTEM) and (b) launching run.cmd as gh-runner at logon.

    Secrets flow (issue #92):
      - Registration + remove tokens live in a per-instance Key Vault secret
        named by the `ghRunnerTokenSecret` VMSS tag, in the vault named by
        `ghRunnerKvName`. The VM's UAMI is granted Key Vault Secrets User.
      - Nothing is persisted to disk. The watchdog re-fetches the remove-token
        from Key Vault at teardown. There is NO DPAPI blob, NO PEM, no long-
        lived secret material on the VM filesystem.

.NOTES
    VMSS tag contract matches the Linux side — see bootstrap.sh header.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RunnerHome      = 'C:\actions-runner'
$LifecycleDir    = 'C:\gh-runner-lifecycle'
$EtcDir          = 'C:\ProgramData\gh-runner'
$BootstrapDir    = 'C:\gh-runner-bootstrap'
$HookStarted     = Join-Path $BootstrapDir 'hooks\job-started.cmd'
$HookCompleted   = Join-Path $BootstrapDir 'hooks\job-completed.cmd'
$LifecycleEnv    = Join-Path $EtcDir       'lifecycle.json'
$CompleteMarker  = Join-Path $LifecycleDir 'bootstrap-complete'

function Write-Log { param([string]$Msg) Write-Host "[bootstrap] $Msg" }

# Reboot guard: the GhRunnerFirstBoot Scheduled Task fires AtStartup. After
# the first successful run the runner is installed as a Windows service that
# auto-starts on subsequent reboots — re-running bootstrap would clobber it
# and try to fetch a (possibly already-redeemed) registration token from KV.
if (Test-Path $CompleteMarker) {
    Write-Log "$CompleteMarker exists — bootstrap already ran on this VM, exiting"
    exit 0
}

function Get-ImdsTag {
    param([Parameter(Mandatory)][string]$Name)
    $tags = Invoke-RestMethod -Headers @{ Metadata = 'true' } `
        -Uri 'http://169.254.169.254/metadata/instance/compute/tagsList?api-version=2021-02-01' `
        -UseBasicParsing
    ($tags | Where-Object { $_.name -eq $Name } | Select-Object -First 1).value
}

function Get-ImdsText {
    param([Parameter(Mandatory)][string]$Path)
    Invoke-RestMethod -Headers @{ Metadata = 'true' } `
        -Uri ("http://169.254.169.254/metadata/instance/{0}?api-version=2021-02-01&format=text" -f $Path) `
        -UseBasicParsing
}

function Restrict-Acl {
    param([Parameter(Mandatory)][string]$Path)
    & icacls.exe $Path /inheritance:r | Out-Null
    & icacls.exe $Path /grant:r 'SYSTEM:F' 'BUILTIN\Administrators:F' | Out-Null
}

# --- main -----------------------------------------------------------------

Write-Log 'creating state directories'
foreach ($d in @($LifecycleDir, $EtcDir, $BootstrapDir, (Join-Path $BootstrapDir 'hooks'))) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

Write-Log 'reading VMSS tags via IMDS'
$tokenSecret  = Get-ImdsTag 'ghRunnerTokenSecret'
$kvName       = Get-ImdsTag 'ghRunnerKvName'
$labels       = Get-ImdsTag 'ghRunnerLabels'
$runnerName   = Get-ImdsTag 'ghRunnerName'
$url          = Get-ImdsTag 'ghRunnerUrl'
$scope        = Get-ImdsTag 'ghRunnerScope'
$idleRetRaw   = Get-ImdsTag 'ghRunnerIdleRetentionMinutes'
$maxLifeRaw   = Get-ImdsTag 'ghRunnerMaxLifetimeHours'
# #100: optional tag — launchers predating minutes-override won't stamp it.
# Treat missing/empty as "0" (watchdog falls through to hours).
$maxLifeMinRaw = Get-ImdsTag 'ghRunnerMaxLifetimeMinutes'
if ([string]::IsNullOrWhiteSpace($maxLifeMinRaw)) { $maxLifeMinRaw = '0' }
$miClientId   = Get-ImdsTag 'ghRunnerIdentityClientId'

if (-not $tokenSecret) { throw 'ghRunnerTokenSecret tag missing' }
if (-not $kvName)      { throw 'ghRunnerKvName tag missing' }
if (-not $labels)      { throw 'ghRunnerLabels tag missing' }
if (-not $runnerName)  { throw 'ghRunnerName tag missing' }
if (-not $url)         { throw 'ghRunnerUrl tag missing' }

# #89: fail loud rather than silently demote a warm runner to ephemeral.
# [int]$null / [int]'' would both coerce to 0 without complaint, which is the
# exact failure mode that caused the bug — guard explicitly.
if ([string]::IsNullOrWhiteSpace($idleRetRaw)) {
    throw 'ghRunnerIdleRetentionMinutes tag missing — VMSS launcher must stamp this (see docker/vmss-launcher/entrypoint.sh)'
}
if ([string]::IsNullOrWhiteSpace($maxLifeRaw)) {
    throw 'ghRunnerMaxLifetimeHours tag missing — VMSS launcher must stamp this (see docker/vmss-launcher/entrypoint.sh)'
}
if ($idleRetRaw -notmatch '^\d+$') {
    throw "ghRunnerIdleRetentionMinutes tag '$idleRetRaw' is not a non-negative integer"
}
if ($maxLifeRaw -notmatch '^\d+$') {
    throw "ghRunnerMaxLifetimeHours tag '$maxLifeRaw' is not a non-negative integer"
}
if ($maxLifeMinRaw -notmatch '^\d+$') {
    throw "ghRunnerMaxLifetimeMinutes tag '$maxLifeMinRaw' is not a non-negative integer"
}
$idleRetMin    = [int]$idleRetRaw
$maxLifeHours  = [int]$maxLifeRaw
$maxLifeMinutes = [int]$maxLifeMinRaw

$subscriptionId = Get-ImdsText 'compute/subscriptionId'
$resourceGroup  = Get-ImdsText 'compute/resourceGroupName'
$vmssName       = Get-ImdsText 'compute/vmScaleSetName'
$vmName         = Get-ImdsText 'compute/name'

Write-Log "writing $LifecycleEnv"
$cfg = [ordered]@{
    IdleRetentionMinutes   = $idleRetMin
    MaxLifetimeHours       = $maxLifeHours
    MaxLifetimeMinutes     = $maxLifeMinutes
    VmssName               = $vmssName
    ResourceGroup          = $resourceGroup
    SubscriptionId         = $subscriptionId
    VmInstanceName         = $vmName
    GhRunnerScopeUrl       = $url
    RunnerIdentityClientId = $miClientId
    KvName                 = $kvName
    TokenSecretName        = $tokenSecret
    LifecycleDir           = $LifecycleDir
    RunnerHome             = $RunnerHome
    RunnerUser             = 'gh-runner'
}
$cfg | ConvertTo-Json | Set-Content -Path $LifecycleEnv -Encoding UTF8
Restrict-Acl $LifecycleEnv

Write-Log "logging in with user-assigned managed identity (clientId=$miClientId)"
& az.cmd login --identity --username $miClientId --allow-no-subscriptions | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'az login --identity failed — cannot fetch runner-token secret from KV'
}

Write-Log "fetching runner-token secret '$tokenSecret' from Key Vault '$kvName'"
$secretJsonRaw = & az.cmd keyvault secret show `
    --vault-name $kvName `
    --name $tokenSecret `
    --query value -o tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($secretJsonRaw)) {
    throw "unable to fetch runner-token secret from Key Vault"
}
$secretObj   = $secretJsonRaw | ConvertFrom-Json
$regToken    = $secretObj.reg
$removeToken = $secretObj.remove
if ([string]::IsNullOrWhiteSpace($regToken))    { throw 'runner-token secret missing .reg field' }
if ([string]::IsNullOrWhiteSpace($removeToken)) { throw 'runner-token secret missing .remove field' }
# Scrub the combined JSON; only split tokens continue in memory. The remove-
# token is re-fetched from KV by the watchdog at teardown (see #92).
$secretJsonRaw = $null
$secretObj     = $null

Write-Log 'clearing KV-related tags from VMSS instance (cosmetic hardening)'
try {
    $resourceId = Get-ImdsText 'compute/resourceId'
    & az.cmd tag update --resource-id $resourceId --operation delete `
        --tags 'ghRunnerTokenSecret=' 'ghRunnerKvName=' 2>$null | Out-Null
} catch {
    Write-Log "tag wipe failed: $($_.Exception.Message)"
}

Write-Log 'recording boot timestamp'
[int][double]::Parse((Get-Date -UFormat %s)) | Set-Content -Path (Join-Path $LifecycleDir 'boot') -Encoding ASCII

Write-Log 'deploying hook scripts'
$hookRoot = Join-Path $BootstrapDir 'hooks'
Copy-Item -Path (Join-Path $PSScriptRoot 'hooks\job-started.cmd')   -Destination $hookRoot -Force -ErrorAction SilentlyContinue
Copy-Item -Path (Join-Path $PSScriptRoot 'hooks\job-completed.cmd') -Destination $hookRoot -Force -ErrorAction SilentlyContinue
Copy-Item -Path (Join-Path $PSScriptRoot 'hooks\job-completed.ps1') -Destination $hookRoot -Force -ErrorAction SilentlyContinue

Write-Log 'configuring GitHub runner'
Push-Location $RunnerHome
try {
    $configArgs = @(
        '--url',    $url,
        '--token',  $regToken,
        '--labels', $labels,
        '--name',   $runnerName,
        '--unattended',
        '--replace',
        '--disableupdate',
        '--runasservice'
    )
    if ($idleRetMin -eq 0) { $configArgs += '--ephemeral' }
    & .\config.cmd @configArgs
    if ($LASTEXITCODE -ne 0) { throw "config.cmd failed with exit $LASTEXITCODE" }
} finally {
    Pop-Location
}

Write-Log 'installing system-level environment variables for job hooks'
[Environment]::SetEnvironmentVariable('ACTIONS_RUNNER_HOOK_JOB_STARTED',   $HookStarted,   'Machine')
[Environment]::SetEnvironmentVariable('ACTIONS_RUNNER_HOOK_JOB_COMPLETED', $HookCompleted, 'Machine')

Write-Log 'installing scheduled tasks (watchdog + runner launcher)'
& (Join-Path $PSScriptRoot 'setup-scheduled-tasks.ps1')

Write-Log "writing completion marker $CompleteMarker"
Set-Content -Path $CompleteMarker -Value ([int][double]::Parse((Get-Date -UFormat %s))) -Encoding ASCII

Write-Log 'bootstrap complete'
