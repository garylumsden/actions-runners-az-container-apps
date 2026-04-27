#!/usr/bin/env bash
# Bootstrap a GitHub Actions self-hosted runner on a VMSS Linux instance.
# Runs as the ghrunner user via the gh-runner.service systemd unit on first boot.
#
# Contract (VMSS tags, read via IMDS):
#   ghRunnerTokenSecret           -- Key Vault secret name with {reg, remove} tokens (JSON)
#   ghRunnerKvName                -- Key Vault name hosting the runner-token secret
#   ghRunnerLabels                -- comma-separated labels
#   ghRunnerName                  -- runner name (unique within scope)
#   ghRunnerScope                 -- "org" or "repo" (informational)
#   ghRunnerUrl                   -- full https://github.com/<org> or .../<org>/<repo> URL
#   ghRunnerIdleRetentionMinutes  -- integer; 0 => ephemeral, single-job
#   ghRunnerMaxLifetimeHours      -- integer; 0 => no hard cap
#
# Moving reg/remove tokens out of VMSS instance tags into per-instance Key
# Vault secrets (issue #92) means an unprivileged workload on the VM can no
# longer pull the tokens straight from IMDS — the fetch requires the VM's
# UAMI via `az keyvault secret show`.
#
# State directory (single source of truth, owned by ghrunner where possible):
#   /var/run/runner-lifecycle/boot          -- unix epoch of bootstrap completion
#   /var/run/runner-lifecycle/job-active    -- present iff a job is currently running
#   /var/run/runner-lifecycle/last-job-end  -- unix epoch of most recent job completion
#
# Config files (root-owned, non-secret):
#   /etc/gh-runner/lifecycle.env            -- watchdog config, sourced by watchdog.sh
#   (remove-token is no longer persisted on disk — watchdog re-fetches from KV
#   on teardown; if KV is unreachable or the secret has been deleted the
#   watchdog logs a warning and skips deregistration, since GitHub-side runner
#   records expire on their own and the VM is about to be deleted anyway.)

set -euo pipefail

log() { printf '[bootstrap] %s\n' "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

RUNNER_HOME="/actions-runner"
LIFECYCLE_DIR="/var/run/runner-lifecycle"
ETC_DIR="/etc/gh-runner"
HOOK_STARTED="/opt/gh-runner-bootstrap/hooks/job-started.sh"
HOOK_COMPLETED="/opt/gh-runner-bootstrap/hooks/job-completed.sh"

IMDS_BASE="http://169.254.169.254/metadata/instance"
IMDS_API="api-version=2021-02-01"

# Read a single VMSS tag (tags are surfaced as a semicolon-delimited list on IMDS)
imds_tag() {
  local tag_name="$1"
  curl -fsS -H 'Metadata:true' \
    "${IMDS_BASE}/compute/tagsList?${IMDS_API}" \
    | jq -r --arg n "$tag_name" '.[] | select(.name==$n) | .value'
}

imds_text() {
  local path="$1"
  curl -fsS -H 'Metadata:true' \
    "${IMDS_BASE}/${path}?${IMDS_API}&format=text"
}

main() {
  command -v jq >/dev/null 2>&1 || die "jq not found (should be baked into image)"
  command -v az >/dev/null 2>&1 || die "az cli not found (should be baked into image)"
  [ -d "$RUNNER_HOME" ] || die "runner home $RUNNER_HOME missing (should be laid down by AIB)"

  log "reading VMSS tags from IMDS"
  local token_secret kv_name labels name scope url idle_min max_hours max_minutes
  token_secret="$(imds_tag ghRunnerTokenSecret)"
  kv_name="$(imds_tag ghRunnerKvName)"
  labels="$(imds_tag ghRunnerLabels)"
  name="$(imds_tag ghRunnerName)"
  scope="$(imds_tag ghRunnerScope)"
  url="$(imds_tag ghRunnerUrl)"
  idle_min="$(imds_tag ghRunnerIdleRetentionMinutes)"
  max_hours="$(imds_tag ghRunnerMaxLifetimeHours)"
  # #100: optional tag — launchers predating minutes-override won't stamp it.
  # Treat missing/empty as "0" (fall through to hours in watchdog).
  max_minutes="$(imds_tag ghRunnerMaxLifetimeMinutes || true)"
  [ -n "$max_minutes" ] || max_minutes="0"

  [ -n "$token_secret" ] || die "ghRunnerTokenSecret tag missing"
  [ -n "$kv_name" ]      || die "ghRunnerKvName tag missing"
  [ -n "$labels" ]       || die "ghRunnerLabels tag missing"
  [ -n "$name" ]         || die "ghRunnerName tag missing"
  [ -n "$url" ]          || die "ghRunnerUrl tag missing"
  : "${scope:=org}"
  # #89: fail loud rather than silently demote a warm runner to ephemeral.
  # The VMSS launcher stamps these tags on every instance; a missing value
  # here means the launcher PATCH silently regressed or was never deployed.
  [ -n "$idle_min" ]  || die "ghRunnerIdleRetentionMinutes tag missing — VMSS launcher must stamp this (see docker/vmss-launcher/entrypoint.sh)"
  [ -n "$max_hours" ] || die "ghRunnerMaxLifetimeHours tag missing — VMSS launcher must stamp this (see docker/vmss-launcher/entrypoint.sh)"
  case "$idle_min"    in ''|*[!0-9]*) die "ghRunnerIdleRetentionMinutes tag '$idle_min' is not a non-negative integer";; esac
  case "$max_hours"   in ''|*[!0-9]*) die "ghRunnerMaxLifetimeHours tag '$max_hours' is not a non-negative integer";; esac
  case "$max_minutes" in ''|*[!0-9]*) die "ghRunnerMaxLifetimeMinutes tag '$max_minutes' is not a non-negative integer";; esac

  # Subscription / RG / VMSS identifiers for the self-delete path in the watchdog.
  local subscription_id resource_group vmss_name mi_client_id
  subscription_id="$(imds_text compute/subscriptionId)"
  resource_group="$(imds_text compute/resourceGroupName)"
  vmss_name="$(imds_text compute/vmScaleSetName)"

  # The runner identity's clientId is surfaced in IMDS identity block; tolerate missing.
  mi_client_id="$(curl -fsS -H 'Metadata:true' \
    "${IMDS_BASE}/compute?${IMDS_API}" \
    | jq -r '.userData // empty' 2>/dev/null || true)"
  # Preferred: explicit tag override (launcher sets this to the runner UAMI clientId)
  local tagged_client_id
  tagged_client_id="$(imds_tag ghRunnerIdentityClientId || true)"
  if [ -n "$tagged_client_id" ] && [ "$tagged_client_id" != "null" ]; then
    mi_client_id="$tagged_client_id"
  fi

  log "preparing state directories"
  install -d -m 0755 -o ghrunner -g ghrunner "$LIFECYCLE_DIR"
  # /etc/gh-runner is pre-created ghrunner:ghrunner by cloud-init so this
  # process (User=ghrunner) can write lifecycle.env below. Do not attempt
  # to recreate as root-owned here — install(1) as a non-root user cannot
  # set root ownership and would fail silently, leaving the dir untouched.

  log "writing /etc/gh-runner/lifecycle.env"
  umask 022
  cat >"${ETC_DIR}/lifecycle.env" <<EOF
