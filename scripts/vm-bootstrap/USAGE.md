# VM-bootstrap usage and trust-boundary contract

This directory provisions long-lived VMSS instances that run ephemeral GitHub
Actions jobs back-to-back (warm retention) without re-imaging the OS between
jobs. Warm retention is a big latency win but it also means the same
filesystem, home directory, and TEMP are reused across jobs — which makes the
per-job cleanup hooks a **trust-boundary control**, not a nice-to-have.

This document describes:

1. How the hooks are wired into the runner lifecycle
2. What each hook wipes (and, crucially, what it **does not** wipe)
3. Known limitations and when you should prefer ephemeral mode

For layout, systemd units, and bootstrap flow see [README.md](./README.md).

---

## 1. Hook wiring

GitHub's `Runner.Listener` invokes a user-supplied script before and after
every job when these env vars are set:

| Env var                            | Points to                                      |
|------------------------------------|------------------------------------------------|
| `ACTIONS_RUNNER_HOOK_JOB_STARTED`  | `linux/hooks/job-started.sh` / `windows/hooks/job-started.cmd` |
| `ACTIONS_RUNNER_HOOK_JOB_COMPLETED`| `linux/hooks/job-completed.sh` / `windows/hooks/job-completed.cmd` |

**Linux** (`linux/bootstrap.sh`): exports both variables immediately before
`exec ./run.sh`, so the runner process and every `Runner.Worker` it forks
inherit them.

**Windows** (`windows/bootstrap.ps1`): writes both variables at `Machine`
scope via `[Environment]::SetEnvironmentVariable(..., 'Machine')`, so the
scheduled task running the runner picks them up on every restart.

The `job-completed` hook is the one that enforces the wipe contract below.
The `job-started` hook only records a lifecycle timestamp used by the idle-
retention watchdog — it is **not** a cleanup hook and does not belong in the
trust-boundary path.

---

## 2. Wipe contract (issue #90)

The `job-completed` hook treats the previous job as **adversarial**: any file
the prior job could write that the next job could read or source is in
scope for wiping.

### Wiped every job

| Category              | Linux                                                 | Windows                                                      |
|-----------------------|-------------------------------------------------------|--------------------------------------------------------------|
| Workspace             | contents of `/actions-runner/_work` (keeps dir)       | contents of `C:\actions-runner\_work`                        |
| Tool cache            | `_work/_tool` (inside workspace root)                 | `_work\_tool`                                                |
| Cached action code    | `_work/_actions`                                      | `_work\_actions`                                             |
| Step env/path files   | `_work/_temp`, `RUNNER_TEMP` contents                 | `_work\_temp`, `RUNNER_TEMP` contents                        |
| General temp          | `/tmp/*`, `/var/tmp/*`                                | `TEMP`, `TMP`, `LOCALAPPDATA\Temp`, `C:\Windows\Temp`        |
| Git                   | `~/.gitconfig`, `~/.git-credentials`, `~/.config/git` | `%USERPROFILE%\.gitconfig`, `.git-credentials`, `.config\git`|
| Docker                | `~/.docker`, `~/.config/containers`, `~/.local/share/containers`, `docker logout` per registry | `%USERPROFILE%\.docker`, `docker logout` per registry |
| Cloud CLIs            | `~/.azure`, `~/.aws`, `~/.config/gcloud`, `~/.kube`, `~/.config/helm` | same equivalents under `%USERPROFILE%` / `AppData\Roaming\gcloud` |
| Package managers      | `~/.npm`, `~/.npmrc`, `~/.yarn`, `~/.yarnrc(.yml)`, `~/.pip`, `~/.pypirc`, `~/.m2/settings*.xml`, `~/.gradle/caches`, `~/.gradle/init.d`, `~/.gradle/gradle.properties`, `~/.cargo/credentials*`, `~/.nuget/NuGet/NuGet.Config`, `~/.composer`, `~/.cache` | equivalents under `%USERPROFILE%` / `AppData\Roaming\(npm\|NuGet)`, `AppData\Local\npm-cache`, `.gradle`, `.m2` etc. |
| Misc creds            | `~/.netrc`, `~/.config/gh` (gh CLI token), `~/.local/share/python_keyring` | `%USERPROFILE%\.netrc`, `_netrc`, `AppData\Roaming\GitHub CLI` |
| SSH poisoning         | `~/.ssh/known_hosts`, `~/.ssh/known_hosts.old`        | same under `%USERPROFILE%\.ssh`                              |
| Shell history         | `~/.bash_history`, `~/.zsh_history`, `~/.python_history`, `~/.sqlite_history`, `~/.node_repl_history` | `PSReadLine\ConsoleHost_history.txt`, `.python_history`, `.node_repl_history` |
| Shell rc appendages   | truncates `~/.bashrc`, `~/.bash_profile`, `~/.bash_login`, `~/.profile`, `~/.zshrc`, `~/.zshenv`, `~/.zprofile`, `~/.zlogin`, `~/.inputrc`, `~/.pam_environment`, `~/.environment` to empty (baseline comes from `/etc/bash.bashrc`, `/etc/profile.d/*`, and `/etc/environment`) | removes every **User-scope** env var in `HKCU\Environment` except `TEMP`, `TMP`, `OneDrive*`; clears User-scope `PATH` (System PATH is untouched) |
| User systemd units    | `~/.config/systemd/user`                              | n/a                                                          |

### Preserved across jobs (intentional)

- The runner install itself (`/actions-runner` / `C:\actions-runner`)
- `/etc`, `/usr`, `/opt` (system config, system binaries)
- System `PATH`, system-scope env vars (`/etc/environment`, HKLM `Environment`)
- SSH host keys and `authorized_keys` (baked, not job-written)
- The lifecycle state directory used by the idle-retention watchdog
  (`/var/run/runner-lifecycle` on Linux)

### Known limitations

- **Root-owned writes** by a job that used `sudo` (or a privileged Docker
  container with host-mount) can place files outside `$HOME` that the hook
  does not enumerate. If your workloads need `sudo`, run ephemeral (one
  job per VM life) and set `warm retention` to `0`.
- **Windows System-scope env var writes** (`[Environment]::SetEnvironmentVariable(..., 'Machine')`)
  require admin; a non-admin job can only write User-scope, which we reset.
  If the runner itself runs as LocalSystem/admin you should treat every job
  as capable of writing Machine-scope — again: prefer ephemeral for
  untrusted workloads.
- **Container layers and volumes** are not pruned by this hook. Run
  `docker system prune` via your own step or a separate maintenance task if
  disk pressure is an issue.
- **Kernel / WSL / container-host state** on Windows is outside the hook's
  scope. If a job installed a driver or enabled a Windows feature, that
  change persists until the VMSS instance is recycled.

If any of the above limitations matter for your threat model, **do not use
warm retention**. Deploy the same images in ephemeral mode (retention = 0,
one job per replica) instead.

---

## 3. Hook exit codes

Both `job-completed` hooks are **best-effort** — they continue on individual
failures because a hook that aborts the runner lifecycle is worse than a
hook that logs a wipe failure. The Linux script uses `set +e` during the
wipe phase and restores `set -e` before the lifecycle bookkeeping tail.
The Windows script uses `$ErrorActionPreference = 'SilentlyContinue'`
throughout.

A wipe failure is surfaced in the runner's diagnostic log
(`_diag/Runner_*.log`) but does not fail the job.
