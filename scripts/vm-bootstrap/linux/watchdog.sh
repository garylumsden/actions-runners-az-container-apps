#!/usr/bin/env bash
# Idle/lifetime watchdog for a VMSS-hosted GitHub Actions runner.
# Runs every 60s as root via gh-runner-watchdog.timer.
set -euo pipefail

LIFECYCLE_DIR="/var/run/runner-lifecycle"
ENV_FILE="/etc/gh-runner/lifecycle.env"

log() { printf '[watchdog] %s\n' "$*" >&2; }

# Fast path: a job is running, nothing to do.
if [ -e "${LIFECYCLE_DIR}/job-active" ]; then
  exit 0
fi

[ -r "$ENV_FILE" ] || { log "missing $ENV_FILE -- runner not yet bootstrapped"; exit 0; }
# shellcheck disable=SC1090
. "$ENV_FILE"

: "${IDLE_RETENTION_MINUTES:=0}"
: "${MAX_LIFETIME_HOURS:=0}"
# #100: MAX_LIFETIME_MINUTES, when >0, overrides MAX_LIFETIME_HOURS to allow
# finer-grained (sub-hour) recycle caps. Default 0 falls through to hours.
: "${MAX_LIFETIME_MINUTES:=0}"
: "${RUNNER_HOME:=/actions-runner}"
: "${RUNNER_USER:=ghrunner}"
: "${VMSS_NAME:=}"
: "${RESOURCE_GROUP:=}"
: "${RUNNER_IDENTITY_CLIENT_ID:=}"
: "${KV_NAME:=}"
: "${RUNNER_TOKEN_SECRET:=}"

boot_file="${LIFECYCLE_DIR}/boot"
last_end_file="${LIFECYCLE_DIR}/last-job-end"

[ -r "$boot_file" ] || { log "no boot timestamp yet -- skipping"; exit 0; }

now=$(date +%s)
boot=$(cat "$boot_file")
if [ -r "$last_end_file" ]; then
  last_end=$(cat "$last_end_file")
else
  last_end="$boot"
fi

idle=$(( now - last_end ))
age=$(( now - boot ))

ephemeral="false"
[ "${IDLE_RETENTION_MINUTES}" = "0" ] && ephemeral="true"

reason=""
if [ "$ephemeral" = "false" ] && [ "$idle" -ge $(( IDLE_RETENTION_MINUTES * 60 )) ]; then
  reason="idle for ${idle}s (retention=${IDLE_RETENTION_MINUTES}m)"
fi

# #100: compute effective max lifetime in seconds. If MAX_LIFETIME_MINUTES>0
# it takes precedence over MAX_LIFETIME_HOURS (enables sub-hour CI tests and
# fine-grained production caps); otherwise fall back to hours for backwards
# compatibility with existing deployments.
if [ "${MAX_LIFETIME_MINUTES}" != "0" ]; then
  max_seconds=$(( MAX_LIFETIME_MINUTES * 60 ))
  max_label="${MAX_LIFETIME_MINUTES}m"
else
  max_seconds=$(( MAX_LIFETIME_HOURS * 3600 ))
  max_label="${MAX_LIFETIME_HOURS}h"
fi

if [ "$max_seconds" -gt 0 ] && [ "$age" -ge "$max_seconds" ]; then
  reason="${reason:+$reason; }age ${age}s exceeds max ${max_label}"
fi

[ -z "$reason" ] && exit 0

log "teardown: $reason"

