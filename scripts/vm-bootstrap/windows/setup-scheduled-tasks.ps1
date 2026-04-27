#Requires -Version 7.0
<#
.SYNOPSIS
    Register Scheduled Tasks for the VMSS Windows runner:
      - GhRunnerWatchdog: watchdog.ps1 every 60s as SYSTEM.
      - GhRunnerService : run.cmd as the gh-runner local account at logon / boot.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$BootstrapDir = 'C:\gh-runner-bootstrap'
$RunnerHome   = 'C:\actions-runner'
$Pwsh         = (Get-Command pwsh.exe).Source

# --- Watchdog task --------------------------------------------------------

$watchdogScript = Join-Path $BootstrapDir 'watchdog.ps1'
$watchdogAction = New-ScheduledTaskAction -Execute $Pwsh -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$watchdogScript`""

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Seconds 60)
$trigger.StartBoundary = (Get-Date).ToString('s')

$watchdogPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$watchdogSettings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

Register-ScheduledTask -TaskName 'GhRunnerWatchdog' `
    -Action   $watchdogAction `
    -Trigger  $trigger `
    -Principal $watchdogPrincipal `
    -Settings $watchdogSettings `
    -Description 'Idle / lifetime watchdog for the GitHub Actions self-hosted runner' `
    -Force | Out-Null

# --- Runner service task --------------------------------------------------
# The runner itself is usually registered with --runasservice (creates
# actions.runner.* Windows service) by config.cmd. We additionally install a
# Scheduled Task that launches run.cmd at boot as a safety net for images that
# don't use --runasservice.

$runnerAction  = New-ScheduledTaskAction -Execute (Join-Path $RunnerHome 'run.cmd') -WorkingDirectory $RunnerHome
$runnerTrigger = New-ScheduledTaskTrigger -AtStartup
$runnerPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$runnerSettings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 0)

# Only install this fallback task if the runner is not already registered as a
# Windows service. Prevents double-start.
$runnerService = Get-Service -Name 'actions.runner.*' -ErrorAction SilentlyContinue
if (-not $runnerService) {
    Register-ScheduledTask -TaskName 'GhRunnerService' `
        -Action    $runnerAction `
        -Trigger   $runnerTrigger `
        -Principal $runnerPrincipal `
        -Settings  $runnerSettings `
        -Description 'GitHub Actions self-hosted runner (fallback launcher)' `
        -Force | Out-Null
}

Write-Host '[setup-scheduled-tasks] done'
