#!/usr/bin/env bash
set -euo pipefail
LIFECYCLE_DIR="${LIFECYCLE_DIR:-/var/run/runner-lifecycle}"
mkdir -p "$LIFECYCLE_DIR"
touch "$LIFECYCLE_DIR/job-active"
