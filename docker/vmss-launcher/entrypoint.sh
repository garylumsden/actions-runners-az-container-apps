#!/usr/bin/env bash
# #98 H2: history is disabled below immediately after `set -euo pipefail`
# so any accidental trace cannot retain the decoded PEM or GitHub tokens.
# VMSS runner launcher (OS-agnostic: Linux or Windows VMSS).
# Triggered by KEDA (github-runner scaler) when a job targeting this tier is
# queued. Adds ONE new VM to the configured VMSS, stamps per-instance tags
# carrying the registration details, and exits fire-and-forget. The VM
# bootstrap reads the tags via IMDS, configures the runner as --ephemeral,
# runs exactly one job, deregisters itself using the remove-token, and is
# then deallocated / replaced by VMSS.
#
# Design notes:
#   * Uses `az rest` PUT against the modern single-instance create API
#     (Microsoft.Compute/virtualMachineScaleSets/virtualMachines/{name},
#     api-version 2024-11-01). Falls back to `az vmss scale` if the API
#     rejects the verb with Method Not Allowed.
#   * Registration details travel via a MIX of per-instance VMSS tags (for
#     non-secret metadata) and a per-instance Key Vault secret (for the
#     short-lived registration + remove tokens). The VM bootstrap reads the
#     tags via IMDS to discover the secret name + vault, then fetches the
#     token JSON using its own managed identity. VMSS instance tags remain
#     readable by any process on the VM via IMDS, so carrying tokens in
#     tags (the pre-#92 design) exposed them to every workload the runner
#     ran — moving the tokens into Key Vault closes that trust-boundary
#     gap because reaching KV requires the VM's UAMI, which is much harder
#     to abuse than a plain IMDS tag read. See issue #92.
#
# Required env vars (see infra/modules/vmss-*.bicep):
#   AZURE_CLIENT_ID, AZURE_SUBSCRIPTION_ID, RESOURCE_GROUP
#   VMSS_NAME
#   RUNNER_OS                       (linux|windows)
#   RUNNER_LABELS
#   GITHUB_ORG, GITHUB_REPO, RUNNER_SCOPE    (scope=org|repo; GITHUB_REPO may be empty for org)
#   GITHUB_APP_ID, GITHUB_INSTALLATION_ID, GITHUB_APP_PEM_B64
#   RUNNER_IDENTITY_RESOURCE_ID     (user-assigned MI for the VM)
#   KV_NAME                         (Key Vault that holds per-instance runner-token secrets)
#   ACCESS_TOKEN_API_URL            (optional: derived from installation id if unset)
#   API_VERSION                     (optional: defaults to 2024-11-01)
#
# Tag contract (written onto the newly-created VMSS instance):
#   ghRunnerTokenSecret      — Key Vault secret name holding {reg, remove} JSON
#   ghRunnerKvName           — Key Vault name (short name, not URL)
#   ghRunnerUrl              — URL to pass to config.(sh|cmd) --url
#                              (org: https://github.com/<owner>
#                               repo: https://github.com/<owner>/<repo>)
#   ghRunnerScope            — org|repo (informational, for bootstrap branching)
#   ghRunnerLabels           — comma-separated label list for config --labels
#   ghRunnerName             — desired runner name (= VM name)
#   ghRunnerIdentityClientId — UAMI client ID so the VM can `az login --identity`
#   ghRunnerOS               — linux|windows (bootstrap may branch on this)
#
# Lifecycle-state tags (issue #89 — read by the reaper / warm-retention logic,
# and updated by the in-VM job-completed hook — see scripts/vm-bootstrap/*/
# hooks/job-completed.* which is owned by issue #90). The launcher writes the
# initial values so the reaper has a consistent view from VM-creation time:
#   ghr:state                 — idle|busy (launcher initialises to "idle";
#                               the job-started / job-completed hooks flip it)
#   ghr:last-job-completed-at — RFC3339 UTC timestamp of the most recent
#                               successful job completion. At creation time
#                               we stamp the VM-creation timestamp as the
#                               sentinel so the idle-retention calculation
#                               (`now - last-job-completed-at`) stays
#                               well-defined before the first job runs.
#   ghr:job-count             — monotonic count of jobs completed on this VM.
#                               Launcher initialises to 0.

