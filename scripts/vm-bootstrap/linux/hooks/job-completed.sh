#!/usr/bin/env bash
# Runner job-completed hook — issue #90.
#
# Warm-retention VMs reuse the same $HOME, /tmp, and _work tree across jobs.
# Without an explicit wipe, the next job inherits:
#   - the previous job's checkout, build outputs, and artefacts under _work/
#   - cached action code under _work/_actions (potentially tampered with)
#   - tool-cache binaries under _work/_tool (potentially planted)
#   - _temp files containing GITHUB_ENV / GITHUB_PATH / step outputs / env files
#   - docker / git / cloud CLI credentials in $HOME
#   - shell rc appendages (user-level PATH mutations)
#   - /tmp and /var/tmp debris (may contain unix sockets, dumped secrets)
#
# Threat model: treat the previous job as adversarial. Any file it could write
# that the next job could read (or source) is in-scope for wiping. The only
# things we preserve are (a) the runner install itself under $RUNNER_HOME,
# (b) system-level config (/etc), and (c) the lifecycle state directory.
#
# Best-effort: individual step failures must not abort the hook — that would
# leave the runner's lifecycle bookkeeping in a dirty state and break the
# watchdog's idle-retention logic.

set +e
umask 077

log() { printf '[job-completed] %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Workspace wipe
# ---------------------------------------------------------------------------
# RUNNER_WORKSPACE is the per-repo dir (e.g. /actions-runner/_work/<repo>).
# We want the full _work tree (parent) so _actions, _tool, _temp also go.
# Fall back to the conventional path if the env var is not set in the hook
# context (older runner versions).
WORK_ROOT=""
if [ -n "${RUNNER_WORKSPACE:-}" ] && [ -d "$RUNNER_WORKSPACE" ]; then
    WORK_ROOT="$(cd "$RUNNER_WORKSPACE/.." 2>/dev/null && pwd)"
fi
: "${WORK_ROOT:=/actions-runner/_work}"

if [ -d "$WORK_ROOT" ]; then
    log "wiping workspace root $WORK_ROOT (keeping dir)"
    find "$WORK_ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 2. Temp dirs
# ---------------------------------------------------------------------------
# Wipe /tmp and /var/tmp contents entirely. RUNNER_TEMP normally lives under
# _work/_temp (already cleared above). If it happens to point at /tmp/<x> we
# clear its contents too — the directory itself is recreated by the next job.
wipe_contents() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    log "wiping contents of $dir"
    find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
}
wipe_contents /tmp
wipe_contents /var/tmp

if [ -n "${RUNNER_TEMP:-}" ] && [ -d "$RUNNER_TEMP" ]; then
    wipe_contents "$RUNNER_TEMP"
fi