# Managed by bootstrap.sh -- do not edit by hand.
IDLE_RETENTION_MINUTES=${idle_min}
MAX_LIFETIME_HOURS=${max_hours}
MAX_LIFETIME_MINUTES=${max_minutes}
VMSS_NAME=${vmss_name}
RESOURCE_GROUP=${resource_group}
SUBSCRIPTION_ID=${subscription_id}
GH_RUNNER_SCOPE_URL=${url}
RUNNER_IDENTITY_CLIENT_ID=${mi_client_id}
KV_NAME=${kv_name}
RUNNER_TOKEN_SECRET=${token_secret}
LIFECYCLE_DIR=${LIFECYCLE_DIR}
RUNNER_HOME=${RUNNER_HOME}
RUNNER_USER=ghrunner
EOF
  chmod 0644 "${ETC_DIR}/lifecycle.env"

  log "logging in with user-assigned managed identity (clientId=${mi_client_id})"
  az login --identity --client-id "$mi_client_id" >/dev/null \
    || die "az login --identity failed — cannot fetch runner-token secret from KV"

  log "fetching runner-token secret '${token_secret}' from Key Vault '${kv_name}'"
  local secret_json reg_token remove_token
  secret_json="$(az keyvault secret show \
    --vault-name "$kv_name" \
    --name "$token_secret" \
    --query value -o tsv)" \
    || die "unable to fetch runner-token secret from Key Vault"
  reg_token="$(printf '%s' "$secret_json" | jq -r '.reg // empty')"
  remove_token="$(printf '%s' "$secret_json" | jq -r '.remove // empty')"
  [ -n "$reg_token" ]    || die "runner-token secret missing .reg field"
  [ -n "$remove_token" ] || die "runner-token secret missing .remove field"
  # Scrub the combined JSON from shell memory — only the split tokens are
  # passed to config.sh, and the remove-token is re-fetched from KV by the
  # watchdog at teardown (we no longer persist it on disk; see #92).
  secret_json=""
  unset secret_json

  log "clearing KV-related tags from VMSS instance (cosmetic hardening)"
  # Best-effort. The secret itself lives in KV and is best-effort-deleted by the
  # launcher after it sees the VM reach Succeeded; clearing tags is defence in
  # depth for the case where a stale tag could mislead a future debugger.
  local vmss_id
  vmss_id="$(imds_text compute/resourceId || true)"
  if [ -n "$vmss_id" ]; then
    az tag update --resource-id "$vmss_id" --operation delete \
      --tags ghRunnerTokenSecret='' ghRunnerKvName='' \
      >/dev/null 2>&1 || log "tag wipe failed (non-fatal)"
  fi

  log "recording boot timestamp"
  date +%s >"${LIFECYCLE_DIR}/boot"
  chown ghrunner:ghrunner "${LIFECYCLE_DIR}/boot"

  log "configuring GitHub runner"
  cd "$RUNNER_HOME"

  local ephemeral_flag=()
  if [ "${idle_min}" = "0" ]; then
    ephemeral_flag=(--ephemeral)
  fi

  ./config.sh \
    --url       "$url" \
    --token     "$reg_token" \
    --labels    "$labels" \
    --name      "$name" \
    --unattended \
    --replace \
    --disableupdate \
    "${ephemeral_flag[@]}"

  # Hooks are intentionally injected via the process environment here, not via
  # a systemd drop-in under /etc/systemd/system/gh-runner.service.d/. The
  # service runs as User=ghrunner (see systemd/gh-runner.service), which cannot
  # write to /etc/systemd/system/. Since bootstrap.sh always precedes run.sh
  # via `exec` in the same process, the exports below are inherited by run.sh
  # and every job-step subprocess the runner launches.
  log "exporting job hook env vars for exec ./run.sh"
  export ACTIONS_RUNNER_HOOK_JOB_STARTED="$HOOK_STARTED"
  export ACTIONS_RUNNER_HOOK_JOB_COMPLETED="$HOOK_COMPLETED"

  log "launching runner (exec ./run.sh)"
  exec ./run.sh
}

main "$@"
