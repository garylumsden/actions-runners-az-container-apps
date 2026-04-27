#Requires -Version 7.0
<#
.SYNOPSIS
    Idle / lifetime watchdog for a VMSS-hosted Windows GitHub Actions runner.
    Runs every 60s as SYSTEM via Scheduled Task.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LifecycleDir    = 'C:\gh-runner-lifecycle'
$EtcDir          = 'C:\ProgramData\gh-runner'
$LifecycleEnv    = Join-Path $EtcDir       'lifecycle.json'
$JobActiveFile   = Join-Path $LifecycleDir 'job-active'
$BootFile        = Join-Path $LifecycleDir 'boot'
$LastEndFile     = Join-Path $LifecycleDir 'last-job-end'

function Write-Log { param([string]$Msg) Write-Host "[watchdog] $Msg" }

if (Test-Path $JobActiveFile) { return }
if (-not (Test-Path $LifecycleEnv)) { Write-Log 'lifecycle.json missing — skipping'; return }
if (-not (Test-Path $BootFile))     { Write-Log 'boot timestamp missing — skipping'; return }

$cfg = Get-Content $LifecycleEnv -Raw | ConvertFrom-Json

$now      = [int][double]::Parse((Get-Date -UFormat %s))
$boot     = [int](Get-Content $BootFile -Raw).Trim()
$lastEnd  = if (Test-Path $LastEndFile) { [int](Get-Content $LastEndFile -Raw).Trim() } else { $boot }

$idle = $now - $lastEnd
$age  = $now - $boot

$ephemeral = ($cfg.IdleRetentionMinutes -eq 0)

$reasons = @()
if (-not $ephemeral -and $idle -ge ($cfg.IdleRetentionMinutes * 60)) {
    $reasons += "idle ${idle}s >= retention $($cfg.IdleRetentionMinutes)m"
}
# #100: MaxLifetimeMinutes (when >0) overrides MaxLifetimeHours so CI and
# fine-grained production caps can recycle in <1h increments. Fall back to
# hours when minutes is missing/zero for backwards compatibility.
$maxMinutes = 0
if ($cfg.PSObject.Properties.Name -contains 'MaxLifetimeMinutes') {
    $maxMinutes = [int]$cfg.MaxLifetimeMinutes
}
if ($maxMinutes -gt 0) {
    $maxSeconds = $maxMinutes * 60
    $maxLabel   = "${maxMinutes}m"
} else {
    $maxSeconds = $cfg.MaxLifetimeHours * 3600
    $maxLabel   = "$($cfg.MaxLifetimeHours)h"
}
if ($maxSeconds -gt 0 -and $age -ge $maxSeconds) {
    $reasons += "age ${age}s >= max $maxLabel"
}

if ($reasons.Count -eq 0) { return }
Write-Log ("teardown: {0}" -f ($reasons -join '; '))

# Teardown ordering (fixes #93):
#   1. az vmss delete-instances --no-wait  -- starts infrastructure tear-down.
#      GitHub sees the runner go offline within ~30s once networking drops.
#   2. config.cmd remove                   -- clean local deregister; races
#      only with the runner removing its own config files. Harmless.
#   3. Stop-Computer -Force                -- belt-and-braces power off.
#
# Previous order (config.cmd remove BEFORE vmss delete-instances) left a
# multi-second window where the runner still appeared "online and idle" to
# the GitHub scheduler, which could assign a fresh job to a VM about to
# disappear. Reversing the order closes that window. Linux watchdog does the
# same thing (see scripts/vm-bootstrap/linux/watchdog.sh).
#
# TODO(hardening): the strictly atomic variant is a DELETE on
# /repos/.../actions/runners/{id} using an installation access token. That
# requires the GitHub App PEM on the VM, which this design deliberately
# avoids -- only the short-lived remove-token is persisted here.

# 1. Self-delete from the VMSS.
$vmssDeleteIssued = $false
try {
    if ($cfg.VmssName -and $cfg.ResourceGroup -and $cfg.RunnerIdentityClientId) {
        & az.cmd login --identity --username $cfg.RunnerIdentityClientId --allow-no-subscriptions 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $instanceOrdinal = ($cfg.VmInstanceName -split '_')[-1]
            Write-Log "az vmss delete-instances --name $($cfg.VmssName) --instance-ids $instanceOrdinal"
            & az.cmd vmss delete-instances `
                --resource-group $cfg.ResourceGroup `
                --name           $cfg.VmssName `
                --instance-ids   $instanceOrdinal `
                --no-wait 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $vmssDeleteIssued = $true
            } else {
                Write-Log "WARNING: vmss delete-instances exit $LASTEXITCODE — relying on shutdown"
            }
        } else {
            Write-Log 'WARNING: az login via MI failed — relying on shutdown'
        }
    }
} catch {
    Write-Log "WARNING: self-delete failed: $($_.Exception.Message)"
}

# 2. Deregister from GitHub. We re-fetch the remove-token from Key Vault
#    (per-instance secret, issue #92) using the VM's UAMI. The az login
#    above for the vmss-delete path should still be valid; if it wasn't,
#    we retry here idempotently. If the launcher has already best-effort-
#    deleted the secret (normal success path) or KV is unreachable we log
#    a warning and continue — GitHub-side runner records time out on their
#    own, and the VM is about to be deleted regardless.
$token = $null
try {
    if ($cfg.PSObject.Properties.Name -contains 'KvName' -and `
        $cfg.PSObject.Properties.Name -contains 'TokenSecretName' -and `
        $cfg.KvName -and $cfg.TokenSecretName) {
        & az.cmd login --identity --username $cfg.RunnerIdentityClientId --allow-no-subscriptions 2>$null | Out-Null
        $loginExit = $LASTEXITCODE
        if ($loginExit -ne 0) {
            # #98 I2: distinguish IMDS/MI login failure from KV secret fetch failure.
            # Previously both failure modes fell through to the same "could not fetch
            # remove-token" warning below, which made triage slow because the actual
            # cause (MI disabled, IMDS unreachable, UAMI revoked) was hidden.
            Write-Log "WARNING: az login --identity failed exit $loginExit — cannot fetch remove-token, skipping deregister (vmss delete issued=$vmssDeleteIssued)"
        } else {
            $secretJsonRaw = & az.cmd keyvault secret show `
                --vault-name $cfg.KvName `
                --name       $cfg.TokenSecretName `
                --query value -o tsv 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($secretJsonRaw)) {
                $secretObj = $secretJsonRaw | ConvertFrom-Json
                if ($secretObj -and $secretObj.PSObject.Properties.Name -contains 'remove') {
                    $token = $secretObj.remove
                }
                $secretObj = $null
            }
            $secretJsonRaw = $null
        }
    }

    if ($token) {
        Push-Location $cfg.RunnerHome
        try {
            & .\config.cmd remove --token $token
            if ($LASTEXITCODE -ne 0) {
                Write-Log "WARNING: config.cmd remove exit $LASTEXITCODE (token may have expired; vmss delete issued=$vmssDeleteIssued)"
            } else {
                Write-Log 'runner deregistered from GitHub'
            }
        } finally {
            Pop-Location
            Remove-Variable token -ErrorAction SilentlyContinue
        }
    } else {
        Write-Log "WARNING: could not fetch remove-token from KV (secret deleted or KV unreachable) — skipping deregister (vmss delete issued=$vmssDeleteIssued)"
    }
} catch {
    Write-Log "WARNING: deregister threw: $($_.Exception.Message)"
}

# 3. Belt-and-braces: shut down.
Write-Log 'Stop-Computer -Force'
Stop-Computer -Force
