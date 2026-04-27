# Setup

End-to-end first-time setup for `actions-runners-az-container-apps`. Run each step in order. Every script is idempotent and safe to re-run.

## Prerequisites

- PowerShell 7 (`pwsh`)
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) (`az login`)
- [GitHub CLI](https://cli.github.com/) (`gh auth login`) — authenticated as an org owner (for org-scope secrets/variables) or a repo admin
- `ssh-keygen` on PATH (only if you plan to enable the `vmss-linux` tier)
- A resource group you control (created automatically by `setup-oidc.ps1`)

## 1 — OIDC setup (`setup-oidc.ps1`)

Creates the Azure AD app registration, grants it `Owner` on the resource group (needed so Bicep can create role assignments), creates federated credentials for `main` pushes and the `production` environment, and writes the five Azure Actions Variables.

```powershell
az login
./scripts/setup-oidc.ps1 -NamingPrefix 'myprefix' -GitHubOrg 'my-org'
```

Variables written: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `RESOURCE_GROUP`, `AZURE_LOCATION`.

## 2 — GitHub App setup (`setup-github-app.ps1`)

Creates (or reuses) a GitHub App for runner auth and stores its credentials.

```powershell
./scripts/setup-github-app.ps1
```

**Required App permissions (Organisation):** Self-hosted runners — Read & write, Administration — Read & write.

Variables written: `GH_APP_ID`, `GH_INSTALLATION_ID`. Secret written: `GH_APP_PEM_B64`.

## 3 — Deploy

Push to `main`, or run `deploy.yml` manually. If you want to enable the **VMSS tiers** (`vmss-linux` / `vmss-windows` — real Docker / WSL2 / Hyper-V), toggle the `enableVmssLinux` / `enableVmssWindows` workflow inputs. There is **no separate VMSS setup step**:

- The VMSS tiers are **fully self-contained**. `main.bicep` provisions its own VNet, subnet, NAT Gateway, and NSG (`infra/modules/vmss-network.bicep`).
- The Linux admin SSH keypair is **auto-generated inline by `deploy.yml`** per run; the private half is discarded immediately, the public half is injected into `vmssLinuxAdminSshPublicKey` and masked in logs. Break-glass SSH access is therefore not available by default — reset the key by re-running `deploy.yml`.
- `VMSS_WINDOWS_ADMIN_PASSWORD` is still optional if you want the Windows canary VM in `build-vhds.yml` to use a known password; if unset, the canary generates a random throwaway password per run.

On first enablement the operator must run `build-vhds.yml` at least once (manually, or wait for the Sunday 22:00 UTC schedule) to bake the initial gallery image — VMSS cannot boot without it.

## Full variable and secret reference

| Name | Type | Set by | Notes |
|---|---|---|---|
| `AZURE_CLIENT_ID` | Variable | `setup-oidc.ps1` | |
| `AZURE_TENANT_ID` | Variable | `setup-oidc.ps1` | |
| `AZURE_SUBSCRIPTION_ID` | Variable | `setup-oidc.ps1` | |
| `RESOURCE_GROUP` | Variable | `setup-oidc.ps1` | |
| `AZURE_LOCATION` | Variable | `setup-oidc.ps1` | |
| `GH_APP_ID` | Variable | `setup-github-app.ps1` | |
| `GH_INSTALLATION_ID` | Variable | `setup-github-app.ps1` | |
| `GH_APP_PEM_B64` | **Secret** | `setup-github-app.ps1` | Base64 of the App private key PEM |
| `VMSS_WINDOWS_ADMIN_PASSWORD` | **Secret** | Operator (optional) | Only consumed by `build-vhds.yml` when creating the Windows canary VM. If unset, a random throwaway password is generated per run. |

`ACR_NAME` is **not** stored. `build-images.yml` discovers it dynamically via `az acr list`.

No `AZURE_CLIENT_SECRET` — Azure auth is OIDC throughout.