set -euo pipefail
# #98 H2: disable history so `set -x` tracing or accidental echoes of
# $GITHUB_APP_PEM_B64 / tokens cannot persist into $HISTFILE.
set +o history

log() { printf '%s [vmss-launcher] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

# ── Config with defaults ──────────────────────────────────────────────────────
API_VERSION="${API_VERSION:-2024-11-01}"
PROVISION_TIMEOUT_SECONDS="${PROVISION_TIMEOUT_SECONDS:-720}"   # 12 min — must stay < replicaTimeout (780s) in vmss-launcher.bicep; see #93
PROVISION_POLL_INTERVAL="${PROVISION_POLL_INTERVAL:-15}"

: "${AZURE_CLIENT_ID:?AZURE_CLIENT_ID required}"
: "${AZURE_SUBSCRIPTION_ID:?AZURE_SUBSCRIPTION_ID required}"
: "${RESOURCE_GROUP:?RESOURCE_GROUP required}"
: "${VMSS_NAME:?VMSS_NAME required}"
: "${RUNNER_OS:?RUNNER_OS required (linux|windows)}"
: "${RUNNER_LABELS:?RUNNER_LABELS required}"
: "${RUNNER_SCOPE:?RUNNER_SCOPE required (org|repo)}"
: "${GITHUB_ORG:?GITHUB_ORG required}"
: "${GITHUB_APP_ID:?GITHUB_APP_ID required}"
: "${GITHUB_INSTALLATION_ID:?GITHUB_INSTALLATION_ID required}"
: "${GITHUB_APP_PEM_B64:?GITHUB_APP_PEM_B64 required}"
: "${RUNNER_IDENTITY_CLIENT_ID:?RUNNER_IDENTITY_CLIENT_ID required (UAMI client ID attached to the VMSS so bootstrap can az login --identity)}"
: "${KV_NAME:?KV_NAME required (Key Vault that holds per-instance runner-token secrets; issue #92)}"

# #89: lifecycle tier values that the VM bootstrap reads to distinguish
# warm/long-lived instances from ephemeral ones. Must be stamped on the
# instance tags — the VMSS-level tags are NOT inherited by child VMs — and
# must be non-negative integers. Fail loud on missing/garbage input: a
# silent default of 0 demotes every warm runner to ephemeral (see issue #89).
: "${IDLE_RETENTION_MINUTES:?IDLE_RETENTION_MINUTES required (non-negative integer; set via Bicep, see issue #89)}"
: "${MAX_LIFETIME_HOURS:?MAX_LIFETIME_HOURS required (non-negative integer; set via Bicep, see issue #89)}"
# #100: optional override to cap VM lifetime in minutes. Defaults to 0 for
# backwards compatibility; when set >0 it takes precedence over
# MAX_LIFETIME_HOURS in the watchdog. Stamped on every instance so the
# bootstrap can propagate it into lifecycle.env / lifecycle.json.
: "${MAX_LIFETIME_MINUTES:=0}"
case "${IDLE_RETENTION_MINUTES}" in ''|*[!0-9]*)
    log "IDLE_RETENTION_MINUTES='${IDLE_RETENTION_MINUTES}' is not a non-negative integer"; exit 1;;
esac
case "${MAX_LIFETIME_HOURS}" in ''|*[!0-9]*)
    log "MAX_LIFETIME_HOURS='${MAX_LIFETIME_HOURS}' is not a non-negative integer"; exit 1;;
esac
case "${MAX_LIFETIME_MINUTES}" in ''|*[!0-9]*)
    log "MAX_LIFETIME_MINUTES='${MAX_LIFETIME_MINUTES}' is not a non-negative integer"; exit 1;;
