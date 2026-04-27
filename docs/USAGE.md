# Usage (for org consumers)

How repositories in the organisation target these runners from their workflows.

> **Audience:** workflow authors in repos **inside** the org that owns this runner infrastructure.
> **Not for:** deploying or operating the runners themselves — see [ARCHITECTURE.md](ARCHITECTURE.md) and [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## Picking a runner

| Label set | OS | Hosted on | Docker / WSL2 / Hyper-V |
|---|---|---|---|
| `[self-hosted, linux, aca]` | Linux (Ubuntu) | Azure Container Apps Job | ❌ |
| `[self-hosted, windows, aci]` | Windows Server Core 2022 | Azure Container Instances | ❌ |
| `[self-hosted, linux, vmss]` *(opt-in)* | Linux (Ubuntu 22.04, full VM) | Azure VM Scale Set | ✅ Docker (Moby + buildx + compose) |
| `[self-hosted, windows, vmss]` *(opt-in)* | Windows Server 2022 (full VM) | Azure VM Scale Set | ✅ Docker + WSL2 + Hyper-V |

Labels are matched **all together** — `runs-on` must include **every** label. Do not drop `self-hosted`.

The two `vmss` tiers are **opt-in** and only exist in your org if the operator has enabled them — see [Using VMSS tiers](#using-vmss-tiers) and [docs/ARCHITECTURE.md#vmss-tiers-opt-in](ARCHITECTURE.md#vmss-tiers-opt-in).

### Linux example

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux, aca]
    steps:
      - uses: actions/checkout@v6
      - run: ./build.sh
```

### Windows example

```yaml
jobs:
  build:
    runs-on: [self-hosted, windows, aci]
    steps:
      - uses: actions/checkout@v6
      - shell: pwsh
        run: dotnet build
```

### Multi-OS matrix

```yaml
jobs:
  test:
    strategy:
      matrix:
        include:
          - os: linux
            labels: [self-hosted, linux, aca]
          - os: windows
            labels: [self-hosted, windows, aci]
    runs-on: ${{ matrix.labels }}
    steps:
      - uses: actions/checkout@v6
      - run: echo "Running on ${{ matrix.os }}"
```

### VMSS example (Linux, Docker)

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux, vmss]
    steps:
      - uses: actions/checkout@v6
      - run: docker build -t myapp:ci .
      - run: docker compose -f test/docker-compose.yml up --exit-code-from tests
```

### VMSS example (Windows, WSL2)

```yaml
jobs:
  build:
    runs-on: [self-hosted, windows, vmss]
    steps:
      - uses: actions/checkout@v6
      - shell: pwsh
        run: |
          wsl --status
          wsl -d Ubuntu -- bash -lc 'uname -a && make test'
```

### When **not** to use these runners

- Workloads needing GPUs, more than a few vCPU, or large disks — use GitHub-hosted `ubuntu-latest` or dedicated hosts. (VMSS tiers use `Standard_D4ds_v5`: 4 vCPU / 16 GB RAM.)
- Jobs that need Docker-in-Docker, service containers (`services:`), or the job-level `container:` key on the **ACA / ACI tiers** — **not supported**. Use the `vmss-linux` / `vmss-windows` tiers, which expose a real Docker daemon.
- Anything public-facing / untrusted-PR builds — these runners have access to internal resources, and VMSS tiers additionally reuse warm VMs across jobs. The `job-completed` hook wipes the full `_work` tree (including `_actions` and `_tool`), `/tmp`, `/var/tmp`, per-user git/docker/cloud-CLI/package-manager credentials and caches, SSH `known_hosts`, shell history, and user-level rc/PATH appendages between jobs on a best-effort basis. The full allow-list is in [`scripts/vm-bootstrap/USAGE.md`](../scripts/vm-bootstrap/USAGE.md). Kernel state, container layers/volumes, installed system packages, and anything written with `sudo` outside `$HOME` still persist for the warm lifetime. Treat warm runners as **trusted-PR only**.

---

## Pre-installed tools

### Linux (`[self-hosted, linux, aca]`)

Base: [`ghcr.io/actions/actions-runner`](https://github.com/actions/runner/pkgs/container/actions-runner) (Ubuntu 22.04).

| Tool | Notes |
|---|---|
| PowerShell 7 | `pwsh` on PATH |
| Azure CLI | `az` — logs in via managed identity if `az login --identity` is used (see caveats below) |
| .NET SDK 8 (LTS) | `dotnet` — matches the `dotnet-sdk-8.0` channel on Windows |
| Node.js LTS | `node`, `npm` — NodeSource LTS, same major as Windows |
| Python 3 | `python3`, `pip3` |
| Git, curl, wget, jq | Standard |
| openssl, gnupg, ca-certificates | Standard |

Anything else — `apt-get install` in a step. Nothing persists between jobs.

### Windows (`[self-hosted, windows, aci]`)

Base: `mcr.microsoft.com/dotnet/sdk:10.0-windowsservercore-ltsc2022`. Package manager: **Chocolatey** (winget is **not** supported in Windows Server Core containers).

| Tool | Notes |
|---|---|
| .NET SDK | 6, 7, 8, 9, **10** (side-by-side in `C:\Program Files\dotnet`) |
| PowerShell 7 | `pwsh` on PATH (the built-in `powershell` 5.1 is also available but lacks `RSA.ImportFromPem()`) |
| Node.js LTS | `node`, `npm` |
| Python 3 | `python`, `pip` |
| Git | Includes Unix tools on PATH (`sed`, `grep`, etc.) |
| Chocolatey | `choco install ...` for anything else |

**Not available on Windows runners:**

- WSL (requires Hyper-V kernel features that ACI does not expose)
- Docker / containerisation
- GUI / RDP — this is a container, not a VM

---

## Behaviour to expect

### Ephemeral

Every job gets a **fresh container**. No state — filesystem, env vars, installed packages, caches on disk — survives from one job to the next.

- `actions/cache@v4` still works (cache lives in GitHub's cache backend, not on the runner).
- `actions/upload-artifact` / `download-artifact` still works.
- If a step writes to `/tmp` or `C:\temp` and another job needs it later — **use artifacts or cache**, not the filesystem.

### Timeouts

| Stage | Limit | Configured by |
|---|---|---|
| Linux job replica | **30 minutes** | `replicaTimeout: 1800` in `linux-runner.bicep` |
| Windows launcher (covers the whole Windows job) | **4 hours** | `replicaTimeout: 14400` in `windows-launcher.bicep` |
| GitHub Actions job | 6 hours (GitHub default) or `jobs.<id>.timeout-minutes` | Your workflow |

If your Linux job needs more than 30 minutes, ask the operator to raise the ACA `replicaTimeout` — it is a deliberate budget guard, not a hard limit.

### Concurrency

Each Bicep-deployed runner pool has a `maxExecutions` cap (default `10` for both Linux and Windows). KEDA polls GitHub every **30 seconds** (Linux) or **60 seconds** (Windows) to scale 0 → N.

What this means in practice:

- If 12 jobs are queued against 10-capacity Linux, the last 2 queue until a slot frees.
- Jobs may sit in "Waiting for a runner" for up to ~1 minute after queueing while the scaler polls — this is normal.
- If a job sits there for **several minutes**, something is wrong — see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

### Networking

- **Outbound:** unrestricted — runners reach `*.github.com`, `*.azure.com`, `packages.microsoft.com`, package registries, the public internet.
- **Inbound:** none. These runners are not addressable from outside Azure.

---

## Runner groups and access control

The runners register into the **org's default runner group** (unless the operator has moved them). Default group policy determines which repos can schedule jobs on them.

If your repo can't pick up jobs on `[self-hosted, linux, aca]`:

1. Check **Organisation settings -> Actions -> Runner groups** -> which repos the group allows.
2. Ask an org admin to add your repo (or move the runners to a different group).

See GitHub's docs on [managing access to self-hosted runners using groups](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/managing-access-to-self-hosted-runners-using-groups).

---

## Azure managed identity — caveats

The Linux runner container runs under a **user-assigned managed identity** that has **`AcrPull` on the runner ACR only**. It has **no** other Azure permissions.

The Windows launcher (and therefore the Windows runner ACI group) runs under a **separate** managed identity that has broader rights (AcrPull + `Container Instance Contributor` on the runner resource group + `Managed Identity Operator` on itself). This is what lets it create/delete ACI groups.

### Implications

- `az login --identity` **on a Linux runner** will succeed but give you an identity that can only pull images from the runner ACR. **Not useful for deploying workloads.**
- `az login --identity` **on a Windows runner** will give you the launcher identity, which **can** create and delete ACI container groups in the runner RG. **Do not rely on this for your workloads** — it's an implementation detail that may change without notice, and you'd be running in a privileged identity not intended for your app.
- **Preferred:** use OIDC workload identity federation from your own workflow to a service principal scoped to **your** resources. See [Azure login with OIDC](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect).

---

## Using VMSS tiers

The `[self-hosted, linux, vmss]` and `[self-hosted, windows, vmss]` tiers run on full Azure VMs baked by Azure Image Builder with the same tool set as GitHub-hosted `ubuntu-22.04` / `windows-2022` runners. Use them when you need **Docker, WSL2, Hyper-V, nested virtualisation, or kernel-level features** that the container-based `aca` / `aci` tiers cannot provide.

### How to enable (operator-only)

Disabled by default. An operator enables per-tier via either:

- **Bicep params** in `infra/main.bicepparam`:
  ```bicep
  param enableVmssLinux   = true
  param enableVmssWindows = true
  // Optional tuning:
  param vmssLinuxIdleRetentionMinutes   = 60   // sliding idle window (min); 0 = 1:1 ephemeral
  param vmssWindowsIdleRetentionMinutes = 60
  param vmssLinuxMaxLifetimeHours       = 12   // hard recycle cap (h); 0 = no cap
  param vmssWindowsMaxLifetimeHours     = 12
  param vmssLinuxMaxInstances           = 10
  param vmssWindowsMaxInstances         = 10
  param vmssVmSize                      = 'Standard_D4ds_v5'
  // Optional rollback pins (default 'latest' -> rotates to newest weekly bake):
  param vmssLinuxImageVersion           = 'latest'
  param vmssWindowsImageVersion         = 'latest'
  ```
- Or as `workflow_dispatch` inputs on `deploy.yml` for a one-off toggle without editing `.bicepparam`. **No additional inputs/secrets are required** — the VNet/subnet and NSG are provisioned by `main.bicep` itself, and the Linux admin SSH public key is auto-generated inline by the workflow run (private half discarded).

On first enablement the operator must also run `build-vhds.yml` at least once to bake the initial gallery version — VMSS cannot provision until there is an image to boot from. Subsequent bakes happen weekly (Sunday 22:00 UTC).

### What you get

Common scenarios that work on `vmss-*` but **not** on `aca` / `aci`:

- `docker build`, `docker run`, `docker compose up`, `docker buildx` with BuildKit
- Running containers alongside your job (`services:` in the workflow, or manual `docker run ... &`)
- Kernel-module-dependent tooling (e.g. `systemd-nspawn`, `cgroups v2` experiments)
- **Windows only:** `wsl --install`, running Linux toolchains inside WSL2, Hyper-V VMs, building Hyper-V VHDs, MSIX signing with hardware-backed keys
- Anything that expects the full `actions/runner-images` tool list (Xcode excluded — this is still Linux/Windows, not macOS)

### Cost model

Unlike the ACA / ACI tiers, VMSS VMs **stay online between jobs** for up to `idleRetentionMinutes` after the last job completes. While warm, you pay the full VM rate (`Standard_D4ds_v5` pay-as-you-go in the VMSS region — see the [Azure VM pricing page](https://azure.microsoft.com/en-us/pricing/details/virtual-machines/linux/) for current rates).

Trade-off:

| `idleRetentionMinutes` | Cost | Warm-hit rate |
|---|---|---|
| `0` | Lowest (identical to ephemeral) | 0% — every job is cold (~2-5 min startup) |
| `10-30` | Low | High for bursty pipelines; cold for sparse runs |
| `60` *(default)* | Moderate | Warm for most workday activity |
| `120+` | Higher | Warm across meetings/lunch |

Also bounded by `maxLifetimeHours` (default 12 h) — a hard recycle cap independent of idle time.

For strict scale-to-zero behaviour with no warm cost, set `idleRetentionMinutes = 0`; this reinstates `--ephemeral` registration and each VM is deleted as soon as its single job finishes.

### When to choose each tier

- Job doesn't need Docker, WSL2, Hyper-V, or kernel features → **`aca-linux`** or **`aci-windows`** (cheapest, fastest cold start).
- Linux job needs Docker, DinD, or `services:` → **`vmss-linux`**.
- Windows job needs Docker, WSL2, Hyper-V, MSI installs requiring reboot, or nested virt → **`vmss-windows`**.
- Bursty CI where cold start matters → enable VMSS and raise `idleRetentionMinutes` (warm hit rate is what buys you the low latency).
- Rare, one-off builds where cost matters more than cold start → `aca` / `aci` tiers, or `vmss` tiers with `idleRetentionMinutes = 0`.

See [docs/ARCHITECTURE.md#vmss-tiers-opt-in](ARCHITECTURE.md#vmss-tiers-opt-in) for the full architecture, diagrams, and lifecycle model.

---

## Image refresh cadence

- Runner images are rebuilt automatically every **Sunday 22:00 UTC** to pick up base-image and package updates. Check the [build-images workflow](../.github/workflows/build-images.yml).
- Images are tagged `YYYYMMDD-<sha7>` (code pushes) or `YYYYMMDD-HHmm` (scheduled / manual), plus the mutable `:stable` tag consumed by the runners.
- Need to pin to a specific image? Talk to the operator — this requires an infra change.

---

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for:

- "Waiting for a runner" that never moves
- Windows job starts but times out during registration
- Deprecated runner version warnings
- Jobs hitting the 30-minute Linux cap

If you're still stuck, open an issue on the runner repo (the one containing this `USAGE.md`) with the workflow run URL.
