# Windows GitHub Actions runner image.
# Base: Microsoft's official .NET SDK 10 image (Windows Server Core ltsc2022).
# Using the SDK image rather than bare servercore means .NET 10 is pre-installed and
# patched by Microsoft; older SDK versions are added side-by-side for legacy project support.
#
# Parity: actions/runner-images@bd758e8a199c411f081c3c5d78be527b9296332c (2026-04-22)
# See docs/runner-images-parity.md for the PORT / SKIP classification of every
# upstream Install-*.ps1 script. New PORT tools (Azure CLI, GitHub CLI, kubectl,
# helm, Java, AWS CLI) are grouped below after the language runtimes.
#
# NOTE: WSL is NOT supported in Windows containers (requires Hyper-V kernel features
# unavailable in ACI). Use the Linux runner for WSL/bash workloads.
#
# NOTE: winget is NOT supported in Windows Server Core containers (requires the UWP
# App Installer service which is absent from Server Core). Chocolatey is used instead.
#
# NOTE: Docker-in-Docker is NOT supported (Containers Windows feature requires a
# kernel restart that ACI does not allow). Install-Docker.ps1 is SKIPPED.
#
# Base pinned by tag + digest (#15). When updating the tag, refresh the digest:
#   docker buildx imagetools inspect mcr.microsoft.com/dotnet/sdk:10.0-windowsservercore-ltsc2022
FROM mcr.microsoft.com/dotnet/sdk:10.0-windowsservercore-ltsc2022@sha256:2ed7122132852dfe6920e1ff03a6e0b8de84836c22da3c440db515385087bb6d

