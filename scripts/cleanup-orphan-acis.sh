#!/usr/bin/env bash
# Manually reap orphan Windows ACI runner groups (aci-win-runner-*).
#
# This is a companion to the scheduled GC workflow
# (.github/workflows/cleanup-orphan-acis.yml) and the launcher cleanup trap
# (docker/windows-launcher/entrypoint.sh). Use it to drain the existing
# orphan backlog after a launcher-cleanup bug, or as a manual override
# while the hourly workflow is still propagating.
#
# Usage:
#   scripts/cleanup-orphan-acis.sh [--dry-run|--yes] [--resource-group RG]
#
# Defaults:
#   - --dry-run  (never deletes unless --yes is passed explicitly)
#   - --resource-group falls back to $RESOURCE_GROUP env var
#
# The script deliberately does NOT use --no-wait and does NOT suppress
# stderr; it must fail loudly so any ARM/auth error is visible. This is
# the exact anti-pattern that produced the original orphan backlog.

set -euo pipefail

DRY_RUN=1
RESOURCE_GROUP="${RESOURCE_GROUP:-}"

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)        DRY_RUN=1; shift ;;
    --yes)            DRY_RUN=0; shift ;;
    --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    -h|--help)        usage 0 ;;
    *)                echo "Unknown argument: $1" >&2; usage 1 ;;
  esac
done

if [[ -z "${RESOURCE_GROUP}" ]]; then
  echo "Error: --resource-group not provided and \$RESOURCE_GROUP not set" >&2
  exit 1
fi

if ! command -v az >/dev/null 2>&1; then
  echo "Error: az CLI not on PATH" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq not on PATH" >&2
  exit 1
fi

echo "Resource group: ${RESOURCE_GROUP}"
echo "Mode:           $([[ ${DRY_RUN} -eq 1 ]] && echo 'DRY-RUN (no deletes)' || echo 'LIVE (will delete)')"
echo

GROUPS_JSON=$(az container list --resource-group "${RESOURCE_GROUP}" --output json)

ORPHANS=$(echo "${GROUPS_JSON}" | jq -c '
  [ .[]
    | select(.name | startswith("aci-win-runner-"))
    | {
        name:       .name,
        state:      (.containers[0].instanceView.currentState.state // "Unknown"),
        exitCode:   (.containers[0].instanceView.currentState.exitCode // null),
        finishTime: (.containers[0].instanceView.currentState.finishTime // ""),
        startTime:  (.containers[0].instanceView.currentState.startTime  // "")
      }
  ]')

COUNT=$(echo "${ORPHANS}" | jq 'length')
echo "Found ${COUNT} aci-win-runner-* group(s):"
echo "${ORPHANS}" | jq -r '.[] | "  - \(.name)  state=\(.state)  exit=\(.exitCode // "?")  finish=\(.finishTime)"'
echo

if [[ "${COUNT}" -eq 0 ]]; then
  echo "Nothing to do."
  exit 0
fi

NOW=$(date -u +%s)
to_epoch() { date -u -d "$1" +%s 2>/dev/null || echo 0; }

rc=0
# shellcheck disable=SC2034
while IFS= read -r row; do
  NAME=$(echo    "${row}" | jq -r '.name')
  FINISH=$(echo  "${row}" | jq -r '.finishTime')
  START=$(echo   "${row}" | jq -r '.startTime')
  TS="${FINISH:-$START}"
  if [[ -n "${TS}" ]]; then
    EPOCH=$(to_epoch "${TS}")
    AGE=$(( NOW - EPOCH ))
  else
    AGE="?"
  fi

  if [[ ${DRY_RUN} -eq 1 ]]; then
    echo "[dry-run] would delete ${NAME} (finish=${TS:-none}, age=${AGE}s)"
    continue
  fi

  echo "Deleting ${NAME} (finish=${TS:-none}, age=${AGE}s)..."
  # Blocking delete; no stderr suppression.
  if az container delete \
        --resource-group "${RESOURCE_GROUP}" \
        --name           "${NAME}" \
        --yes \
        --output none; then
    echo "  deleted ${NAME}"
  else
    echo "  ERROR: failed to delete ${NAME}" >&2
    rc=1
  fi
done < <(echo "${ORPHANS}" | jq -c '.[]')

if [[ ${DRY_RUN} -eq 1 ]]; then
  echo
  echo "Re-run with --yes to actually delete."
fi

exit "${rc}"
