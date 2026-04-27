# Upgrading

How to bump base images, GitHub Actions, .NET SDKs, and Bicep API versions -- plus how to roll back when a new image breaks.

## General principles

- **Pin by digest or tag, never float on `:latest`.** Runner images are published as `YYYYMMDD-<sha7>` (on code pushes) or `YYYYMMDD-HHmm` (on scheduled/manual runs), plus the mutable `stable` pointer; bare `YYYYMMDD` is not pushed / `YYYYMMDD-<sha7>`, and a mutable `stable` pointer. ACA jobs pull `:stable`. Roll forward/back by moving `:stable`.
- **Bump base images weekly.** `build-images.yml` is scheduled for Sunday 22:00 UTC. Manual runs work too.
- **One concern per PR.** Don't bundle a base-image bump with workflow changes.
- **Dependabot is on** for GitHub Actions and Docker images (see `.github/dependabot.yml`). Prefer merging its PRs rather than hand-editing versions.

## Bump the Linux runner base image

1. Check new release: [`ghcr.io/actions/actions-runner`](https://github.com/actions/runner/pkgs/container/actions-runner).
2. Edit `docker/linux/Dockerfile` -- update the `FROM ghcr.io/actions/actions-runner:<tag>` line.
3. Open PR -> merge -> `build-images.yml` builds + tags + moves `:stable`.
4. Next queued job picks up the new image automatically.

## Bump the Windows runner base image

1. Check new [`mcr.microsoft.com/dotnet/sdk`](https://mcr.microsoft.com/en-us/product/dotnet/sdk/tags) Windows Server Core LTSC 2022 tag.
2. Edit `docker/windows-runner/Dockerfile` -- update `FROM mcr.microsoft.com/dotnet/sdk:<ver>-windowsservercore-ltsc2022`.
3. If the base's preinstalled .NET version changes, update the side-by-side SDK list below accordingly.
4. Open PR -> merge -> `build-images.yml` runs `az acr build --platform windows`.

> Windows base image bumps take longer than Linux in ACR -- expect 10--20 min queue + build.

## Bump the Windows launcher image

The launcher is a lightweight Linux ACA Job. Edit `docker/windows-launcher/Dockerfile`, merge, done. It uses `az container create` via managed identity -- the Azure CLI version in the base matters.

## Bump .NET SDKs on the Windows runner

`docker/windows-runner/Dockerfile` installs .NET 6, 7, 8, 9 side-by-side via [`dotnet-install.ps1`](https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-install-script), on top of the base image's preinstalled SDK (currently .NET 10).

- To add an SDK (e.g. .NET 11 preview): add a new `RUN powershell ... -Channel 11.0 ...` step.
- To drop an SDK: remove its `RUN` block.
- To bump patch version: `dotnet-install.ps1` with a `-Channel 8.0` always pulls the latest 8.0.x, so a rebuild is enough -- no Dockerfile change needed.

Never remove the base image's preinstalled SDK (.NET 10) -- it ships with the image.

## Bump GitHub Actions versions

Workflows in `.github/workflows/` pin third-party actions. Current pinned versions:

| Action | Purpose |
|---|---|
| [`actions/checkout@v6`](https://github.com/actions/checkout) | Clone the repo |
| [`azure/login@v3`](https://github.com/Azure/login) | OIDC federated login to Azure |

Both are required to be Node.js 24 compatible. Dependabot opens bump PRs; review and merge.

## Bump Bicep API versions

1. Check Microsoft Learn for the latest [resource reference](https://learn.microsoft.com/en-us/azure/templates/) page for the resource type.
2. Edit the relevant module under `infra/modules/`.
3. Run `az bicep build --file infra/main.bicep` locally -- verify only expected BCP081 warnings.
4. Run `az deployment group what-if` with real parameters to confirm the change is a no-op semantically.
5. Open PR.

> Preview API versions are allowed. BCP081 warnings are expected and do not block deployment.

## Rollback: revert `:stable` to a known-good tag

If a newly built image breaks runners, retag `:stable` to an older dated tag. No Bicep change, no redeploy.

```powershell
$acr = (az acr list --resource-group $env:RESOURCE_GROUP --query "[0].name" -o tsv)
$repo = "github-runner-linux"     # or github-runner-windows, github-runner-windows-launcher
$goodTag = "20260415"              # pick from: az acr repository show-tags ...

az acr repository show-tags --name $acr --repository $repo --orderby time_desc --top 10 -o tsv

# Move :stable to the known-good tag
az acr import `
  --name $acr `
  --source "$acr.azurecr.io/${repo}:${goodTag}" `
  --image "${repo}:stable" `
  --force
```

The next scheduled/queued runner pulls the old image. For ACI Windows runners, any in-flight container groups keep running their old image; only new groups pick up the change.

To roll back a Bicep change: revert the merge commit on `main`, push. `deploy.yml` re-applies the prior template.

## Related

- [Architecture](ARCHITECTURE.md) -- components, auth flows, naming.
- [`scripts/setup-oidc.ps1`](../scripts/setup-oidc.ps1) -- OIDC federated credentials.
- [`scripts/setup-github-app.ps1`](../scripts/setup-github-app.ps1) -- GitHub App registration.
