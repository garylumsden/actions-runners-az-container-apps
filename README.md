# actions-runners-az-container-apps

<!-- MIRROR_VERSION_INFO_START -->
> **Version:** `1.0.0` &middot; **Last published:** 2026-04-27 08:48 UTC &middot; **Source commit:** `34a8c96`
<!-- MIRROR_VERSION_INFO_END -->

Event-driven, ephemeral[GitHub Actions self-hosted runners](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners) on [Azure Container Apps Jobs](https://learn.microsoft.com/en-us/azure/container-apps/jobs) (Linux) and [Azure Container Instances](https://learn.microsoft.com/en-us/azure/container-instances/container-instances-overview) (Windows), managed with [Bicep](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/overview). Scaled by the [KEDA `github-runner` scaler](https://keda.sh/docs/latest/scalers/github-runner/).

- **Runner -> GitHub auth** uses a [GitHub App JWT](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app) — no PATs.
- **GitHub Actions -> Azure auth** uses [OIDC workload identity federation](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation) — no client secrets.
- **Runner -> Azure auth** uses a [user-assigned managed identity](https://learn.microsoft.com/en-us/azure/active-directory/managed-identities-azure-resources/overview).
- **Scale to zero** — no idle cost; runners only exist while jobs are queued or running.
- **Dual scope** — use with a GitHub **organisation** (recommended) or a **personal account** scoped to a single repository.

> This is a **generated, sanitised snapshot** of a private upstream repository. It is published as open-source reference material so you can fork and deploy your own runners. Active workflows are shipped in `.github/workflows-disabled/` so the mirror does not attempt to deploy anyone's infrastructure on clone.

## What you get

| Component | What it is |
|---|---|
| `infra/` | Bicep modules: ACR, Log Analytics, managed identity, Container Apps Environment, Linux runner ACA Job, Windows launcher ACA Job, Private DNS for ACR (optional). |
| `docker/linux/` | Linux runner image — ephemeral, minimal (pwsh, `az`, git, jq, curl, openssl). |
| `docker/windows-runner/` | Windows Server Core + .NET 6/7/8/9/10 SDKs + PowerShell 7 + Git + Node LTS + Python 3 + Chocolatey. |
| `docker/windows-launcher/` | Linux-based ACA Job that creates ephemeral Windows ACI container groups on demand (ACA doesn't support Windows containers). |
| `scripts/setup-oidc.ps1` | Creates the Azure AD app, grants RG role assignments, sets federated credentials and `AZURE_*` variables. Supports both org and repo scope. |
| `scripts/setup-github-app.ps1` | Guides you through creating a GitHub App, publishes the App ID, installation ID and base64 PEM as variables/secret. Supports both org and repo scope. |

## Why use this

Compared to GitHub-hosted runners you get:

- **Your private networking** — runners run inside your Azure subscription and can reach your VNet, Key Vault, internal APIs.
- **Larger machines / custom images** — scale ACA replicas up or layer tools into the Docker image.
- **Per-second billing with scale-to-zero** — no fixed monthly charge, no idle VMs.
- **Full Linux and Windows support** — Windows is delivered via ACI because ACA only supports Linux today.

Compared to always-on self-hosted VMs you get:

- **No patch / update treadmill** — each job runs in a fresh container.
- **Automatic weekly rebuild** of the base image (Sunday 22:00 UTC), so new runner releases roll in without intervention.
- **Fewer `Waiting for a runner…` minutes** — KEDA polls GitHub every 30s (Linux) / 60s (Windows) and scales the pool to match queue depth.

## Scope — org or repo?

This project supports **both** runner scopes. Pick whichever matches your GitHub account:

| Feature | `runnerScope = 'org'` | `runnerScope = 'repo'` |
|---|---|---|
| Who can use it | GitHub **Organisations** only | **Personal accounts** or single-repo org isolation |
| Who can target the runners | Every repository in the org | The specific repo you configure |
| Runner groups | Supported (GitHub feature) | Not applicable |
| GitHub App install target | The organisation | A single repository |
| GitHub App permissions required | Organisation: Actions (R), Self-hosted runners (R/W), Administration (R/W) | Repository: Administration (R/W), Actions (R), Metadata (R) |
| Setup script flag | `-Scope org` (default) | `-Scope repo -GitHubRepo myrepo` |
| Variables set by `setup-oidc.ps1` | Org variables (`--org`) | Repo variables (`--repo <owner>/<name>`) |

Both scopes use identical runtime — same Bicep, same images, same KEDA scaler. The scaler's `runnerScope` metadata field toggles between the two modes.

See [docs/SCOPES.md](docs/SCOPES.md) for full details.

## Quick start

1. **Fork or clone** this repository.
2. **Create an Azure resource group** in your preferred region.
3. **Copy** `infra/main.bicepparam.example` to `infra/main.bicepparam` and fill in your values (namingPrefix, githubOwner, runnerScope, location, locationAbbreviation).
4. **Run the setup scripts** (requires `az`, `gh`, `pwsh`):

   ```pwsh
   # Org scope (GitHub organisations)
   ./scripts/setup-oidc.ps1 -NamingPrefix 'yourprefix' -GitHubOwner 'your-org' -Scope org
   ./scripts/setup-github-app.ps1 -GitHubOwner 'your-org' -Scope org

   # Repo scope (personal accounts or single-repo isolation)
   ./scripts/setup-oidc.ps1 -NamingPrefix 'yourprefix' -GitHubOwner 'your-user' -Scope repo -GitHubRepo 'your-repo'
   ./scripts/setup-github-app.ps1 -GitHubOwner 'your-user' -Scope repo -GitHubRepo 'your-repo'
   ```

5. **Enable the workflows** you want: move files from `.github/workflows-disabled/` to `.github/workflows/`.
6. **Run `deploy.yml`** (or `az deployment group create` locally) to provision the infrastructure.
7. **Run `build-images.yml`** to push the first `:stable` runner images.

### Targeting the runners from a workflow

```yaml
jobs:
  linux-job:
    runs-on: [self-hosted, linux, aca]
    steps:
      - run: echo "Running on an ACA Linux runner"

  windows-job:
    runs-on: [self-hosted, windows, aci]
    steps:
      - run: Write-Host "Running on an ACI Windows runner"
```

See `docs/USAGE.md` for the full pre-installed-tools list, timeouts, and what's **not** supported (docker-in-docker, service containers, WSL, inbound networking).

## Further reading

- `docs/USAGE.md` — how workflows target the runners, pre-installed tools, limits, runner groups.
- `docs/SCOPES.md` — org vs repo scope, permissions, trade-offs.
- `docs/ARCHITECTURE.md` — components, auth flows, Bicep layout, build commands, Mermaid diagram.
- `docs/TROUBLESHOOTING.md` — stuck jobs, identity errors, ACI quota, Log Analytics KQL queries.
- `docs/upgrading.md` — base image bumps, GitHub Actions and .NET SDK upgrades, rollback.
- `docs/runbooks/` — incident response, PEM rotation.

## License

[MIT](LICENSE).

## Contributing

This repository is a **generated mirror**. Pull requests opened against the mirror cannot be merged; the mirror is rewritten by an automated publisher.

Open issues or PRs against the upstream source repository that generates this mirror, or fork this mirror and maintain your own copy.
