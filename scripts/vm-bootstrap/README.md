# VM bootstrap & watchdog scripts — Stream E

Lifecycle scripts for VMSS-hosted GitHub Actions self-hosted runners, baked
onto the OS image by Azure Image Builder (Stream D) and executed on first
boot by cloud-init / Scheduled Tasks.

## Layout

```
scripts/vm-bootstrap/
├── linux/
│   ├── bootstrap.sh            # First-boot: IMDS → config.sh → exec run.sh
│   ├── watchdog.sh             # 60s idle/lifetime teardown
│   ├── cloud-init.yml          # VMSS customData shim
│   ├── hooks/
│   │   ├── job-started.sh      # ACTIONS_RUNNER_HOOK_JOB_STARTED
│   │   └── job-completed.sh    # ACTIONS_RUNNER_HOOK_JOB_COMPLETED
│   └── systemd/
│       ├── gh-runner.service           # Runs bootstrap.sh as ghrunner
│       ├── gh-runner-watchdog.service  # Oneshot root
│       └── gh-runner-watchdog.timer    # 60s cadence
└── windows/
    ├── bootstrap.ps1           # First-boot: IMDS → config.cmd --runasservice
    ├── watchdog.ps1            # Scheduled Task, 60s cadence as SYSTEM
    ├── setup-scheduled-tasks.ps1
    └── hooks/
        ├── job-started.cmd
        └── job-completed.cmd
```

## VMSS tag contract

Stream C (launcher) writes these tags on the VMSS instance before bringing
it online. Tags are read by bootstrap via IMDS `compute/tagsList`.

| Tag | Description |
|---|---|
| `ghRunnerRegToken` | One-shot runner registration token. Wiped by bootstrap after use. |
| `ghRunnerRemoveToken` | **Pre-minted** remove-token (no PEM on VM). Stored for the watchdog. |
| `ghRunnerLabels` | Comma-separated labels. |
| `ghRunnerName` | Unique runner name (matches VM instance name). |
| `ghRunnerScope` | `org` or `repo`. |
| `ghRunnerUrl` | `https://github.com/<org>` or `…/<org>/<repo>`. |
| `ghRunnerIdleRetentionMinutes` | `0` ⇒ ephemeral (`--ephemeral`, single-job). |
| `ghRunnerMaxLifetimeHours` | `0` ⇒ no hard cap. |
| `ghRunnerIdentityClientId` | Runner UAMI clientId for `az login --identity`. |

## Lifecycle directory layout

### Linux

| Path | Owner | Mode | Purpose |
|---|---|---|---|
| `/var/run/runner-lifecycle/` | `ghrunner:ghrunner` | `0755` | Runtime state |
| `/var/run/runner-lifecycle/boot` | ghrunner | `0644` | Epoch of first boot |
| `/var/run/runner-lifecycle/job-active` | ghrunner | `0644` | Flag touched by job-started hook |
| `/var/run/runner-lifecycle/last-job-end` | ghrunner | `0644` | Epoch written by job-completed hook |
| `/etc/gh-runner/lifecycle.env` | `root` | `0644` | Shell-sourceable config |
| `/etc/gh-runner/remove-token` | `ghrunner` | `0600` | Pre-minted remove-token |
| `/actions-runner/` | ghrunner | — | Runner install dir |

### Windows

| Path | ACL | Purpose |
|---|---|---|
| `C:\gh-runner-lifecycle\` | SYSTEM + Administrators full | Runtime state |
| `C:\gh-runner-lifecycle\boot` | inherited | Epoch of first boot |
| `C:\gh-runner-lifecycle\job-active` | inherited | Flag |
| `C:\gh-runner-lifecycle\last-job-end` | inherited | Epoch |
| `C:\gh-runner-lifecycle\remove-token.dpapi` | SYSTEM + Administrators only | DPAPI-encrypted remove-token |
| `C:\ProgramData\gh-runner\lifecycle.json` | SYSTEM + Administrators only | Config (JSON) |
| `C:\actions-runner\` | — | Runner install dir |
| `C:\gh-runner-bootstrap\` | — | Scripts baked by AIB |

## Teardown flow

1. Watchdog wakes every 60s.
2. If `job-active` exists → exit 0 immediately.
3. Compare `now - last-job-end` vs `IdleRetentionMinutes`; compare `now - boot` vs `MaxLifetimeHours`. Exit if both under threshold.
4. Deregister: `config.sh remove --token <pre-minted remove-token>` (Linux) / `config.cmd remove --token …` (Windows).
5. Self-delete: `az login --identity --username <runnerClientId>` + `az vmss delete-instances --no-wait`.
6. Belt-and-braces: `shutdown -h now` / `Stop-Computer -Force`.

## Security notes

- **No PEM on the VM.** The launcher mints both the registration token and the remove-token at VMSS instance creation time and passes them via tags. If the remove-token expires before the watchdog runs (unlikely — registration tokens are typically valid for 1h, remove-tokens similar), deregistration is skipped and GitHub will garbage-collect the offline runner within ~24h.
- Reg-token tag is wiped after successful `config.sh`/`config.cmd` (best-effort; non-fatal if the runner MI lacks tag-write).
- Linux `ghrunner` has `sudo NOPASSWD` for `/sbin/shutdown` only.
- Windows DPAPI LocalMachine scope means file ACL is the primary defence.