esac

# ── State used by the cleanup trap ────────────────────────────────────────────
PEM_FILE=""
TMP_BODY=""
INSTANCE_CREATED=0
INSTANCE_NAME=""
SECRET_CREATED=0
SECRET_NAME=""

cleanup() {
  local rc=$?

  # Shred the decoded PEM on every exit path (including SIGTERM from ACA
  # replicaTimeout). shred when available, plain rm otherwise.
  if [[ -n "${PEM_FILE}" && -f "${PEM_FILE}" ]]; then
    shred -u "${PEM_FILE}" 2>/dev/null || rm -f "${PEM_FILE}" || true
  fi
  if [[ -n "${TMP_BODY}" && -f "${TMP_BODY}" ]]; then
    shred -u "${TMP_BODY}" 2>/dev/null || rm -f "${TMP_BODY}" || true
  fi

  # On error, best-effort delete the VMSS instance we created so a failed
  # launch doesn't leave an orphaned half-configured VM billing for hours.
  # DELETE on the single-instance resource is supported at the same api
  # version we used to create it.
  if [[ "${rc}" -ne 0 && "${INSTANCE_CREATED}" -eq 1 && -n "${INSTANCE_NAME}" ]]; then
    log "error path: deleting partially-created VMSS instance '${INSTANCE_NAME}'"
    # Prefer the resource-id-based URL captured by the scale-fallback path
    # (Flexible VMSS); fall back to the Uniform child path otherwise.
    local delete_url="${INSTANCE_URL:-https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Compute/virtualMachineScaleSets/${VMSS_NAME}/virtualMachines/${INSTANCE_NAME}?api-version=${API_VERSION}}"
    az rest \
      --method DELETE \
      --url "${delete_url}" \
      --output none 2>/dev/null || true
  fi

  # On the error path, best-effort soft-delete the per-instance runner-token
  # KV secret so the short-lived tokens disappear as soon as possible.
  # On the SUCCESS path we deliberately DO NOT delete the secret: the launcher
  # exits as soon as the VMSS instance reaches provisioningState=Succeeded,
  # which fires BEFORE cloud-init runs inside the VM — deleting here would
  # race the VM's bootstrap fetch of the token and prevent runner registration
  # (observed via warm-run jobs stuck in "queued" forever). The token carries
  # its own ~1h TTL at GitHub so leaving the KV secret in place is safe;
  # Key Vault's 90d soft-delete retention is hygiene only. See #92.
  if [[ "${rc}" -ne 0 && "${SECRET_CREATED}" -eq 1 && -n "${SECRET_NAME}" ]]; then
    log "error path: deleting KV secret '${SECRET_NAME}' in vault '${KV_NAME}'"
    az keyvault secret delete \
      --vault-name "${KV_NAME}" \
      --name "${SECRET_NAME}" \
      --output none 2>/dev/null || log "kv secret delete failed (non-fatal)"
  fi

  exit "${rc}"
}
trap cleanup EXIT INT TERM HUP

# ── Retry wrapper with exponential backoff ────────────────────────────────────
retry() {
  local max_attempts=$1; shift
  local attempt=1
  local delay=5
  while true; do
    if "$@"; then
      return 0
    fi
    if (( attempt >= max_attempts )); then
      log "retry: command failed after ${attempt} attempts: $*"
      return 1
    fi
    log "retry: attempt ${attempt} failed, sleeping ${delay}s..."
    sleep "${delay}"
    attempt=$(( attempt + 1 ))
    delay=$(( delay * 2 ))
  done
}

# ── Decode the PEM to a 0600 temp file ────────────────────────────────────────
# umask before mktemp = 0600 from creation (TOCTOU-free, see issue #49 pattern).
# #98 H1: prefer /dev/shm tmpfs so the PEM never touches persistent disk,
# falling back to the default tmp dir if /dev/shm is not writable.
PEM_FILE=$(umask 077; mktemp -p /dev/shm 2>/dev/null || mktemp)
( umask 077; printf '%s' "${GITHUB_APP_PEM_B64}" | base64 -d > "${PEM_FILE}" )
if [[ ! -s "${PEM_FILE}" ]]; then
  log "failed to decode GITHUB_APP_PEM_B64"
  exit 1
