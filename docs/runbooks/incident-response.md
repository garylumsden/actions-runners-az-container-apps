# Runbook: Incident response

**Applies to:** security incidents affecting the `actions-runners-az-container-apps` runner
infrastructure — the GitHub App PEM, the managed identity, the container
images in ACR, or the workflows that deploy them.

**Goal:** contain the incident, evict the attacker, restore a known-good
state, and document what happened.

**Golden rules**

1. **Contain first, investigate second.** Revoke credentials before you dig
   into logs.
2. **Prefer recreate over clean.** Ephemeral compute (ACA Jobs, ACI groups)
   is cheap to rebuild. If in doubt, blow it away.
3. **Treat any PAT / PEM / token as burned** the moment it is suspected to
   have leaked. Rotate, don't "monitor."
4. **Preserve evidence.** Export relevant Log Analytics query results and
   Activity Log entries before tearing resources down.
5. **Notify.** Tell the repo owner and the GitHub org owner. If a customer
   tenant is affected, follow your organisation's disclosure process.

---

## Scenario A — GitHub App PEM leaked or suspected leaked

**Indicators:** PEM found in a public repo / log / chat; unexpected
`installation/access_tokens` requests in GitHub audit log; runner
registrations from IPs not owned by Azure.

1. **Revoke immediately.**
   - GitHub org -> **Settings** -> **Developer settings** -> **GitHub Apps** ->
     the app -> **Private keys** -> **Delete** every existing key.
   - This invalidates all JWTs minted from the old PEM. Active ephemeral
     runners will finish their current job and fail to register new ones —
     that is expected and safe.
2. **Rotate** by following
   [rotate-github-app-pem.md](rotate-github-app-pem.md) from step 1. You will
   generate a new PEM, redeploy, and verify.
3. **Audit**:
   - GitHub org -> **Settings** -> **Audit log** — filter by
     `action:integration_installation` and the app name for the last 30 days.
     Look for `installation.authorize` / `installation.token` events from
     unexpected IPs.
   - In Azure: `ContainerAppConsoleLogs_CL` for any `Runner successfully
     added` events whose `hostname` does not match the `runner-<ts>-<rand>`
     pattern emitted by our entrypoint scripts.
4. **Scope the blast radius.** The app only has the permissions configured
   for it (runner registration tokens). Confirm no additional permissions
   were added by an attacker — GitHub will show a changelog on the app page.

## Scenario B — Managed identity / OIDC token suspected exfiltrated

**Indicators:** unexpected role assignments in the resource group; Azure
Activity Log entries for actions not performed by a known team member;
`Sign-in logs` in Entra for the workload identity from an unexpected
location.

