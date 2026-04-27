#Requires -Version 7
# Windows ACI GitHub Actions runner entrypoint.
# Authenticates using GitHub App JWT, registers as an ephemeral runner, runs one job, then exits.
$ErrorActionPreference = 'Stop'

# ── Decode the base64-encoded PEM ─────────────────────────────────────────────
$pemContent = [System.Text.Encoding]::UTF8.GetString(
    [System.Convert]::FromBase64String($env:GITHUB_APP_PEM_B64))
$pemPath = Join-Path $env:TEMP "pem-$PID-$([guid]::NewGuid().ToString('N').Substring(0,8)).pem"

# Defense-in-depth cleanup: ensure the PEM is removed on every exit path,
# including exceptions from ImportFromPem / SignData and process teardown
# (e.g. ACI stopping the container). Registered before the PEM is written.
$script:pemPath = $pemPath
$cleanupPem = {
    if ($script:pemPath -and (Test-Path -LiteralPath $script:pemPath)) {
        Remove-Item -LiteralPath $script:pemPath -Force -ErrorAction SilentlyContinue
    }
}
# PowerShell.Exiting fires inside the PS engine before shutdown, so the
# runspace is still alive when the action runs. This is the PS-native
# equivalent of AppDomain.ProcessExit -- the latter is unsafe here because
# the runspace may already be torn down when .NET raises ProcessExit,
# causing scriptblock invocation to throw and the PEM to leak.
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    $p = $Event.MessageData
    if ($p -and (Test-Path $p)) {
        Remove-Item -Force -ErrorAction SilentlyContinue $p
    }
} -MessageData $pemPath | Out-Null
try {
    [Console]::add_CancelKeyPress([System.ConsoleCancelEventHandler]$cleanupPem)
} catch {
    # Non-interactive hosts may not support CancelKeyPress; not fatal.
}

try {
    Set-Content -Path $pemPath -Value $pemContent -NoNewline -Encoding UTF8

    # ── JWT generation ────────────────────────────────────────────────────────
    function ConvertTo-Base64Url([byte[]] $bytes) {
        [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    }

    $now  = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $iat  = $now - 60    # issued 60s in the past to account for clock skew
    $exp  = $now + 600   # 10-minute expiry

    $header  = ConvertTo-Base64Url([Text.Encoding]::UTF8.GetBytes('{"typ":"JWT","alg":"RS256"}'))
    $payload = ConvertTo-Base64Url([Text.Encoding]::UTF8.GetBytes(
        "{`"iat`":$iat,`"exp`":$exp,`"iss`":$($env:GITHUB_APP_ID)}"))

    $hp  = "$header.$payload"
    $rsa = [System.Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportFromPem((Get-Content $pemPath -Raw))
        $sig = ConvertTo-Base64Url($rsa.SignData(
            [Text.Encoding]::UTF8.GetBytes($hp),
            [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1))
    } finally {
        $rsa.Dispose()
    }
} finally {
    & $cleanupPem
}

$jwt = "$hp.$sig"

# ── Exchange JWT for an installation access token ─────────────────────────────
$accessToken = (Invoke-RestMethod -Method Post -Uri $env:ACCESS_TOKEN_API_URL -Headers @{
    'Accept'               = 'application/vnd.github+json'
    'Authorization'        = "Bearer $jwt"
    'X-GitHub-Api-Version' = '2022-11-28'
}).token

# ── Get a short-lived runner registration token ───────────────────────────────
$regToken = (Invoke-RestMethod -Method Post -Uri $env:REGISTRATION_TOKEN_API_URL -Headers @{
    'Accept'               = 'application/vnd.github.v3+json'
    'Authorization'        = "Bearer $accessToken"
    'X-GitHub-Api-Version' = '2022-11-28'
}).token

# ── Get a short-lived runner *remove* (deregistration) token ──────────────────
# Mirrors the registration-token endpoint — only the trailing path segment
# differs. Fetching it now (while we still have the installation access
# token) lets the `finally` block deregister without another JWT round trip,
# which is important under crash/abort conditions (#50, #60).
$removeTokenUrl = $env:REGISTRATION_TOKEN_API_URL -replace 'registration-token$','remove-token'
$removeToken = (Invoke-RestMethod -Method Post -Uri $removeTokenUrl -Headers @{
    'Accept'               = 'application/vnd.github.v3+json'
    'Authorization'        = "Bearer $accessToken"
    'X-GitHub-Api-Version' = '2022-11-28'
}).token

# ── Resolve runner labels with a safe default ─────────────────────────────────
# If RUNNER_LABELS is missing/empty the runner would register with no custom
# labels and could be matched by unrelated workflow jobs. Default to the same
# label set the ACA KEDA scaler filters on.
if ([string]::IsNullOrWhiteSpace($env:RUNNER_LABELS)) {
    $labels = 'self-hosted,windows,aci'
} else {
    $labels = $env:RUNNER_LABELS
}
Write-Host "Registering runner with labels: $labels"

# ── Scrub sensitive material from the environment ─────────────────────────────
# The base64 PEM (and JWT) would otherwise be inherited by every user workflow
# step, which is a trivial exfiltration vector for a malicious action.
Remove-Item Env:\GITHUB_APP_PEM_B64 -ErrorAction SilentlyContinue
$jwt = $null
$pemContent = $null

# ── Register and run the ephemeral runner ─────────────────────────────────────
$runnerName = "win-aci-$([System.Net.Dns]::GetHostName().ToLower())"

& C:\actions-runner\config.cmd `
    --url   $env:RUNNER_REGISTRATION_URL `
    --token $regToken `
    --name  $runnerName `
    --labels $labels `
    --unattended `
    --ephemeral `
    --disableupdate
if ($LASTEXITCODE -ne 0) {
    throw "config.cmd failed with exit code $LASTEXITCODE"
}

# Clear tokens now that config.cmd has consumed them.
$regToken = $null
$accessToken = $null

# Run the runner inside try/finally so we *always* deregister (#60) and so
# run.cmd's exit code is propagated back to ACI (#50). Without `exit
# $LASTEXITCODE`, a crashed runner reports Succeeded and masks failures.
$runnerExit = 0
try {
    & C:\actions-runner\run.cmd
    $runnerExit = $LASTEXITCODE
} finally {
    # Defence in depth: --ephemeral would normally deregister, but SIGKILL /
    # ACI force-delete leaves the runner registered for up to 24h.
    try {
        & C:\actions-runner\config.cmd remove --token $removeToken | Out-Host
    } catch {
        Write-Host "config.cmd remove failed: $_"
    }
    $removeToken = $null
}

exit $runnerExit