fi

# ── Authenticate to Azure via the attached user-assigned MI ───────────────────
log "authenticating to Azure via managed identity (client_id=${AZURE_CLIENT_ID})"
az login --identity --client-id "${AZURE_CLIENT_ID}" --output none
az account set --subscription "${AZURE_SUBSCRIPTION_ID}" --output none

# ── Compute GitHub API URLs based on scope ────────────────────────────────────
if [[ "${RUNNER_SCOPE}" == "repo" ]]; then
  : "${GITHUB_REPO:?GITHUB_REPO required when RUNNER_SCOPE=repo}"
  REGISTRATION_TOKEN_API_URL="https://api.github.com/repos/${GITHUB_ORG}/${GITHUB_REPO}/actions/runners/registration-token"
  REMOVE_TOKEN_API_URL="https://api.github.com/repos/${GITHUB_ORG}/${GITHUB_REPO}/actions/runners/remove-token"
  RUNNER_REGISTRATION_URL="https://github.com/${GITHUB_ORG}/${GITHUB_REPO}"
else
  REGISTRATION_TOKEN_API_URL="https://api.github.com/orgs/${GITHUB_ORG}/actions/runners/registration-token"
  REMOVE_TOKEN_API_URL="https://api.github.com/orgs/${GITHUB_ORG}/actions/runners/remove-token"
  RUNNER_REGISTRATION_URL="https://github.com/${GITHUB_ORG}"
fi
ACCESS_TOKEN_API_URL="${ACCESS_TOKEN_API_URL:-https://api.github.com/app/installations/${GITHUB_INSTALLATION_ID}/access_tokens}"

# ── Mint a GitHub App JWT (RS256, 10-min expiry) ──────────────────────────────
now=$(date +%s)
iat=$((now - 60))
exp=$((now + 600))