# Teardown ordering (fixes #93):
#   1. az vmss delete-instances --no-wait  -- starts infrastructure tear-down.
#      Control-plane marks the instance as Deleting immediately; the runner's
#      heartbeat to GitHub stops within ~30s when networking is cordoned.
#   2. config.sh remove                    -- clean local deregister. By the
#      time this runs, GitHub either already considers the runner offline or
#      is about to; the call races only with the runner removing its own
#      config files -- harmless.
#   3. shutdown -h now                     -- belt-and-braces power off.
#
# Previous order (config.sh remove BEFORE vmss delete-instances) left a
# multi-second window where the runner still appeared "online and idle" to
# the GitHub scheduler, which could assign a fresh job to a VM about to
# disappear. Reversing the order closes that window.
#
# TODO(hardening): the strictly atomic variant is a DELETE on
# /repos/.../actions/runners/{id} with an installation access token. That
# requires the GitHub App PEM on the VM, which this design deliberately
# avoids -- only the short-lived remove-token is persisted here.

# 1. Self-delete from the VMSS so the scaler's desired count matches reality.
vmss_delete_issued=0
if [ -n "$VMSS_NAME" ] && [ -n "$RESOURCE_GROUP" ] && [ -n "$RUNNER_IDENTITY_CLIENT_ID" ]; then
  if az login --identity --client-id "$RUNNER_IDENTITY_CLIENT_ID" >/dev/null 2>&1; then
    # IMDS exposes the VM's short name (e.g. "vmss_0"); we need the VMSS instance ID.
    instance_id=$(curl -fsS -H 'Metadata:true' \
      "http://169.254.169.254/metadata/instance/compute/name?api-version=2021-02-01&format=text")
    # instance_id looks like "<vmss>_<n>"; delete-instances wants "<n>".
    instance_ordinal="${instance_id##*_}"
    log "az vmss delete-instances --name $VMSS_NAME --instance-ids $instance_ordinal"
    if az vmss delete-instances \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VMSS_NAME" \
        --instance-ids "$instance_ordinal" \
        --no-wait >/dev/null 2>&1; then
      vmss_delete_issued=1
    else
      log "WARNING: vmss delete-instances call failed -- relying on shutdown"
    fi
  else
    log "WARNING: az login via MI failed -- relying on shutdown"
  fi
else
  log "VMSS identifiers incomplete -- skipping self-delete"
fi

# 2. Deregister with GitHub. Runs after delete-instances so there is no
#    window in which the runner is "online and idle" to the scheduler while
#    we are tearing it down. We re-fetch the remove-token from Key Vault
#    (it lives under a per-instance secret, issue #92) using the VM's UAMI.
#    If the launcher has already best-effort-deleted the secret (normal
#    success path) or KV is unreachable, we log a warning and continue --
#    GitHub-side runner records time out on their own, and the VM is about
#    to be deleted regardless.
remove_token=""
if [ -n "$KV_NAME" ] && [ -n "$RUNNER_TOKEN_SECRET" ]; then
  # az login already happened above for the vmss delete path; if it failed
  # we still try here (idempotent) so that the tokens-in-KV path works even
  # when the delete path short-circuits (e.g. in local simulation).
  az login --identity --client-id "$RUNNER_IDENTITY_CLIENT_ID" >/dev/null 2>&1 || true
  secret_json=$(az keyvault secret show \
    --vault-name "$KV_NAME" \
    --name "$RUNNER_TOKEN_SECRET" \
    --query value -o tsv 2>/dev/null || true)
  if [ -n "$secret_json" ]; then
    remove_token=$(printf '%s' "$secret_json" | jq -r '.remove // empty' 2>/dev/null || true)
  fi
  secret_json=""
  unset secret_json
fi

if [ -n "$remove_token" ]; then
  if sudo -u "$RUNNER_USER" -H bash -c "cd '$RUNNER_HOME' && ./config.sh remove --token '$remove_token'"; then
    log "runner deregistered from GitHub"
  else
    log "WARNING: config.sh remove failed (token may have expired) -- continuing (vmss delete issued=${vmss_delete_issued})"
  fi
else
  log "WARNING: could not fetch remove-token from KV (secret deleted or KV unreachable) -- skipping deregister (vmss delete issued=${vmss_delete_issued})"
fi

# 3. Belt-and-braces: power off. systemd will SIGTERM gh-runner.service first.
log "shutdown -h now"
/sbin/shutdown -h now