# ---------------------------------------------------------------------------
# 3. Credentials and caches in $HOME
# ---------------------------------------------------------------------------
# Allow-list: what STAYS in $HOME
#   - .bashrc / .bash_profile / .profile (baked baseline; see note below)
#   - .ssh/ directory and its baked host keys/authorized_keys (but see known_hosts below)
#
# Everything else that can hold credentials, tokens, or tamperable config is
# wiped. If your workflow legitimately needs one of these caches to persist
# across warm jobs, add it to a self-hosted-runner setup step that re-creates
# it at job-started time.
HOME_WIPE=(
    # Git
    "$HOME/.gitconfig"
    "$HOME/.git-credentials"
    "$HOME/.config/git"

    # Docker / containerd / buildx
    "$HOME/.docker"
    "$HOME/.config/containers"
    "$HOME/.local/share/containers"

    # Cloud CLIs (az login, aws sso, gcloud, kubectl, helm)
    "$HOME/.azure"
    "$HOME/.aws"
    "$HOME/.config/gcloud"
    "$HOME/.kube"
    "$HOME/.config/helm"

    # Language / package managers (creds + tamperable caches)
    "$HOME/.npm"
    "$HOME/.npmrc"
    "$HOME/.yarn"
    "$HOME/.yarnrc"
    "$HOME/.yarnrc.yml"
    "$HOME/.pip"
    "$HOME/.pypirc"
    "$HOME/.m2/settings.xml"
    "$HOME/.m2/settings-security.xml"
    "$HOME/.gradle/caches"
    "$HOME/.gradle/init.d"
    "$HOME/.gradle/gradle.properties"
    "$HOME/.cargo/credentials"
    "$HOME/.cargo/credentials.toml"
    "$HOME/.nuget/NuGet/NuGet.Config"
    "$HOME/.composer"

    # Generic caches (may be tool-cache-adjacent)
    "$HOME/.cache"

    # gh CLI / generic netrc / python keyring
    "$HOME/.config/gh"
    "$HOME/.netrc"
    "$HOME/.local/share/python_keyring"

    # Shell history (may include tokens pasted via `echo` or secret expansion)
    "$HOME/.bash_history"
    "$HOME/.zsh_history"
    "$HOME/.python_history"
    "$HOME/.sqlite_history"
    "$HOME/.node_repl_history"

    # SSH known_hosts (ssh-keyscan poisoning). Keys/authorized_keys are left
    # alone — those are baked, not job-written.
    "$HOME/.ssh/known_hosts"
    "$HOME/.ssh/known_hosts.old"

    # Per-user systemd units a prior job could have dropped
    "$HOME/.config/systemd/user"
)
for path in "${HOME_WIPE[@]}"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
        log "wiping $path"
        rm -rf -- "$path" 2>/dev/null || true
    fi
done

# ---------------------------------------------------------------------------
# 4. Reset user-level PATH / env mutations
# ---------------------------------------------------------------------------
# GitHub Actions job steps can mutate env via GITHUB_ENV / GITHUB_PATH, but
# those only apply to subsequent steps within the same job — they never
# persist to the next job's worker process because each job spawns a fresh
# Runner.Worker from Runner.Listener. So process-env leakage is not the
# concern here.
#
# What DOES leak is rc-file appendage: a malicious step doing
# `echo 'export FOO=evil' >> ~/.bashrc` or `echo '/opt/evil' >> ~/.bash_profile`
# will affect every future bash step on this VM. We defend by truncating the
# runner user's rc files back to empty and letting the system-wide /etc/bash.bashrc
# + /etc/profile.d/* provide the baseline PATH. System PATH (set in /etc/environment
# and /etc/profile) is untouched and continues to stay.
for rc in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile" \
          "$HOME/.zshrc" "$HOME/.zshenv" "$HOME/.zprofile" "$HOME/.zlogin" \
          "$HOME/.inputrc" "$HOME/.pam_environment" "$HOME/.environment"; do
    if [ -f "$rc" ]; then
        log "truncating shell rc $rc"
        : > "$rc" 2>/dev/null || true
    fi
done

# ---------------------------------------------------------------------------
# 5. Docker registry logouts
# ---------------------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
    # `docker logout` without args clears the default (Docker Hub) entry.
    # We also enumerate any registries the engine knows about.
    registries=$(docker system info 2>/dev/null | awk '/^[[:space:]]*Registry:[[:space:]]*/ {print $2}' | sort -u)
    for reg in $registries; do
        log "docker logout $reg"
        docker logout "$reg" >/dev/null 2>&1 || true
    done
    log "docker logout (default)"
    docker logout >/dev/null 2>&1 || true
else
    log "docker not installed; skipping logout"
fi

log "wipe complete"

# ---------------------------------------------------------------------------
# 6. Lifecycle bookkeeping (must always run — watchdog depends on this)
# ---------------------------------------------------------------------------
set -e
LIFECYCLE_DIR="${LIFECYCLE_DIR:-/var/run/runner-lifecycle}"
mkdir -p "$LIFECYCLE_DIR"
rm -f "$LIFECYCLE_DIR/job-active"
date +%s >"$LIFECYCLE_DIR/last-job-end"