b64url() { openssl base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n'; }

header=$(printf '%s' '{"typ":"JWT","alg":"RS256"}' | b64url)
payload=$(printf '{"iat":%d,"exp":%d,"iss":%s}' "${iat}" "${exp}" "${GITHUB_APP_ID}" | b64url)
header_payload="${header}.${payload}"
signature=$(printf '%s' "${header_payload}" | openssl dgst -sha256 -sign "${PEM_FILE}" -binary | b64url)
jwt="${header_payload}.${signature}"

log "minted GitHub App JWT (exp in 10m)"

# ── Exchange JWT for an installation access token ─────────────────────────────
access_token=$(curl -fsSL -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${jwt}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "${ACCESS_TOKEN_API_URL}" | jq -r '.token')

# Clear the JWT immediately — registration+remove tokens are fetched below.
jwt=""
unset jwt

if [[ -z "${access_token}" || "${access_token}" == "null" ]]; then
  log "failed to obtain installation access token"
  exit 1
fi

# ── Fetch registration AND remove tokens up front (#60) ───────────────────────
# Both are fetched now so that the VM bootstrap can deregister on its own
# exit path (SIGKILL, crashed job, ACA scale-in) without needing the PEM.
log "fetching registration + remove tokens (scope=${RUNNER_SCOPE})"
registration_token=$(curl -fsSL -X POST \
  -H "Accept: application/vnd.github.v3+json" \
  -H "Authorization: Bearer ${access_token}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "${REGISTRATION_TOKEN_API_URL}" | jq -r '.token')

remove_token=$(curl -fsSL -X POST \
  -H "Accept: application/vnd.github.v3+json" \
  -H "Authorization: Bearer ${access_token}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "${REMOVE_TOKEN_API_URL}" | jq -r '.token')

# Access token no longer needed; clear it before touching ARM.
access_token=""
unset access_token

if [[ -z "${registration_token}" || "${registration_token}" == "null" \
   || -z "${remove_token}"       || "${remove_token}"       == "null" ]]; then
  log "failed to obtain registration or remove token"
  exit 1
fi

# ── Compute a unique VM name ──────────────────────────────────────────────────
# Must be DNS-safe, <= 15 chars for Windows (NetBIOS), lower for Linux too.
# Pattern: r-<os1><rand10>  → e.g. "r-l3f9a2b1c4d5" truncated to 15 chars.
os_prefix="${RUNNER_OS:0:1}"
rand_suffix=$(openssl rand -hex 5 | tr -d '\n')
INSTANCE_NAME="r-${os_prefix}${rand_suffix}"
INSTANCE_NAME="${INSTANCE_NAME:0:15}"
log "target VMSS instance name: ${INSTANCE_NAME}"

# ── Per-instance KV secret (issue #92) ────────────────────────────────────────
# KV secret names must match ^[0-9a-zA-Z-]{1,127}$. VMSS names already come
# lowercase-alnum-with-hyphens; instance names are r-<os><rand>; fold to that
# character class defensively (underscores, if ever introduced, → hyphens)
# and truncate to 127 chars. Writing the reg+remove tokens into Key Vault
# (instead of VMSS instance tags) keeps them out of IMDS — the VM has to
# use its UAMI to `az keyvault secret show` them, which is not reachable
# from an unprivileged process merely because it can read IMDS tags.
SECRET_NAME="runner-token-$(printf '%s-%s' "${VMSS_NAME}" "${INSTANCE_NAME}" \
  | tr '[:upper:]' '[:lower:]' \
  | tr '_' '-' \
  | tr -cd 'a-z0-9-')"
SECRET_NAME="${SECRET_NAME:0:127}"

# 4-hour expiry gives plenty of headroom for the VM to boot + bootstrap while
# capping the useful life of the secret contents even if the launcher crashes
# before its cleanup-trap delete (soft-deletion happens anyway, but `--expires`
# also caps usefulness of a leaked value if the VM fetches it and the attacker
# later steals it).
secret_expires="$(date -u -d '+4 hours' +%Y-%m-%dT%H:%M:%SZ)"
secret_value=$(jq -cn \
  --arg reg    "${registration_token}" \
  --arg remove "${remove_token}" \
  '{reg: $reg, remove: $remove}')

log "writing runner-token KV secret '${SECRET_NAME}' in vault '${KV_NAME}' (expires ${secret_expires})"
if ! az keyvault secret set \
    --vault-name "${KV_NAME}" \
    --name "${SECRET_NAME}" \
    --value "${secret_value}" \
    --expires "${secret_expires}" \
    --output none; then
  log "failed to write runner-token KV secret"
  exit 1
fi
SECRET_CREATED=1

# Clear the plaintext secret payload from shell memory now that KV has it.
secret_value=""
unset secret_value

# ── Build the PUT body ────────────────────────────────────────────────────────
# Tags carry the runner bootstrap inputs. Properties are left mostly empty so
# the VMSS profile (image, size, network, extensions) applies as-is; only
# osProfile.computerName is overridden to match the instance name for parity
# with the runner name recorded on GitHub.
#
# NOTE: we rely on the VMSS having `overprovision: false`, `upgradePolicy:
# Manual`, and (for flexible orchestration) `platformFaultDomainCount: 1`.
# Those are set in Bicep (Stream B).
umask 077
TMP_BODY=$(mktemp)

# #89: seed the lifecycle-state tags so the reaper has a well-defined view
# from VM-creation time (before the first job runs and before the
# job-completed hook — owned by #90 — starts updating these).
# The colon-style keys (`ghr:state`, `ghr:last-job-completed-at`,
# `ghr:job-count`) are intentional: they are a distinct runtime-state
# namespace from the camelCase config tags (`ghRunnerFoo`) so the reaper
# can enumerate them with a `startswith(ghr:)` query without confusing
# them with deploy-time config.
created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -n \
  --arg name        "${INSTANCE_NAME}" \
  --arg secretName  "${SECRET_NAME}" \
  --arg kvName      "${KV_NAME}" \
  --arg labels      "${RUNNER_LABELS}" \
  --arg url         "${RUNNER_REGISTRATION_URL}" \
  --arg os          "${RUNNER_OS}" \
  --arg scope       "${RUNNER_SCOPE}" \
  --arg idClientId  "${RUNNER_IDENTITY_CLIENT_ID}" \
  --arg idleMin     "${IDLE_RETENTION_MINUTES}" \
  --arg maxHours    "${MAX_LIFETIME_HOURS}" \
  --arg maxMinutes  "${MAX_LIFETIME_MINUTES}" \
  --arg createdAt   "${created_at}" \
  '{
    tags: {
      ghRunnerName:                 $name,
      ghRunnerTokenSecret:          $secretName,
      ghRunnerKvName:               $kvName,
      ghRunnerLabels:               $labels,
      ghRunnerUrl:                  $url,
      ghRunnerScope:                $scope,
      ghRunnerIdentityClientId:     $idClientId,
      ghRunnerOS:                   $os,
      ghRunnerIdleRetentionMinutes: $idleMin,
      ghRunnerMaxLifetimeHours:     $maxHours,
      ghRunnerMaxLifetimeMinutes:   $maxMinutes,
      "ghr:state":                  "idle",
      "ghr:last-job-completed-at":  $createdAt,
      "ghr:job-count":              "0"
    },
    properties: {
      osProfile: {
        computerName: $name
      }
    }
  }' > "${TMP_BODY}"

# Wipe token vars — they are now in KV, and the PUT body no longer carries them.
registration_token=""
remove_token=""
unset registration_token remove_token

# ── Create the VMSS instance ──────────────────────────────────────────────────
PUT_URL="https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Compute/virtualMachineScaleSets/${VMSS_NAME}/virtualMachines/${INSTANCE_NAME}?api-version=${API_VERSION}"

create_via_rest() {
  az rest \
    --method PUT \
    --url "${PUT_URL}" \
    --body "@${TMP_BODY}" \
    --headers "Content-Type=application/json" \
    --output none
}

create_via_scale_fallback() {
  # Fallback path for control planes that reject the single-instance PUT with
  # HTTP 405. We increment capacity by 1 and then identify the newest
  # instance. Note: this loses the ability to name the VM in advance, so we
  # discover the name after the fact and re-stamp tags via PATCH.
  #
  # Flex-mode VMSS: `az vmss list-instances` returns `timeCreated: null`
  # for Flexible orchestration, so we cannot sort by it. Instead, capture
  # the set of existing instance IDs BEFORE scaling and diff them against
  # the set AFTER — the new instance is the one not present before.
  log "fallback: scaling VMSS '${VMSS_NAME}' by +1 capacity"
  local before_ids
  before_ids=$(az vmss list-instances \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${VMSS_NAME}" \
    --query "[].id" --output tsv | sort)

  local current
  current=$(az vmss show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${VMSS_NAME}" \
    --query "sku.capacity" --output tsv)
  az vmss scale \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${VMSS_NAME}" \
    --new-capacity $((current + 1)) \
    --output none

  local after_json
  after_json=$(az vmss list-instances \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${VMSS_NAME}" \
    --query "[].{name:name,id:id}" --output json)

  # Find entries whose id is not in the pre-scale set.
  local new_entry
  new_entry=$(jq --argjson before "$(printf '%s\n' "${before_ids}" | jq -R . | jq -s .)" \
    '[.[] | select(.id as $i | ($before | index($i)) | not)] | .[0] // empty' \
    <<< "${after_json}")

  INSTANCE_NAME=$(jq -r '.name // empty' <<< "${new_entry}")
  local instance_id
  instance_id=$(jq -r '.id // empty' <<< "${new_entry}")

  if [[ -z "${INSTANCE_NAME}" || -z "${instance_id}" || "${instance_id}" == "null" ]]; then
    log "fallback: could not identify newest instance after scale"
    return 1
  fi
  log "fallback: newest instance is '${INSTANCE_NAME}' (id=${instance_id}); patching tags"

  # PATCH tags onto the scaled-up instance so the bootstrap can find them.
  #
  # `az vmss list-instances` returns an id of the form
  #   /providers/Microsoft.Compute/virtualMachineScaleSets/{vmss}/virtualMachines/{instance}
  # which is a READ-ONLY projection. On Flexible VMSS the same VM also
  # exists as a first-class Microsoft.Compute/virtualMachines resource,
  # and THAT is the URI that supports PATCH (tags). Uniform VMSS does
  # not take this code path — the PUT-body path already sets tags on
  # create — so we always construct the Compute/virtualMachines URI for
  # the PATCH regardless of orchestration mode.
  local vm_resource_id="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Compute/virtualMachines/${INSTANCE_NAME}"
  local patch_body
  patch_body=$(mktemp)
  jq --arg name "${INSTANCE_NAME}" '{tags: (.tags + {ghRunnerName: $name})}' \
    "${TMP_BODY}" > "${patch_body}"
  az rest \
    --method PATCH \
    --url "https://management.azure.com${vm_resource_id}?api-version=${API_VERSION}" \
    --body "@${patch_body}" \
    --headers "Content-Type=application/json" \
    --output none
  local patch_rc=$?
  shred -u "${patch_body}" 2>/dev/null || rm -f "${patch_body}" || true

  # Expose the Flex-native GET/PATCH URL for subsequent verification and
  # polling. Must target Microsoft.Compute/virtualMachines (not the
  # VMSS-child projection) so PATCH + provisioningState polling work.
  INSTANCE_URL="https://management.azure.com${vm_resource_id}?api-version=${API_VERSION}"
  return "${patch_rc}"
}

log "creating VMSS instance '${INSTANCE_NAME}' via PUT (api-version=${API_VERSION})"
create_stderr=$(mktemp)
if ! az rest \
    --method PUT \
    --url "${PUT_URL}" \
    --body "@${TMP_BODY}" \
    --headers "Content-Type=application/json" \
    --output none 2> "${create_stderr}"; then
  err=$(cat "${create_stderr}" || true)
  rm -f "${create_stderr}"
  log "single-instance PUT failed"
  if grep -qiE 'method not allowed|MethodNotAllowed|405|Uniform orchestration mode|non-negative integer' <<< "${err}"; then
    log "control plane rejected single-instance create (likely Flexible VMSS); falling back to az vmss scale"
    if ! retry 3 create_via_scale_fallback; then
      log "fallback VMSS scale-up failed"
      exit 1
    fi
  else
    # Transient — retry the PUT a couple of times before giving up.
    if ! retry 3 create_via_rest; then
      log "single-instance PUT failed after retries"
      exit 1
    fi
  fi
else
  rm -f "${create_stderr}"
fi
INSTANCE_CREATED=1
log "VMSS instance '${INSTANCE_NAME}' create accepted; polling provisioningState"

# ── #89: verify lifecycle tags landed on the instance ─────────────────────────
# Both create paths (PUT body and PATCH fallback) stamp ghRunnerIdleRetention‐
# Minutes / ghRunnerMaxLifetimeHours, but a post-create GET is the only way to
# confirm Azure actually recorded them before the VM bootstrap reads IMDS and
# fails loud. VMSS-level tags are NOT inherited to child VMs (issue #89), so
# if the jq block regresses or the fallback path skips them, the bootstrap
# will silently demote a warm runner to ephemeral. Fail fast here instead.
#
# INSTANCE_URL is set by the scale-fallback path using the instance's own
# ARM resource id (Flexible-compatible). Only default to the Uniform child
# path when the PUT path was used (Uniform VMSS); don't clobber fallback.
: "${INSTANCE_URL:=https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Compute/virtualMachineScaleSets/${VMSS_NAME}/virtualMachines/${INSTANCE_NAME}?api-version=${API_VERSION}}"

verify_lifecycle_tags() {
  local tags_json
  tags_json=$(az rest --method GET --url "${INSTANCE_URL}" --query "tags" --output json 2>/dev/null || echo 'null')
  # Verify config tags AND the #89 runtime-state seeds.
  # .["ghr:state"] etc. use bracket-quoted jq keys because the colon is not a
  # valid jq identifier character (unquoted .ghr:state would be parsed as
  # `.ghr` followed by a suffix and fail).
  if ! jq -e \
      --arg idle "${IDLE_RETENTION_MINUTES}" \
      --arg max  "${MAX_LIFETIME_HOURS}" \
      --arg maxm "${MAX_LIFETIME_MINUTES}" \
      '(.ghRunnerIdleRetentionMinutes // empty | tostring) == $idle
        and (.ghRunnerMaxLifetimeHours // empty | tostring) == $max
        and (.ghRunnerMaxLifetimeMinutes // empty | tostring) == $maxm
        and (.["ghr:state"] // empty) == "idle"
        and (.["ghr:job-count"] // empty | tostring) == "0"
        and ((.["ghr:last-job-completed-at"] // empty) | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' \
      <<< "${tags_json}" >/dev/null; then
    log "lifecycle-tag verification failed; instance tags='${tags_json}' expected idle=${IDLE_RETENTION_MINUTES} max=${MAX_LIFETIME_HOURS} maxMin=${MAX_LIFETIME_MINUTES} ghr:state=idle ghr:job-count=0 ghr:last-job-completed-at=<RFC3339>"
    return 1
  fi
  return 0
}

if ! retry 3 verify_lifecycle_tags; then
  log "instance '${INSTANCE_NAME}' is missing config lifecycle tags (ghRunnerIdleRetentionMinutes / ghRunnerMaxLifetimeHours / ghRunnerMaxLifetimeMinutes) and/or runtime-state seeds (ghr:state / ghr:last-job-completed-at / ghr:job-count); tearing down to prevent ephemeral demotion or warm-retention misbehaviour (see issue #89, issue #100)"
  exit 1
fi
log "lifecycle tags verified on '${INSTANCE_NAME}' (idle=${IDLE_RETENTION_MINUTES}m, max=${MAX_LIFETIME_HOURS}h, maxMin=${MAX_LIFETIME_MINUTES}m, ghr:state=idle, ghr:job-count=0, ghr:last-job-completed-at=${created_at})"

# Body file (with tokens) is no longer needed — remove eagerly.
shred -u "${TMP_BODY}" 2>/dev/null || rm -f "${TMP_BODY}" || true
TMP_BODY=""

# ── Poll provisioningState (bounded) ──────────────────────────────────────────
deadline=$(( $(date +%s) + PROVISION_TIMEOUT_SECONDS ))
while : ; do
  state=$(az rest \
    --method GET \
    --url "${INSTANCE_URL}" \
    --query "properties.provisioningState" --output tsv 2>/dev/null || echo "Unknown")

  log "  provisioningState=${state}"

  case "${state}" in
    Succeeded)
      log "VMSS instance '${INSTANCE_NAME}' provisioned successfully; exiting (fire-and-forget)"
      # Reset INSTANCE_CREATED so the cleanup trap does not delete the VM on
      # the success path (rc=0 would already short-circuit, but be explicit).
      INSTANCE_CREATED=0
      exit 0
      ;;
    Failed|Canceled)
      log "provisioning terminated with state=${state}"
      exit 1
      ;;
  esac

  if (( $(date +%s) >= deadline )); then
    log "provisioning did not reach Succeeded within ${PROVISION_TIMEOUT_SECONDS}s; giving up"
    exit 2
  fi
  sleep "${PROVISION_POLL_INTERVAL}"
done
