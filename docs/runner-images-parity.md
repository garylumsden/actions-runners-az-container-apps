# Runner-images parity

This document describes how this repo stays aligned with the upstream
[actions/runner-images](https://github.com/actions/runner-images) project so
jobs running on self-hosted runners here see roughly the same toolbox they
would see on `ubuntu-22.04` / `windows-2022` in GitHub-hosted runners.

## SHA pin flow

Parity is pinned against a single upstream commit, tracked in
[`infra/runner-images-version.txt`](../infra/runner-images-version.txt):

```
bd758e8a199c411f081c3c5d78be527b9296332c
```

Every place that consumes the SHA does so through this file — nothing inside
the repo carries a separately-versioned copy. The rules are:

1. **Bump deliberately.** Update the SHA only as a discrete PR with a
   rationale (bug fix? new upstream tool? CVE?). Every bump must be reviewed
   by a human before merging.
2. **Fan-out.** The SHA is read by:
   - `infra/modules/aib-ubuntu.bicep` via `loadTextContent('../runner-images-version.txt')`
     for the AIB `vmssRunnerImagesCommit` parameter.
   - `infra/modules/aib-windows.bicep` via the same mechanism.
   - `docs/runner-images-parity.md` (this file) for the prose reference.
3. **Never inline.** Do **not** hard-code the SHA in bicep files or
   Dockerfiles. If a tool-pin truly needs a commit, pin it to its own upstream
   project's release, not to `actions/runner-images`.

## VMSS Ubuntu + Windows bakes

`infra/modules/aib-ubuntu.bicep` and `infra/modules/aib-windows.bicep` are
**standalone** Azure Image Builder (AIB) `imageTemplate` modules. They are
deliberately not wired into `main.bicep` — the default runner path in this
repo is ACA Jobs (Linux) + ACI (Windows). Use the AIB modules only when you
want a VM/VMSS image with near-full upstream parity.

### Ubuntu 22.04 (`aib-ubuntu.bicep`)

- Base: `Canonical / 0001-com-ubuntu-server-jammy / 22_04-lts-gen2 / latest`.
- Clones `actions/runner-images` at the pinned SHA to `/opt/runner-images`.
- **Re-enables `universe` pocket.** Azure's Ubuntu 22.04 Gen2 base image
  ships with only `main` + `restricted`. Many upstream `install-*.sh` scripts
  pull packages from `universe` (unzip, jq, zstd deps etc.) and fail fast
  without it. This step **must not** be removed.
- Iterates every `install-*.sh` in `images/ubuntu/scripts/build` in
  lexical order and runs it under `sudo -E bash` with the upstream env
  vars set:
  `HELPER_SCRIPTS`, `INSTALLER_SCRIPT_FOLDER`, `IMAGE_FOLDER`,
  `IMAGE_OS`, `IMAGE_VERSION`, `IMAGEDATA_FILE`, `METADATAFILE`,
  `AGENT_TOOLSDIRECTORY`, `DEBIAN_FRONTEND=noninteractive`.
- Pre-pulls the `actions/runner` binary to `/opt/actions-runner` so cold
  start on a fresh VM is not dominated by a ~75 MB download.
- `osDiskSizeGB` default 120; `buildTimeoutMinutes` default 240.

### Windows Server 2022 (`aib-windows.bicep`)

- Base: `MicrosoftWindowsServer / WindowsServer / 2022-datacenter-azure-edition / latest`.
- Clones `actions/runner-images` at the pinned SHA to `C:\runner-images`.
- Stages `helpers`, `assets`, and `toolset-2022.json` exactly where the
  upstream scripts expect them (`C:\imagegeneration\...`).
- Runs the upstream install scripts in **phases** that mirror the
  upstream `build.windows-2022.pkr.hcl` `windows-restart` boundaries:

  | Phase | Contents | Followed by |
  | ----- | -------- | ----------- |
  | 1 | base config (Defender, WindowsFeatures, Chocolatey, ImageData) | `WindowsRestart` (waits for Containers feature) |
  | 2 | Docker + DockerCompose + PowerShell Core | `WindowsRestart` (30m) |
  | 3 | Visual Studio + KubernetesTools (`validExitCodes: [0, 3010]`) | `WindowsRestart` (10m) |
  | 4 | Wix, WDK, VSExtensions, AzureCLI, AzureDevOpsCLI, ChocolateyPackages, JavaTools, Kotlin, OpenSSL | _(no restart)_ |
  | 5 | ServiceFabricSDK | `WindowsRestart` (10m) |
  | 6 | uninstall legacy Azure PowerShell | _(no restart)_ |
  | 7 | big install bundle (Ruby, PyPy, Toolset, NodeJS, Android SDK, PowerShell Az, Git, GH-CLI, PHP, Rust, Sbt, browsers + webdrivers, Apache, Nginx, Msys2, AWS, DACFx, MySQL, SQL, dotnet SDK, MinGW, Haskell, Stack, Miniconda, CosmosDB emulator, Mercurial, zstd, NSIS, vcpkg, PostgreSQL, Bazel, Aliyun, RootCA, MongoDB, CodeQL, diagnostics) | _(no restart)_ |
  | 8 | Windows Updates + configure (DynamicPort, GDIQuota, Shell, DeveloperMode, LLVM) | `WindowsRestart` (30m) |
  | 9 | post-reboot Windows updates + cleanup | _(no restart)_ |
  | 10 | NativeImages + Configure-System + Post-Build-Validation | `WindowsRestart` (10m) |
  | — | AIB sysprep handles the final generalize phase |

  Getting these boundaries right matters: several install scripts depend on
  features installed in the previous phase being registered _after_ a reboot
  (notably the Containers feature that `Install-Docker.ps1` needs, and the
  Visual Studio instance that the subsequent extension installers require).
- `osDiskSizeGB` default 250; `buildTimeoutMinutes` default 360.

Neither AIB module is referenced from `main.bicep`. To deploy one, author a
thin orchestrator template (or `az deployment group create` directly against
the module) and supply `aibIdentityId` and `galleryImageId`.

## Windows container parity (`docker/windows-runner/Dockerfile`)

The Windows ACI runner uses a Chocolatey-based container image rather than a
full AIB bake, because ACA does not support Windows containers and ACI can
only pull an image — it cannot run a VMSS bake. The container image
therefore only ports the **subset** of upstream tools that are viable in
Windows Server Core containers without a reboot.

Classification per upstream `build.windows-2022.pkr.hcl` install script:

| Upstream script | Status | Reason |
| --- | --- | --- |
| `Install-Chocolatey.ps1`          | **PORTED** | bootstrapped directly in Dockerfile with SHA-pinned `install.ps1` |
| `Install-PowershellCore.ps1`      | **PORTED** | PowerShell 7 MSI installed with SHA256 verification |
| `Install-Git.ps1`                 | **PORTED** | `choco install git` with Unix tools on PATH |
| `Install-NodeJS.ps1`              | **PORTED** | `choco install nodejs-lts` |
| `Install-DotnetSDK.ps1`           | **PORTED** | .NET 10 from base image; 6, 7, 8, 9 added side-by-side via `dotnet-install.ps1` |
| `Install-AzureCli.ps1`            | **PORTED** | via Chocolatey |
| `Install-GitHub-CLI.ps1`          | **PORTED** | via Chocolatey |
| `Install-KubernetesTools.ps1`     | **PORTED** | `kubectl` + `helm` + `kubernetes-cli` via Chocolatey |
| `Install-JavaTools.ps1`           | **PORTED** | Temurin JDK 17 LTS via Chocolatey |
| `Install-AWSTools.ps1`            | **PORTED** | `awscli` via Chocolatey |
| `Install-Ruby.ps1`                | _(upstream-only)_ | language runtime not yet required by our workloads |
| `Install-PyPy.ps1`                | _(upstream-only)_ | alternative Python runtime not yet required |
| `Install-Rust.ps1`                | _(upstream-only)_ | can be added on demand |
| `Install-Docker.ps1` / `Install-DockerCompose.ps1` / `Install-DockerWinCred.ps1` | **SKIPPED** | Docker Engine requires the Containers Windows feature + kernel restart, which is unavailable inside an ACI container. |
| `Install-VisualStudio.ps1` / `Install-VSExtensions.ps1` / `Install-Wix.ps1` / `Install-WDK.ps1` | **SKIPPED** | Visual Studio requires interactive installer components and GUI subsystems not present in Server Core. |
| `Install-Msys2.ps1`               | **SKIPPED** | requires UWP infrastructure and ~5 GB of state; out of scope for a container |
| `Install-AzureCosmosDbEmulator.ps1` | **SKIPPED** | emulator requires services disabled on Server Core |
| `Install-MongoDB.ps1` / `Install-PostgreSQL.ps1` / `Install-SQLPowerShellTools.ps1` / `Install-MysqlCli.ps1` | **SKIPPED** | server database workloads belong in sidecar containers or service-hosted DBs, not baked into the runner |
| `Install-Chrome.ps1` / `Install-Firefox.ps1` / `Install-EdgeDriver.ps1` / `Install-IEWebDriver.ps1` / `Install-Selenium.ps1` / `Install-WinAppDriver.ps1` | **SKIPPED** | browser E2E tests require a full desktop session; use a hosted browser service or a Linux runner |
| `Install-WindowsUpdates*.ps1` | **SKIPPED** | the container base image is patched by Microsoft's monthly tag refresh, not by in-container updates |
| `Install-NativeImages.ps1` | **SKIPPED** | native-image generation only helps persistent VMs |
| `Configure-WindowsDefender.ps1` / `Configure-PowerShell.ps1` / `Configure-BaseImage.ps1` / `Configure-DeveloperMode.ps1` etc. | **SKIPPED** | either not applicable to Server Core, or inherited from the base image configuration |
| `Install-Toolset.ps1` / `Configure-Toolset.ps1` | **partial** | we install the pinned-version subset we actually use (Python, Node) directly via Chocolatey instead of running the upstream toolset installer, which expects a pristine bake VM |
| `Install-WinAppDriver.ps1`, `Install-TortoiseSvn.ps1`, `Install-Mercurial.ps1`, `Install-ServiceFabricSDK.ps1` | **SKIPPED** | niche or legacy; not required by current workloads |

### Container limitations baked into the Dockerfile

- **No WSL.** WSL requires Hyper-V kernel features unavailable in ACI Windows
  containers. Use the Linux runner for WSL / bash workloads.
- **No `winget`.** `winget` depends on UWP App Installer services that are
  absent from Server Core. Chocolatey is used throughout.
- **No Docker in Docker.** See above — the Containers feature cannot be
  enabled inside an ACI container.
- **No GUI.** Browser tests, UWP tests, and anything that needs an
  interactive session will not work.

When a workload needs something in the SKIPPED list, the correct response is
usually to either (a) run it on the Linux ACA runner, or (b) stand up a
small purpose-built VMSS bake via the `aib-windows.bicep` standalone module.

## Keeping parity fresh

- `build-images.yml` runs weekly (Sunday 22:00 UTC) and rebuilds the two
  runner container images on top of the current base OS tags, preserving
  the pinned tool versions in the Dockerfile.
- The upstream SHA pin in `infra/runner-images-version.txt` is updated by
  hand after reviewing upstream release notes. Dependabot does not manage it.
- Tool-version choco pins in the Dockerfile (`GIT_CHOCO_VERSION`,
  `PYTHON3_CHOCO_VERSION`, `NODEJS_LTS_CHOCO_VERSION`, the PORT tool
  versions listed below) and the runner release pin (`RUNNER_VERSION`) are
  bumped deliberately, with the corresponding SHA256 refreshed at the same
  time.
