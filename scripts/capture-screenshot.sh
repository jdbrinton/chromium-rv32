#!/usr/bin/env bash
#
# Thin wrapper around tools/capture-screenshot.py, mostly so the
# end-to-end documented sequence in docs/build.md is symmetrical with
# the other scripts/* helpers.
#
# Usage:
#   scripts/capture-screenshot.sh [DEST_PNG]
#
# Defaults DEST_PNG to artifacts/runs/m6-<timestamp>.png. The script
# assumes scripts/run-guest.sh --svelte-host URL is *already running*
# in another shell (i.e. content_shell has come up and the CDP endpoint
# is reachable on 127.0.0.1:9222).

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${HERE}/env.sh"

ts=$(date +%Y%m%d-%H%M%S)
DEFAULT_OUT="${PROJECT_ROOT}/artifacts/runs/m6-${ts}.png"
OUT="${1:-${DEFAULT_OUT}}"
mkdir -p "$(dirname "${OUT}")"

echo ">>> capturing screenshot via CDP -> ${OUT}"
python3 -u "${PROJECT_ROOT}/tools/capture-screenshot.py" \
    --output "${OUT}" \
    --cdp-host 127.0.0.1 \
    --cdp-port 9222 \
    --connect-timeout 240 \
    --allgreen-timeout 240

ls -lh "${OUT}"
echo ">>> done"