1. **Sever the identity's privileges first.**

   ```powershell
   # Find role assignments held by the runner managed identity
   $mi = az identity show ``
     --resource-group $env:RESOURCE_GROUP ``
     --name "id-<namingPrefix>-gh-runners-<locAbbr>" ``
     --query principalId -o tsv

   az role assignment list --assignee $mi -o table

   # Remove each role assignment (example: Contributor on the RG).
   # Resolve the subscription directly so this does not depend on an env
   # var that setup-oidc.ps1 may or may not have exported.
   $sub = az account show --query id -o tsv
   az role assignment delete --assignee $mi --role Contributor ```r
     --scope "/subscriptions/$sub/resourceGroups/$env:RESOURCE_GROUP"
   ```

2. **Recreate the identity.** Because it is defined in Bicep, the simplest
   safe path is to delete it in the portal / CLI and redeploy:

   ```powershell
   az identity delete --resource-group $env:RESOURCE_GROUP ``
     --name "id-<namingPrefix>-gh-runners-<locAbbr>"

   gh workflow run deploy.yml --ref main
   gh run watch
   ```

   The new identity has a new `principalId`; any stolen token is now bound to
   a principal that no longer exists.

3. **Investigate.**
   - Entra ID -> **Sign-in logs** -> filter `Service principal sign-ins` for
     the managed identity's app ID. Look for sign-ins from non-Azure IP
     ranges.
   - Azure portal -> resource group -> **Activity log** -> filter by the
     identity's object ID for the past 7 days. Export the result as CSV and
     attach it to the incident ticket.
   - Check for resources created / modified outside the expected set
     (anything other than ephemeral `aci-win-runner-*` groups created by the
     Windows launcher is suspicious).

4. **Rotate the OIDC deployment SP too** if the incident suggests its token
   was exposed. Follow
   [Configure an app to trust a GitHub repo](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust)
   to delete and recreate the federated credential.

## Scenario C — Compromised runner image in ACR

**Indicators:** unexpected digest on `:stable`; image pushed outside a
`build-images.yml` run; `az acr task` history shows an unknown actor; runner
behaviour deviates (unexpected network egress, unknown processes).

1. **Freeze the image.** Disable the build workflow so no new pushes happen
   while you investigate:

   ```powershell
   gh workflow disable build-images.yml
   ```

2. **Identify the last known-good digest.** List tags and manifests:

   ```powershell
   az acr repository show-manifests ``
     --name $env:ACR_NAME ``
     --repository github-runner-linux ``
     --orderby time_desc -o table
   ```

   Pick the most recent dated tag (`YYYYMMDD-<sha7>`) that was produced by
   a legitimate `build-images.yml` run (cross-check against `gh run list
   --workflow build-images.yml`).

3. **Repin `:stable` to the known-good digest.** Use `az acr import` against
   the same registry to create a new `:stable` tag pointing at the trusted
   manifest:

   ```powershell
   $good = "github-runner-linux@sha256:<digest-of-known-good>"

   az acr import ``
     --name $env:ACR_NAME ``
     --source "$($env:ACR_NAME).azurecr.io/$good" ``
     --image "github-runner-linux:stable" ``
     --force
   ```

   Repeat for `github-runner-windows` if that image is also suspect.

4. **Purge the malicious tag(s).**

   ```powershell
   az acr repository delete ``
     --name $env:ACR_NAME ``
     --image "github-runner-linux:<bad-tag>" --yes
   ```

5. **Force ACA to pick up the repinned image.** Container Apps Jobs pull on
   each execution, so the next KEDA-triggered run will use the new `:stable`
   digest. To drain any in-flight runners:

   ```powershell
   az containerapp job execution list ``
     --resource-group $env:RESOURCE_GROUP ``
     --name "caj-linux-<namingPrefix>-gh-runners-<locAbbr>" ``
     --query "[?properties.status=='Running'].name" -o tsv |
     ForEach-Object {
       az containerapp job stop ``
         --resource-group $env:RESOURCE_GROUP ``
         --name "caj-linux-<namingPrefix>-gh-runners-<locAbbr>" ``
         --job-execution-name $_
     }
   ```

6. **Investigate the push.** `az acr task list-runs` and the ACR
   `Administrator activity log` show who pushed the bad tag and from which
   principal. If a GitHub Actions principal was abused, proceed to
   Scenario D.

7. **Re-enable builds** only after the image story is clean:

   ```powershell
   gh workflow enable build-images.yml
   ```

## Scenario D — Rogue workflow run / compromised Actions principal

**Indicators:** a workflow run you do not recognise; `deploy.yml` triggered
by an unexpected actor; a PR from outside the org that somehow ran against
`environment: production`.

1. **Cancel the run and disable the workflow.**

   ```powershell
   gh run list --limit 20
   gh run cancel <run-id>
   gh workflow disable deploy.yml
   gh workflow disable build-images.yml
   ```

2. **Protect the environment.** GitHub repo -> **Settings** ->
   **Environments** -> `production` -> verify required reviewers are set and
   the branch is restricted to `main`. If these were weakened, restore them.

3. **Revoke the OIDC trust temporarily.** In Entra:
   - App registration -> **Federated credentials** -> delete the affected
     credentials. `deploy.yml` and `build-images.yml` will fail until you
     recreate them — that is the point.

4. **Rotate both the PEM (Scenario A) and the managed identity (Scenario B)**
   if the rogue run reached the point of minting tokens or pulling secrets.

5. **Re-create the OIDC credentials and re-enable the workflows.**

   ```powershell
   .\scripts\setup-oidc.ps1
   gh workflow enable deploy.yml
   gh workflow enable build-images.yml
   ```

6. **Post-mortem the trigger.** Look at the PR, branch, or schedule that
   launched the rogue run. Tighten `on:` triggers and environment protection
   rules accordingly.

---

## Post-incident

- File a GitHub Security Advisory (private) against this repo describing
  what happened, what was rotated, and when. Reference all related audit log
  exports.
- Open a follow-up issue to address any preventive action (stricter branch
  protection, additional KEDA filters, image-signing, etc.).
- Update `SECURITY.md` if the incident revealed a new in-scope or
  out-of-scope area.

## References

- [GitHub security hardening for self-hosted runners](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#hardening-for-self-hosted-runners)
- [Managing private keys for GitHub Apps](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/managing-private-keys-for-github-apps)
- [Azure Container Registry - content trust and image purge](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-content-trust)
- [Azure Managed Identity - security best practices](https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/managed-identity-best-practice-recommendations)
