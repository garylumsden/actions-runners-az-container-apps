#!/usr/bin/env bash
# Attribution: JWT generation pattern from ethorneloe/azure-apps-jobs-github-runners (MIT)
# Adapted for org-scope runners, RUNNER_LABELS support, and base64-encoded PEM.
set -euo pipefail
# #98 H2: disable command history so any accidental `echo $GITHUB_APP_PEM_B64`
# or `set -x` trace later in this script cannot leave a plaintext copy of the
# decoded PEM or the GitHub tokens in $HISTFILE. Bash does not inherit parent
# HISTFILE in a non-interactive shell, but this is belt-and-braces.
set +o history

# Decode the base64-encoded PEM and write to a temp file.
# Using a file avoids shell quoting issues with multi-line PEM content.
# umask 077 before mktemp ensures the file is created with 0600 perms from the
# start, eliminating the chmod TOCTOU window where another process could open
# the newly-created file before its mode is tightened.
# #98 H1: prefer tmpfs (/dev/shm) so the PEM never touches persistent disk
# even transiently; fall back to the default tmp dir if /dev/shm is not
# writable (some constrained ACA profiles remount it ro).
PEM_FILE=$(umask 077; mktemp -p /dev/shm 2>/dev/null || mktemp)

# State used by the signal/exit handlers (#49, #60).
RUNNER_PID=0
REMOVE_TOKEN=""
DEREGISTERED=0

cleanup_pem() {
  # Defense-in-depth: shred the PEM if coreutils is available, otherwise plain rm.
  # Runs on normal exit AND on SIGINT/SIGTERM/SIGHUP so an abnormal termination
  # (e.g. ACA replicaTimeout sending SIGTERM) doesn't leave the key on disk.
  if [ -f "${PEM_FILE}" ]; then
    shred -u "${PEM_FILE}" 2>/dev/null || rm -f "${PEM_FILE}"
  fi
}

cleanup_runner() {
  # Explicit deregistration (#60). --ephemeral normally removes the runner
  # after one job, but SIGKILL / ACA force-stop leaves it registered on
  # GitHub for up to 24h. Calling ./config.sh remove on every exit path is
  # defence in depth. REMOVE_TOKEN is fetched up-front so we don't need
  # another JWT round-trip from inside a signal handler.
  if [[ "${DEREGISTERED}" -eq 0 ]] && [[ -n "${REMOVE_TOKEN}" ]] && [[ -x ./config.sh ]]; then
    DEREGISTERED=1
    ./config.sh remove --token "${REMOVE_TOKEN}" || true
  fi
}

on_exit() {
  local rc=$?
  cleanup_runner
  cleanup_pem
  exit "${rc}"
}

# Forward SIGTERM/SIGINT to the runner process so it can gracefully finish
# the in-flight job instead of being SIGKILLed by the init shell (#49).
# Without this, ACA scale-in signals the entrypoint shell and the runner
# child gets killed mid-job and stays registered on GitHub.
forward_signal() {
  local sig=$1
  if [[ "${RUNNER_PID}" -ne 0 ]] && kill -0 "${RUNNER_PID}" 2>/dev/null; then
    kill -"${sig}" "${RUNNER_PID}" 2>/dev/null || true
    # Block until the runner exits so the EXIT trap (which deregisters)
    # runs only after the runner has released its session on GitHub.
    wait "${RUNNER_PID}" 2>/dev/null || true
  fi
}

trap on_exit EXIT HUP
trap 'forward_signal TERM' TERM
trap 'forward_signal INT'  INT
# Write the decoded PEM under umask 077 so the contents land in the already
# 0600-permissioned file without a separate chmod step (TOCTOU-free).
( umask 077; printf '%s' "${GITHUB_APP_PEM_B64}" | base64 -d > "${PEM_FILE}" )

# ── JWT generation ────────────────────────────────────────────────────────────
now=$(date +%s)
iat=$((now - 60))   # issued 60s in the past to account for clock skew
exp=$((now + 600))  # 10-minute expiry

b64enc() { openssl base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n'; }

header=$(echo -n '{"typ":"JWT","alg":"RS256"}' | b64enc)
payload=$(echo -n "{\"iat\":${iat},\"exp\":${exp},\"iss\":${GITHUB_APP_ID}}" | b64enc)
header_payload="${header}.${payload}"
signature=$(openssl dgst -sha256 -sign "${PEM_FILE}" <(echo -n "${header_payload}") | b64enc)
jwt="${header_payload}.${signature}"

# ── Exchange JWT for an installation access token ─────────────────────────────
access_token=$(curl -fsSL -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${jwt}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "${ACCESS_TOKEN_API_URL}" | jq -r '.token')

# ── Get a short-lived runner registration token ───────────────────────────────
registration_token=$(curl -fsSL -X POST \
  -H "Accept: application/vnd.github.v3+json" \
  -H "Authorization: Bearer ${access_token}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "${REGISTRATION_TOKEN_API_URL}" | jq -r '.token')

# ── Get a short-lived runner *remove* (deregistration) token ──────────────────
# The remove-token endpoint mirrors registration-token, only the trailing path
# segment differs. Fetching it now (while we still have the installation
# access token) means the EXIT trap can deregister without another JWT round
# trip — important because the trap may run under signal/timeout conditions.
remove_token_url="${REGISTRATION_TOKEN_API_URL/registration-token/remove-token}"
REMOVE_TOKEN=$(curl -fsSL -X POST \
  -H "Accept: application/vnd.github.v3+json" \
  -H "Authorization: Bearer ${access_token}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "${remove_token_url}" | jq -r '.token')

# ── Scrub sensitive material from the environment ─────────────────────────────
# The base64 PEM would otherwise be inherited by every user workflow step,
# which is a trivial exfiltration vector for a malicious action. Tokens and
# the JWT are also cleared so they can't leak into child processes or logs.
unset GITHUB_APP_PEM_B64
jwt=""
unset jwt

# ── Register and run the ephemeral runner ─────────────────────────────────────
# --ephemeral: runner deregisters after completing exactly one job.
# --disableupdate: pinned to the image version; avoids unexpected self-updates.
./config.sh \
  --url "${RUNNER_REGISTRATION_URL}" \
  --token "${registration_token}" \
  --labels "${RUNNER_LABELS:-self-hosted,linux,aca}" \
  --unattended \
  --ephemeral \
  --disableupdate

# Clear the registration token now that config.sh has consumed it, then run.
registration_token=""
access_token=""
unset registration_token access_token

# Run the runner as a background child so trapped signals can be forwarded
# to it (#49). `wait $pid` returns either the runner's exit status, or
# 128+signo when interrupted by a trapped signal — the signal handler
# forwards the signal and itself waits for the runner to exit, so by the
# time control returns here the child has already been reaped.
./run.sh &
RUNNER_PID=$!
set +e
wait "${RUNNER_PID}"
rc=$?
set -e
exit "${rc}"
