#!/usr/bin/env bash
# Windows runner launcher.
# Triggered by KEDA (github-runner scaler, windows label) when a Windows job is queued.
# Creates one ACI Windows container group, waits for the runner to finish, then deletes the group.
set -euo pipefail

# Authenticate to Azure using the user-assigned managed identity attached to this ACA job.
az login --identity --client-id "${AZURE_CLIENT_ID}" --output none

# Derive a unique, DNS-safe ACI group name. The ACA job execution hostname is
# "caj-win-launcher-<prefix>-<execId>-<replica>" — stripping non-alnum and
# taking the first 16 chars collapses every execution to the same prefix and
# causes ACI name collisions. Use the tail (the unique execution/replica slug)
# plus a short random suffix for extra safety.
EXEC_SLUG=$(hostname | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | tail -c 10)
RAND_SUFFIX=$(openssl rand -hex 3)
ACI_NAME="aci-win-runner-${EXEC_SLUG}-${RAND_SUFFIX}"
ACI_CREATED=0

# Temp file used to pass the Log Analytics shared key to `az container create`
# via the CLI's `@file` syntax instead of argv (see create_aci below).
LAW_KEY_FILE=""

# Always attempt to clean up the ACI group we created, even if the script exits
# unexpectedly (error under set -euo pipefail, SIGTERM from ACA replicaTimeout,
# or Ctrl-C). Without this, orphaned Windows ACI groups keep billing and may
# re-register as phantom self-hosted runners.
cleanup() {
  local rc=$?
  # Disable the trap immediately so the explicit `exit` at the bottom of this
  # function does not re-trigger EXIT (which would re-enter cleanup and attempt
  # a second delete on an already-gone ACI group). Cheap belt-and-braces guard
  # against signal-delivery-during-cleanup races as well.
  trap - EXIT INT TERM
  if [[ -n "${LAW_KEY_FILE}" && -f "${LAW_KEY_FILE}" ]]; then
    rm -f "${LAW_KEY_FILE}" || true
  fi
  if [[ "${ACI_CREATED}" == "1" ]]; then
    echo "cleanup: deleting ACI '${ACI_NAME}' (launcher exit=${rc})"

    # Delete with up to 3 attempts and surface stderr, rather than silently
    # swallowing failures via `--no-wait --output none >/dev/null 2>&1 || true`.
    # Past orphaned ACIs (issue: launcher-cleanup) were caused by:
    #   - --no-wait: bash exited before the az CLI flushed its ARM HTTPS request
    #   - >/dev/null 2>&1: zero visibility into ARM throttling / 5xx / auth errors
    # Dropping --no-wait makes the CLI block until ARM returns 2xx (still fast;
    # the actual VM teardown is asynchronous server-side), so we know the delete
    # was accepted before we exit.
    local attempt=1
    local max_attempts=3
    local delay=5
    local delete_stderr
    local delete_rc
    while true; do
      delete_stderr=$(az container delete \
        --resource-group "${RESOURCE_GROUP}" \
        --subscription   "${SUBSCRIPTION_ID}" \
        --name           "${ACI_NAME}" \
        --yes --output none 2>&1 >/dev/null) && delete_rc=0 || delete_rc=$?
      if (( delete_rc == 0 )); then
        echo "cleanup: delete accepted for '${ACI_NAME}' on attempt ${attempt}"
        break
      fi
      echo "cleanup: delete attempt ${attempt}/${max_attempts} failed (rc=${delete_rc}) for '${ACI_NAME}':" >&2
      echo "${delete_stderr}" >&2
      if (( attempt >= max_attempts )); then
        echo "cleanup: ERROR - giving up on deleting '${ACI_NAME}' after ${max_attempts} attempts; orphan will need manual or scheduled-GC cleanup" >&2
        break
      fi
      attempt=$(( attempt + 1 ))
      sleep "${delay}"
      delay=$(( delay * 2 ))
    done

    # Verify the ACI group has actually started terminating. `az container show`
    # returns 404 (ResourceNotFound) once ARM has deleted the group, or the
    # group with provisioningState=Deleting while the VM teardown is in flight.
    # Any other visible state here means the delete silently failed - log loudly
    # so the scheduled-GC workflow knows to reap it later.
    local show_stderr
    local show_rc
    show_stderr=$(az container show \
      --resource-group "${RESOURCE_GROUP}" \
      --subscription   "${SUBSCRIPTION_ID}" \
      --name           "${ACI_NAME}" \
      --query          "provisioningState" \
      --output tsv 2>&1) && show_rc=0 || show_rc=$?
    if (( show_rc != 0 )) && echo "${show_stderr}" | grep -qi 'ResourceNotFound\|could not be found\|not found'; then
      echo "cleanup: verified '${ACI_NAME}' is gone (ResourceNotFound)"
    elif [[ "${show_stderr}" == "Deleting" ]]; then
      echo "cleanup: verified '${ACI_NAME}' is in Deleting state"
    else
      echo "cleanup: WARNING - '${ACI_NAME}' still visible after delete; provisioningState='${show_stderr}' (show rc=${show_rc})" >&2
    fi
  fi
  exit "${rc}"
}
trap cleanup EXIT INT TERM