SHELL ["C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

# ── PowerShell 7 ─────────────────────────────────────────────────────────────
# Required for RSA.ImportFromPem() used in entrypoint.ps1.
# The base image ships with PowerShell Core but we pin the version explicitly.
# SHA256 from the official hashes.sha256 asset on the PowerShell release page:
# https://github.com/PowerShell/PowerShell/releases/tag/v7.4.6 (#24)
ARG PS_VERSION=7.4.6
ARG PS_SHA256=ed331a04679b83d4c013705282d1f3f8d8300485eb04c081f36e11eaf1148bd0
RUN Invoke-WebRequest \
        -Uri "https://github.com/PowerShell/PowerShell/releases/download/v${env:PS_VERSION}/PowerShell-${env:PS_VERSION}-win-x64.msi" \
        -OutFile C:\ps7.msi; \
    $actual = (Get-FileHash -Path C:\ps7.msi -Algorithm SHA256).Hash.ToLower(); \
    if ($actual -ne $env:PS_SHA256.ToLower()) { \
        throw "PowerShell MSI SHA256 mismatch. Expected: $env:PS_SHA256 Actual: $actual"; \
    }; \
    Start-Process msiexec.exe -Wait -ArgumentList '/I C:\ps7.msi /quiet /norestart'; \
    Remove-Item C:\ps7.msi

# ── Chocolatey ────────────────────────────────────────────────────────────────
# Chocolatey does not publish a stable SHA256 for install.ps1 (it is regenerated
# on each release). We pin to a SHA captured at a known point in time and
# verify before execution; when the upstream script changes, the build fails
# loudly and a human updates CHOCO_INSTALLER_SHA256 after reviewing the diff.
# Consider mirroring a pinned copy to ACR (#24).
# SHA captured 2026-04-22 from https://community.chocolatey.org/install.ps1
ARG CHOCO_INSTALLER_SHA256=44e045ed5350758616d664c5af631e7f2cd10165f5bf2bd82cbf3a0bb8f63462
RUN Set-ExecutionPolicy Bypass -Scope Process -Force; \
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; \
    Invoke-WebRequest -Uri 'https://community.chocolatey.org/install.ps1' -OutFile C:\choco.ps1; \
    $actual = (Get-FileHash -Path C:\choco.ps1 -Algorithm SHA256).Hash.ToLower(); \
    if ($actual -ne $env:CHOCO_INSTALLER_SHA256.ToLower()) { \
        throw "Chocolatey install.ps1 SHA256 mismatch. Expected: $env:CHOCO_INSTALLER_SHA256 Actual: $actual"; \
    }; \
    & C:\choco.ps1; \
    Remove-Item C:\choco.ps1; \
    choco feature enable -n allowGlobalConfirmation

# ── Git ───────────────────────────────────────────────────────────────────────
# '/GitAndUnixToolsOnPath' adds git, curl, grep, sed, awk etc. to PATH
# Version pinned for supply-chain reproducibility (#72); bump deliberately.
ARG GIT_CHOCO_VERSION=2.54.0
RUN choco install git --version=$env:GIT_CHOCO_VERSION --params "'/GitAndUnixToolsOnPath /NoShellIntegration'"

# ── Python 3 ─────────────────────────────────────────────────────────────────
# python3 choco package installs to C:\PythonXYZ (ignores /InstallDir). Copying
# just python.exe to a shim dir breaks runtime because python.exe resolves its
# DLLs (python3XX.dll, stdlib) from its own directory. Instead, create a
# directory junction C:\Python -> C:\PythonXYZ so the entire install tree is
# accessible under a stable, version-independent path. Junctions don't require
# SeCreateSymbolicLinkPrivilege, unlike true symlinks.
# Version pinned for supply-chain reproducibility (#72); bump deliberately.
ARG PYTHON3_CHOCO_VERSION=3.14.4
RUN choco install python3 --version=$env:PYTHON3_CHOCO_VERSION -y; \
    $pyRoot = Get-ChildItem 'C:\' -Directory -Filter 'Python*' | Where-Object { $_.Name -match '^Python\d+$' } | Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName; \
    if (-not $pyRoot) { throw 'Python install dir not found under C:\' }; \
    Write-Host "Python installed at: $pyRoot"; \
    cmd /c mklink /J C:\Python $pyRoot; \
    if (-not (Test-Path 'C:\Python\python.exe')) { throw 'Junction creation failed' }; \
    Copy-Item -Path C:\Python\python.exe -Destination C:\Python\python3.exe; \
    [Environment]::SetEnvironmentVariable('PYTHON_ROOT', $pyRoot, 'Machine')

# ── Node.js LTS ───────────────────────────────────────────────────────────────
# Version pinned for supply-chain reproducibility (#72); bump deliberately.
ARG NODEJS_LTS_CHOCO_VERSION=24.15.0
RUN choco install nodejs-lts --version=$env:NODEJS_LTS_CHOCO_VERSION

# ── PORT: Install-AzureCli.ps1 ───────────────────────────────────────────────
# Upstream: images/windows/scripts/build/Install-AzureCli.ps1.
# Pinned via Chocolatey; bump deliberately alongside the upstream SHA pin.
ARG AZURE_CLI_CHOCO_VERSION=2.77.0
RUN choco install azure-cli --version=$env:AZURE_CLI_CHOCO_VERSION

# ── PORT: Install-GitHub-CLI.ps1 ─────────────────────────────────────────────
# Upstream: images/windows/scripts/build/Install-GitHub-CLI.ps1.
ARG GH_CLI_CHOCO_VERSION=2.76.2
RUN choco install gh --version=$env:GH_CLI_CHOCO_VERSION

# ── PORT: Install-KubernetesTools.ps1 (kubectl + helm) ───────────────────────
# Upstream: images/windows/scripts/build/Install-KubernetesTools.ps1.
# Minikube and kind are intentionally omitted — both need a hypervisor which
# is unavailable inside an ACI Windows container.
ARG KUBECTL_CHOCO_VERSION=1.34.1
ARG HELM_CHOCO_VERSION=3.19.0
RUN choco install kubernetes-cli --version=$env:KUBECTL_CHOCO_VERSION; \
    choco install kubernetes-helm --version=$env:HELM_CHOCO_VERSION

# ── PORT: Install-JavaTools.ps1 (Temurin JDK 17 LTS) ─────────────────────────
# Upstream installs Temurin 8/11/17/21 side-by-side via the image toolset.
# Inside a container we ship one LTS — the majority case — and point
# JAVA_HOME at it. Bump deliberately.
ARG TEMURIN17_CHOCO_VERSION=17.0.16
RUN choco install temurin17 --version=$env:TEMURIN17_CHOCO_VERSION; \
    $jdk = Get-ChildItem 'C:\Program Files\Eclipse Adoptium' -Directory | Where-Object { $_.Name -like 'jdk-17*' } | Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName; \
    if (-not $jdk) { throw 'Temurin 17 JDK not found after install' }; \
    [Environment]::SetEnvironmentVariable('JAVA_HOME', $jdk, 'Machine'); \
    [Environment]::SetEnvironmentVariable('JAVA_HOME_17_X64', $jdk, 'Machine')

# ── PORT: Install-AWSTools.ps1 (AWS CLI v2) ──────────────────────────────────
# Upstream: images/windows/scripts/build/Install-AWSTools.ps1.
ARG AWSCLI_CHOCO_VERSION=2.31.4
RUN choco install awscli --version=$env:AWSCLI_CHOCO_VERSION

# ── Legacy .NET SDKs 6, 7, 8, 9 ──────────────────────────────────────────────
# .NET 10 is already present from the base image at C:\Program Files\dotnet.
# Additional SDKs are installed into the same root so a single 'dotnet' binary
# resolves all installed versions (global.json / TargetFramework pinning works).
# .NET 6 & 7 are EOL but included so legacy projects can still build in CI.
# Microsoft does not publish a stable SHA256 for dotnet-install.ps1 (it is
# updated continuously). We pin to a SHA captured at a known point in time and
# verify before execution; when the upstream script changes, the build fails
# loudly and a human updates DOTNET_INSTALL_SHA256 after reviewing the diff.
# Consider mirroring a pinned copy to ACR (#24).
# SHA captured 2026-04-22 from https://dot.net/v1/dotnet-install.ps1
ARG DOTNET_INSTALL_SHA256=ce5330422f1d3e9b3d46462a24ef7105f660ec6c67ef3f5d4ae05b7259fb4234
RUN Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile C:\dotnet-install.ps1; \
    $actual = (Get-FileHash -Path C:\dotnet-install.ps1 -Algorithm SHA256).Hash.ToLower(); \
    if ($actual -ne $env:DOTNET_INSTALL_SHA256.ToLower()) { \
        throw "dotnet-install.ps1 SHA256 mismatch. Expected: $env:DOTNET_INSTALL_SHA256 Actual: $actual"; \
    }; \
    foreach ($channel in @('6.0', '7.0', '8.0', '9.0')) { \
        Write-Host "--- Installing .NET SDK channel $channel ---"; \
        & C:\dotnet-install.ps1 -Channel $channel -InstallDir 'C:\Program Files\dotnet' -Architecture x64; \
    }; \
    Remove-Item C:\dotnet-install.ps1

# Make all installed tools available to subsequent layers and the running container.
# Chocolatey shims (git, python, node, npm, pip …) live in C:\ProgramData\chocolatey\bin.
# DOTNET_ROOT and C:\Program Files\dotnet are already on PATH from the base image.
ENV PATH="C:\Program Files\dotnet;C:\Python;C:\Python\Scripts;C:\Program Files\nodejs;C:\Program Files\Git\cmd;C:\Program Files\Git\mingw64\bin;C:\Program Files\Git\usr\bin;C:\ProgramData\chocolatey\bin;C:\ProgramData\chocolatey\lib\nodejs-lts\tools;C:\Program Files\PowerShell\7;C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin;C:\Program Files\Amazon\AWSCLIV2;C:\Program Files\Kubernetes\helm;C:\Program Files\GitHub CLI;C:\Windows\System32\WindowsPowerShell\v1.0;${PATH}"

# ── Verify tools are on PATH AND actually runnable (fail build early if not) ─
# Logic lives in a separate script to avoid Docker line-continuation interacting
# badly with backtick-escaped characters (e.g. "`n") in multi-line RUN.
COPY verify-tools.ps1 C:/verify-tools.ps1
RUN powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\verify-tools.ps1

# ── GitHub Actions runner ─────────────────────────────────────────────────────
# Check https://github.com/actions/runner/releases for the latest version.
# NOTE: GitHub deprecates old runner versions aggressively — a deprecated runner
# will register, connect, then immediately exit with
# "Runner version vX.Y.Z is deprecated and cannot receive messages."
# Keep this bumped. build-images.yml runs weekly to refresh the image.
ARG RUNNER_VERSION=2.333.1
# SHA256 published by GitHub on the runner release page:
# https://github.com/actions/runner/releases/tag/v2.333.1
# When bumping RUNNER_VERSION, update this hash to match the new release (#24).
ARG RUNNER_SHA256=d0c4fcb91f8f0754d478db5d61db533bba14cad6c4676a9b93c0b7c2a3969aa0
WORKDIR C:/actions-runner

RUN Invoke-WebRequest \
        -Uri "https://github.com/actions/runner/releases/download/v${env:RUNNER_VERSION}/actions-runner-win-x64-${env:RUNNER_VERSION}.zip" \
        -OutFile C:\actions-runner\runner.zip; \
    $actual = (Get-FileHash -Path C:\actions-runner\runner.zip -Algorithm SHA256).Hash.ToLower(); \
    if ($actual -ne $env:RUNNER_SHA256.ToLower()) { \
        throw "actions-runner zip SHA256 mismatch. Expected: $env:RUNNER_SHA256 Actual: $actual"; \
    }; \
    Expand-Archive -Path C:\actions-runner\runner.zip -DestinationPath C:\actions-runner; \
    Remove-Item C:\actions-runner\runner.zip

COPY entrypoint.ps1 C:/actions-runner/entrypoint.ps1

ENTRYPOINT ["C:\\Program Files\\PowerShell\\7\\pwsh.exe", "-NonInteractive", "-File", "C:\\actions-runner\\entrypoint.ps1"]
