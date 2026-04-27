# Scopes — organisation vs repository

This project supports two **runner scopes**. The scope controls **where** your runners register with GitHub, **who** can target them, and **which** permissions the GitHub App needs.

| Property | `runnerScope = 'org'` | `runnerScope = 'repo'` |
|---|---|---|
| Who can use it | GitHub **Organisations** only | **Personal accounts**, or an org that wants single-repo isolation |
| Who can target the runners | Every repository in the org (subject to runner group policy) | The one repository you configure |
| Runner groups | Supported — GitHub feature, lets you restrict which repos or workflows can use a runner | Not applicable |
| GitHub App install target | The organisation | A single repository |
| Setup script scope flag | `-Scope org` (default) | `-Scope repo -GitHubRepo <name>` |
| GitHub CLI variable target | `gh variable set --org <owner> --visibility all` | `gh variable set --repo <owner>/<repo>` |
| KEDA scaler `runnerScope` metadata | `org` | `repo` (plus `repos: <name>`) |
| Registration API endpoint | `POST /orgs/{owner}/actions/runners/registration-token` | `POST /repos/{owner}/{repo}/actions/runners/registration-token` |
| Register-to URL (runner `--url` flag) | `https://github.com/{owner}` | `https://github.com/{owner}/{repo}` |

Both scopes share everything else: the same Bicep modules, the same ACA/ACI topology, the same Docker images, the same KEDA scaler, the same ephemeral model.

## GitHub App permissions

### Organisation scope

**Organisation permissions**

| Permission | Access |
|---|---|
| Actions | Read-only |
| Self-hosted runners | Read and write |
| Administration | Read and write |

**Install target:** your organisation. If you use runner groups, install on all repos or the specific repos that should be allowed to target these runners.

### Repository scope

**Repository permissions**

| Permission | Access |
|---|---|
| Administration | Read and write |
| Actions | Read-only |
| Metadata | Read-only (always required) |

**Install target:** only the target repository. The App never needs access to anything else.

The repo scope's permission set is **narrower** than org scope — there are no org-level settings to manage because there is no organisation. This is a strict security benefit for single-repo installations.

## Choosing a scope

| If you have… | Choose |
|---|---|
| A GitHub organisation | `org` |
| A personal account (`github.com/yourname`) | `repo` (orgs are the only context that supports org-scope runners) |
| An org, but you want runners visible to a single repo only | Either `repo` scope, or `org` scope with a runner group restricted to that repo |
| An org and multiple repos that should share runners | `org` |

## Deployment parameters

These three parameters in `infra/main.bicepparam` control scope:

```bicep
param githubOwner = 'your-org-or-user'   // organisation name OR personal user name
param runnerScope = 'org'                // 'org' or 'repo'
param githubRepo = ''                    // required only when runnerScope = 'repo'
```

The Bicep guards against the most common misconfig: if you set `runnerScope = 'repo'` and leave `githubRepo` empty, deployment fails at ARM evaluation time with an error referencing `runnerScope_repo_requires_non_empty_githubRepo`. Beyond that, the setup script and KEDA itself enforce consistency — if the runner target is wrong (e.g. `runnerScope = 'repo'` but a non-existent repo), KEDA will fail to find matching jobs and your runners simply never start.

## Moving between scopes

Moving an existing deployment from one scope to another is a **tear-down-and-redeploy** operation. You cannot migrate in place, because:

- The runner's registration URL is baked into the ACA Job via an environment variable. Changing it requires re-deploying the jobs.
- The GitHub App installation target is tied to the scope and must be re-installed on the new target.
- The KEDA scaler's `runnerScope` metadata must match the registration scope or the scaler simply doesn't scale.

To switch: update `runnerScope` (and `githubRepo` if moving to repo scope) in `infra/main.bicepparam`, redeploy via `deploy.yml`, and re-run `./scripts/setup-github-app.ps1` with the new `-Scope` flag.