# Retry wrapper with exponential backoff. Usage: retry <max_attempts> <cmd...>
retry() {
  local max_attempts=$1; shift
  local attempt=1
  local delay=10
  while true; do
    if "$@"; then
      return 0
    fi
    if (( attempt >= max_attempts )); then
      echo "retry: command failed after ${attempt} attempts: $*" >&2
      return 1
    fi
    echo "retry: attempt ${attempt} failed, sleeping ${delay}s..." >&2
    sleep "${delay}"
    attempt=$(( attempt + 1 ))
    delay=$(( delay * 2 ))
  done
}

echo "Creating Windows ACI runner: ${ACI_NAME}"

# Pull the runner image using the user-assigned managed identity
# (--acr-identity). The same identity is attached to the ACI group via
# --assign-identity and has AcrPull on the ACR (granted in identity.bicep).
#
# This replaces the previous --registry-password "$ACR_TOKEN" approach which
# exposed a short-lived ACR access token in the az container create argv
# (visible via /proc/<pid>/cmdline while the command ran) — a real leak risk
# on any shared/multi-tenant host, regardless of the later unset.
#
# NOTE: an earlier iteration reported --acr-identity hanging indefinitely for
# Windows ACI. Retrying here per PR review guidance. If hangs recur in
# production, fall back to passing the token via stdin
# (--registry-password @/dev/stdin <<< "$ACR_TOKEN") rather than reintroducing
# argv exposure.
create_aci() {
  az container create \
    --resource-group "${RESOURCE_GROUP}" \
    --subscription  "${SUBSCRIPTION_ID}" \
    --name          "${ACI_NAME}" \
    --location      "${ACI_LOCATION}" \
    --image         "${ACR_SERVER}/${WINDOWS_RUNNER_IMAGE:-github-runner-windows:stable}" \
    --os-type       Windows \
    --cpu           "${WINDOWS_CPU:-4}" \
    --memory        "${WINDOWS_MEMORY_GB:-8}" \
    --assign-identity "${MANAGED_IDENTITY_ID}" \
    --acr-identity   "${MANAGED_IDENTITY_ID}" \
    --restart-policy  Never \
    --environment-variables \
      "GITHUB_APP_ID=${GITHUB_APP_ID}" \
      "GITHUB_INSTALLATION_ID=${GITHUB_INSTALLATION_ID}" \
      "ACCESS_TOKEN_API_URL=${ACCESS_TOKEN_API_URL}" \
      "REGISTRATION_TOKEN_API_URL=${REGISTRATION_TOKEN_API_URL}" \
      "RUNNER_REGISTRATION_URL=${RUNNER_REGISTRATION_URL}" \
      "RUNNER_LABELS=${RUNNER_LABELS}" \
    --secure-environment-variables \
      "GITHUB_APP_PEM_B64=${GITHUB_APP_PEM_B64}" \
    --log-analytics-workspace     "${LOG_ANALYTICS_WORKSPACE_ID}" \
    --log-analytics-workspace-key "@${LAW_KEY_FILE}" \
    --output none
}

