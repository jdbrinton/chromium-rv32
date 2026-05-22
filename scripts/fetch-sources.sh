#!/usr/bin/env bash
#
# Fetch and pin all upstream source trees needed by the rest of the
# build pipeline:
#
#   1. depot_tools     -> src/depot_tools/
#   2. V8 standalone   -> src/v8/         (pinned to V8_PIN_SHA)
#   3. Chromium tree   -> src/chromium/   (pinned to CHROMIUM_PIN_TAG by 85-step)
#
# Steps 2 and 3 are independently skippable via flags so a fresh clone
# can be brought up to "build d8" without burning the bandwidth on the
# 80-100 GB Chromium fetch.
#
# Usage:
#   scripts/fetch-sources.sh              # all three steps
#   scripts/fetch-sources.sh --no-chromium # skip the Chromium fetch
#   scripts/fetch-sources.sh --only-depot-tools
#
# The pinned SHAs are kept in this file as variables; they are also
# documented in docs/build.md.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${HERE}/env.sh"

# ---------------------------------------------------------------------------
# Pins. Update these in lock-step with patches/ when rolling forward.
# ---------------------------------------------------------------------------
V8_PIN_SHA="637ded7fab21c745f197b071dc63ac19cff74ee3"     # last commit before
                                                          # RV32 deprecation
# Chromium tip is pinned by tagging whatever HEAD `fetch chromium`
# returned when we ran it; that SHA is recorded in
# docs/build.md and as a tag locally.

WANT_DEPOT_TOOLS=1
WANT_V8=1
WANT_CHROMIUM=1
PIN_CHROMIUM=1

while [ $# -gt 0 ]; do
    case "$1" in
        --no-depot-tools)    WANT_DEPOT_TOOLS=0 ;;
        --no-v8)             WANT_V8=0 ;;
        --no-chromium)       WANT_CHROMIUM=0 ;;
        --no-pin-chromium)   PIN_CHROMIUM=0 ;;
        --only-depot-tools)  WANT_V8=0; WANT_CHROMIUM=0 ;;
        --only-v8)           WANT_CHROMIUM=0 ;;
        --only-chromium)     WANT_V8=0 ;;
        -h|--help)
            sed -n '3,30p' "$0"
            exit 0
            ;;
        *)
            echo "unknown arg: $1" >&2
            exit 1
            ;;
    esac
    shift
done

mkdir -p "${SRC_DIR}"

# ---------------------------------------------------------------------------
# 1) depot_tools
# ---------------------------------------------------------------------------
if [ "${WANT_DEPOT_TOOLS}" = 1 ]; then
    if [ ! -d "${SRC_DIR}/depot_tools/.git" ]; then
        echo ">>> cloning depot_tools -> ${SRC_DIR}/depot_tools"
        git clone --depth=1 https://chromium.googlesource.com/chromium/tools/depot_tools.git \
            "${SRC_DIR}/depot_tools"
    else
        echo ">>> depot_tools already present (skipping clone)"
    fi
    # Make sure gclient is importable.
    "${SRC_DIR}/depot_tools/gclient" --version >/dev/null
    echo ">>> depot_tools ready"
fi

# Re-source env now that depot_tools may exist.
. "${HERE}/env.sh" >/dev/null

# ---------------------------------------------------------------------------
# 2) V8 (standalone, pinned via --no-history + git checkout)
# ---------------------------------------------------------------------------
if [ "${WANT_V8}" = 1 ]; then
    cd "${SRC_DIR}"
    if [ ! -d "${SRC_DIR}/v8" ]; then
        echo ">>> fetching v8 (15-45 minutes; --no-history shallow)"
        fetch --no-history v8
    else
        echo ">>> v8 checkout already present (skipping initial fetch)"
    fi
    cd "${SRC_DIR}/v8"

    HEAD_SHA="$(git rev-parse HEAD)"
    if [ "${HEAD_SHA}" != "${V8_PIN_SHA}" ]; then
        echo ">>> deepening v8 to reach pin ${V8_PIN_SHA}"
        # `fetch --no-history` produces depth=1 — we need history back to
        # the pin SHA. `git fetch --unshallow` plus an explicit checkout
        # of the pin SHA does the trick.
        git fetch --unshallow origin 2>/dev/null || git fetch origin
        git checkout "${V8_PIN_SHA}"
    fi
    echo ">>> v8 pinned at: $(git rev-parse HEAD)"
    echo ">>>   $(git log -1 --format='%ci %s')"
fi

# ---------------------------------------------------------------------------
# 3) Chromium (big; pinnable separately)
# ---------------------------------------------------------------------------
if [ "${WANT_CHROMIUM}" = 1 ]; then
    CHROMIUM_DIR="${SRC_DIR}/chromium"
    mkdir -p "${CHROMIUM_DIR}"

    if [ ! -d "${CHROMIUM_DIR}/src/.git" ]; then
        cd "${CHROMIUM_DIR}"
        echo ">>> fetching chromium (1-3 hours; ~80-100 GB)"
        echo "    flags: --no-history --nohooks"
        fetch --no-history --nohooks chromium
    else
        echo ">>> chromium tree already present at ${CHROMIUM_DIR}/src (skipping fetch)"
    fi

    if [ "${PIN_CHROMIUM}" = 1 ]; then
        cd "${CHROMIUM_DIR}/src"
        SHA="$(git rev-parse HEAD)"
        SHORT="$(git rev-parse --short HEAD)"
        TAG="chromium-rv32/pinned-${SHORT}"
        echo ">>> tagging Chromium HEAD as ${TAG}"
        git tag -f "${TAG}" >/dev/null

        BUNDLE_DIR="${PROJECT_ROOT}/toolchain/bundles"
        mkdir -p "${BUNDLE_DIR}"
        BUNDLE="${BUNDLE_DIR}/chromium-${SHORT}.bundle"
        echo ">>> snapshot bundle -> ${BUNDLE}"
        git bundle create "${BUNDLE}" "${TAG}" >/dev/null

        echo ">>> chromium pinned"
        echo "    sha:    ${SHA}"
        echo "    tag:    ${TAG}"
        echo "    bundle: ${BUNDLE}"
    fi
fi

echo
echo ">>> sources ready. next: scripts/apply-patches.sh"
