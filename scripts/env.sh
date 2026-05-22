#!/usr/bin/env bash
# Source me, don't execute me.
#
# Exports the canonical paths used by every other script in this repo:
#
#   PROJECT_ROOT   — absolute path to the chromium-rv32 repo root.
#   SRC_DIR        — $PROJECT_ROOT/src/ (depot_tools + V8 + Chromium checkouts).
#   BUILD_DIR      — $PROJECT_ROOT/build/ (out-of-tree gn/ninja outputs).
#   SYSROOT        — $PROJECT_ROOT/toolchain/sysroot/ (rv32 sysroot mirror).
#   BR2_EXTERNAL   — $PROJECT_ROOT/configs/buildroot/ (BR2_EXTERNAL tree).
#
# Also prepends depot_tools to PATH if SRC_DIR/depot_tools exists.

# shellcheck disable=SC2155
export PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRC_DIR="${PROJECT_ROOT}/src"
export BUILD_DIR="${PROJECT_ROOT}/build"
export SYSROOT="${PROJECT_ROOT}/toolchain/sysroot"
export BR2_EXTERNAL="${PROJECT_ROOT}/configs/buildroot"
export CHROMIUM_RV32_CCACHE_DIR="${PROJECT_ROOT}/ccache"

if [ -d "${SRC_DIR}/depot_tools" ]; then
    case ":$PATH:" in
        *":${SRC_DIR}/depot_tools:"*) ;;
        *) PATH="${SRC_DIR}/depot_tools:$PATH" ;;
    esac
fi

# depot_tools is allergic to self-updating in air-gapped / pinned mode.
export DEPOT_TOOLS_UPDATE=0

if command -v ccache >/dev/null 2>&1; then
    export CCACHE_DIR="${CHROMIUM_RV32_CCACHE_DIR}"
fi

export PATH

if [ "${CHROMIUM_RV32_ENV_QUIET:-0}" != "1" ]; then
    echo "chromium-rv32 env active"
    echo "  PROJECT_ROOT=${PROJECT_ROOT}"
    echo "  SRC_DIR=${SRC_DIR}"
    echo "  BUILD_DIR=${BUILD_DIR}"
    echo "  SYSROOT=${SYSROOT}"
    echo "  BR2_EXTERNAL=${BR2_EXTERNAL}"
    command -v gn       >/dev/null && echo "  gn:    $(command -v gn)"
    command -v ninja    >/dev/null && echo "  ninja: $(command -v ninja)"
    command -v fetch    >/dev/null && echo "  fetch: $(command -v fetch)"
fi
true