# Write the Log Analytics shared key to a mode 0600 temp file and pass it to
# `az container create` via the Azure CLI `@file` syntax, rather than inlining
# the key on argv (`--log-analytics-workspace-key "$KEY"`). Argv is visible in
# /proc/<pid>/cmdline and ACA job execution traces while the command runs —
# the same leak class as the previously-fixed ACR_TOKEN. The `@file` form
# causes only the file path to appear in the process listing; the CLI reads
# the key out of band. The file is unlinked in the cleanup trap, and the
# in-memory env var is unset immediately after the CLI call below.
#
# Note: The ACI REST response does not surface the shared key (keys are
# write-only server-side), so the remaining risk vector is purely local.
umask 077
LAW_KEY_FILE=$(mktemp -t law-key.XXXXXXXX)
# Fetch the Log Analytics shared key at runtime via the launcher's managed
# identity (issue #73). Previously the key was baked into this ACA Job as a
# secret in Bicep and injected via LOG_ANALYTICS_WORKSPACE_KEY; now the MI holds
# Log Analytics Contributor on the workspace and lists the key on demand. The
# value is streamed straight into the 0600-mode temp file so it never touches
# argv, a named env var, or the shell's history.
az monitor log-analytics workspace get-shared-keys \
  --resource-group "${RESOURCE_GROUP}" \
  --subscription   "${SUBSCRIPTION_ID}" \
  --workspace-name "${LOG_ANALYTICS_WORKSPACE_NAME}" \
  --query primarySharedKey \
  --output tsv > "${LAW_KEY_FILE}"
if [[ ! -s "${LAW_KEY_FILE}" ]]; then
  echo "Failed to retrieve Log Analytics shared key for workspace '${LOG_ANALYTICS_WORKSPACE_NAME}'" >&2
  exit 1
fi

# Retry az container create on transient control-plane failures (throttling,
# region blips). 3 attempts with 10s / 20s backoff.
if ! retry 3 create_aci; then
  echo "Failed to create ACI group after retries" >&2
  exit 1
fi
ACI_CREATED=1

# Remove the temp file as soon as the CLI call is done. The cleanup trap will
# also rm -f the file on any abnormal exit path above.
rm -f "${LAW_KEY_FILE}"
LAW_KEY_FILE=""

echo "ACI group created. Waiting for the Windows runner to complete..."

# Bounded poll. Default ~3h50m (230 iterations * 60s), just under the ACA Job
# replicaTimeout of 4h so the trap can still run cleanup before SIGKILL.
MAX_POLL_ITERATIONS="${MAX_POLL_ITERATIONS:-230}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-60}"
iteration=0

while (( iteration < MAX_POLL_ITERATIONS )); do
  iteration=$(( iteration + 1 ))

  STATE=$(az container show \
    --resource-group "${RESOURCE_GROUP}" \
    --subscription  "${SUBSCRIPTION_ID}" \
    --name          "${ACI_NAME}" \
    --query         "containers[0].instanceView.currentState.state" \
    --output tsv 2>/dev/null || echo "Pending")

  echo "  [${iteration}/${MAX_POLL_ITERATIONS}] State: ${STATE}"

  if [[ "${STATE}" == "Terminated" ]]; then
    EXIT_CODE=$(az container show \
      --resource-group "${RESOURCE_GROUP}" \
      --subscription  "${SUBSCRIPTION_ID}" \
      --name          "${ACI_NAME}" \
      --query         "containers[0].instanceView.currentState.exitCode" \
      --output tsv 2>/dev/null || echo "unknown")
    echo "Runner finished (exit code: ${EXIT_CODE})"
    # On non-zero exit, surface the last lines of container logs and events to
    # make failures visible in launcher logs without needing to query ACI LAW.
    if [[ "${EXIT_CODE}" != "0" ]]; then
      echo "--- ACI container logs (tail) ---"
      az container logs \
        --resource-group "${RESOURCE_GROUP}" \
        --subscription  "${SUBSCRIPTION_ID}" \
        --name          "${ACI_NAME}" 2>&1 | tail -n 80 || true
      echo "--- ACI events ---"
      az container show \
        --resource-group "${RESOURCE_GROUP}" \
        --subscription  "${SUBSCRIPTION_ID}" \
        --name          "${ACI_NAME}" \
        --query         "containers[0].instanceView.events" \
        --output json 2>&1 || true
    fi
    break
  fi

  sleep "${POLL_INTERVAL_SECONDS}"
done

if (( iteration >= MAX_POLL_ITERATIONS )); then
  echo "Polling deadline reached (${MAX_POLL_ITERATIONS} iterations). Exiting so trap can clean up hung ACI group." >&2
  exit 2
fi

echo "Launcher done (cleanup trap will delete ${ACI_NAME})."
