# Runner job-completed hook — issue #90.
#
# Warm-retention VMSS instances reuse the same user profile, TEMP, and
# C:\actions-runner\_work tree across jobs. Without an explicit wipe, the
# next job inherits:
#   - the previous job's checkout, build outputs, and artefacts under _work\
#   - cached action code under _work\_actions (potentially tampered with)
#   - tool-cache binaries under _work\_tool (potentially planted)
#   - _temp files containing GITHUB_ENV / GITHUB_PATH / step outputs
#   - docker / git / cloud CLI credentials in $HOME (C:\Users\<runner>)
#   - User-scope environment variables / User-scope PATH appendage
#   - TEMP / LOCALAPPDATA\Temp debris
#
# Threat model: treat the previous job as adversarial. Everything the prior
# job could write that the next job could read or source is in-scope.
#
# Best-effort: individual failures must not abort the hook, or the runner's
# lifecycle bookkeeping (invoked from the .cmd wrapper) gets left dirty and
# the idle-retention watchdog misbehaves.

$ErrorActionPreference = 'SilentlyContinue'

function Write-Step { param([string]$Msg) Write-Host "[job-completed] $Msg" }

function Remove-DirContents {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Write-Step "wiping contents of $Path"
    Get-ChildItem -Force -LiteralPath $Path -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -Recurse -Force -LiteralPath $_.FullName -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# 1. Workspace wipe
# ---------------------------------------------------------------------------
# RUNNER_WORKSPACE is the per-repo dir (e.g. C:\actions-runner\_work\<repo>).
# We want the full _work root (parent), so _actions, _tool, _temp also go.
$workRoot = $null
if ($env:RUNNER_WORKSPACE -and (Test-Path -LiteralPath $env:RUNNER_WORKSPACE)) {
    $workRoot = (Resolve-Path -LiteralPath (Join-Path $env:RUNNER_WORKSPACE '..') -ErrorAction SilentlyContinue).Path
}
if (-not $workRoot) { $workRoot = 'C:\actions-runner\_work' }

if (Test-Path -LiteralPath $workRoot) {
    Write-Step "wiping workspace root $workRoot (keeping dir)"
    Remove-DirContents -Path $workRoot
}

# ---------------------------------------------------------------------------
# 2. Temp dirs
# ---------------------------------------------------------------------------
# Wipe TEMP, LOCALAPPDATA\Temp, and C:\Windows\Temp contents entirely.
# RUNNER_TEMP usually lives under _work\_temp (already cleared above).
$tempCandidates = @(
    $env:TEMP,
    $env:TMP,
    (Join-Path $env:LOCALAPPDATA 'Temp'),
    'C:\Windows\Temp',
    $env:RUNNER_TEMP
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

foreach ($t in $tempCandidates) {
    Remove-DirContents -Path $t
}

# ---------------------------------------------------------------------------
# 3. Credentials and caches in the runner user's profile
# ---------------------------------------------------------------------------
# Allow-list: what STAYS
#   - %USERPROFILE%\.ssh (baked keys / authorized_keys; known_hosts goes)
#   - PowerShell / cmd profile scripts (baked baseline)
# Everything else that holds credentials, tokens, or tamperable config is
# wiped.
$homeWipe = @(
    # Git
    "$HOME\.gitconfig",
    "$HOME\.git-credentials",
    "$HOME\.config\git",

    # Docker / containerd
    "$HOME\.docker",

    # Cloud CLIs (az, aws, gcloud, kubectl, helm)
    "$HOME\.azure",
    "$HOME\.aws",
    "$HOME\AppData\Roaming\gcloud",
    "$HOME\.kube",
    "$HOME\.config\helm",

    # Language / package managers
    "$HOME\.npmrc",
    "$HOME\AppData\Roaming\npm-cache",
    "$HOME\AppData\Local\npm-cache",
    "$HOME\.yarn",
    "$HOME\.yarnrc",
    "$HOME\.yarnrc.yml",
    "$HOME\pip",
    "$HOME\AppData\Roaming\pip",
    "$HOME\.pypirc",
    "$HOME\.m2\settings.xml",
    "$HOME\.m2\settings-security.xml",
    "$HOME\.gradle\caches",
    "$HOME\.gradle\init.d",
    "$HOME\.gradle\gradle.properties",
    "$HOME\.cargo\credentials",
    "$HOME\.cargo\credentials.toml",
    "$HOME\AppData\Roaming\NuGet\NuGet.Config",
    "$HOME\.nuget\NuGet\NuGet.Config",
    "$HOME\.composer",

    # gh CLI / netrc / keyring
    "$HOME\AppData\Roaming\GitHub CLI",
    "$HOME\.netrc",
    "$HOME\_netrc",

    # Shell / REPL history
    "$HOME\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt",
    "$HOME\.python_history",
    "$HOME\.node_repl_history",

    # SSH known_hosts only (leave baked keys / authorized_keys)
    "$HOME\.ssh\known_hosts",
    "$HOME\.ssh\known_hosts.old"
)
foreach ($path in $homeWipe) {
    if (Test-Path -LiteralPath $path) {
        Write-Step "wiping $path"
        Remove-Item -Recurse -Force -LiteralPath $path -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# 4. Reset User-scope environment variables / PATH mutations
# ---------------------------------------------------------------------------
# On Windows, GitHub Actions steps frequently use `[Environment]::SetEnvironmentVariable(
# 'FOO','bar','User')` or modify the User-scope PATH. Those writes persist
# in HKCU\Environment across jobs on warm VMs. Wipe every User-scope var
# except the Windows defaults that MUST stay for the shell to function.
#
# System-scope (HKLM\...\Environment) is untouched — that's the baked
# PATH / TEMP / TMP that the runner needs to operate.
$preserveUserEnv = @(
    'TEMP', 'TMP',               # default per-user temp pointers
    'OneDrive', 'OneDriveConsumer', 'OneDriveCommercial',
    'Path'                       # we reset (not remove) User PATH below
)
try {
    $userEnvKey = 'HKCU:\Environment'
    if (Test-Path $userEnvKey) {
        $props = Get-ItemProperty -Path $userEnvKey -ErrorAction SilentlyContinue
        if ($props) {
            foreach ($p in $props.PSObject.Properties) {
                if ($p.Name -like 'PS*') { continue }  # PSPath, PSParentPath, etc.
                if ($preserveUserEnv -contains $p.Name) { continue }
                Write-Step "removing User env $($p.Name)"
                Remove-ItemProperty -Path $userEnvKey -Name $p.Name -ErrorAction SilentlyContinue
            }
        }
    }
    # Reset User-scope PATH to empty — System PATH (HKLM) remains and is
    # what every process actually inherits on shell start. The User PATH
    # appends to it; a cleared User PATH means no job-appended leakage.
    Write-Step 'clearing User-scope PATH (System PATH untouched)'
    [Environment]::SetEnvironmentVariable('Path', '', 'User')
} catch {
    Write-Step "env reset failed: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# 5. Docker registry logouts
# ---------------------------------------------------------------------------
try {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if ($docker) {
        $info = & docker system info 2>$null
        if ($LASTEXITCODE -eq 0 -and $info) {
            $registries = @()
            foreach ($line in $info) {
                if ($line -match '^\s*Registry:\s*(\S+)') { $registries += $Matches[1] }
            }
            foreach ($r in ($registries | Select-Object -Unique)) {
                Write-Step "docker logout $r"
                & docker logout $r *>$null
            }
            Write-Step 'docker logout (default)'
            & docker logout *>$null
        }
    }
} catch { }

Write-Step 'wipe complete'
