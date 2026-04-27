# Verify required tools are on PATH AND actually runnable (fail build early if not).
# Get-Command only checks PATH resolution — it won't catch broken installs
# where the exe resolves but can't find its runtime DLLs (e.g. a mis-shimmed
# python.exe). Invoke each tool's --version to prove it actually runs.

$ErrorActionPreference = 'Continue'

$tools = @(
    @{ name = 'dotnet'; args = @('--version') },
    @{ name = 'node';   args = @('--version') },
    @{ name = 'npm';    args = @('--version') },
    @{ name = 'python'; args = @('--version') },
    @{ name = 'git';    args = @('--version') },
    @{ name = 'pwsh';   args = @('--version') }
)

$failed = @()

foreach ($t in $tools) {
    $c = Get-Command $t.name -ErrorAction SilentlyContinue
    if (-not $c) {
        Write-Host ('MISSING  ' + $t.name)
        $failed += $t.name
        continue
    }

    $out = & $t.name @($t.args) 2>&1 | Out-String
    $out = $out.Trim()

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($out)) {
        Write-Host ('BROKEN   ' + $t.name + ' -> ' + $c.Source + '  (exit=' + $LASTEXITCODE + ', output=' + $out + ')')
        $failed += $t.name
    }
    else {
        $firstLine = $out.Split("`n")[0]
        Write-Host ('OK       ' + $t.name + ' -> ' + $c.Source + '  ' + $firstLine)
    }
}

if ($failed.Count -gt 0) {
    Write-Host ('Failed tools: ' + ($failed -join ','))
    exit 1
}
