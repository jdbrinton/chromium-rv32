#!/usr/bin/env bash
#
# Apply all chromium-rv32 patches to the corresponding source trees.
# Idempotent: a patch already applied is detected and skipped.
#
# Patch layout:
#   patches/v8/0001-chromium-rv32-cumulative.patch       -> src/v8/
#   patches/v8/0002-chromium-rv32-build-system.patch     -> src/v8/build/    (separate submodule)
#   patches/chromium/0001-chromium-rv32-chromium-side.patch        -> src/chromium/src/
#   patches/chromium/0002-chromium-rv32-third_party-angle.patch    -> src/chromium/src/third_party/angle/
#   patches/chromium/0002-chromium-rv32-third_party-lss.patch      -> src/chromium/src/third_party/lss/
#   patches/chromium/0002-chromium-rv32-third_party-swiftshader.patch -> src/chromium/src/third_party/swiftshader/
#   patches/chromium/0002-chromium-rv32-v8.patch         -> src/chromium/src/v8/
#   patches/buildroot/                                   -> currently empty

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${HERE}/env.sh"

apply_in() {
    local target_dir="$1"
    local patch_file="$2"
    [ -d "${target_dir}/.git" ] || {
        echo "    SKIP — no git checkout at ${target_dir}"
        return 0
    }
    (
        cd "${target_dir}"
        if git apply --check "${patch_file}" 2>/dev/null; then
            git apply "${patch_file}"
            echo "    applied in ${target_dir}"
        elif git apply --reverse --check "${patch_file}" 2>/dev/null; then
            echo "    already applied in ${target_dir}; skipping"
        else
            echo "    REFUSED in ${target_dir} (patch does not apply cleanly)"
            return 1
        fi
    )
}

apply_dir() {
    local patchdir="$1"
    shift
    local default_target="$1"
    shift

    if [ ! -d "${patchdir}" ] || [ -z "$(ls "${patchdir}"/*.patch 2>/dev/null || true)" ]; then
        echo ">>> ${patchdir}: no patches; skipping"
        return 0
    fi

    for p in "${patchdir}"/*.patch; do
        local name target_dir
        name="$(basename "${p}")"
        target_dir="${default_target}"

        # Per-patch routing (handled here instead of with a manifest
        # file so the layout stays self-describing).
        case "${name}" in
            0002-chromium-rv32-build-system.patch)
                target_dir="${SRC_DIR}/v8/build"
                ;;
            0002-chromium-rv32-third_party-angle.patch)
                target_dir="${SRC_DIR}/chromium/src/third_party/angle"
                ;;
            0002-chromium-rv32-third_party-lss.patch)
                target_dir="${SRC_DIR}/chromium/src/third_party/lss"
                ;;
            0002-chromium-rv32-third_party-swiftshader.patch)
                target_dir="${SRC_DIR}/chromium/src/third_party/swiftshader"
                ;;
            0002-chromium-rv32-v8.patch)
                target_dir="${SRC_DIR}/chromium/src/v8"
                ;;
        esac

        echo ">>> ${name} -> ${target_dir}"
        apply_in "${target_dir}" "${p}" || return 1
    done
}

apply_dir "${PROJECT_ROOT}/patches/v8"        "${SRC_DIR}/v8"               || exit 1
apply_dir "${PROJECT_ROOT}/patches/chromium"  "${SRC_DIR}/chromium/src"     || exit 1
# patches/buildroot/ is currently empty; this is a placeholder so a
# future contributor can drop a patch there and have it picked up.
if [ -d "${PROJECT_ROOT}/patches/buildroot" ]; then
    for p in "${PROJECT_ROOT}/patches/buildroot/"*.patch; do
        [ -e "${p}" ] || continue
        echo "(buildroot patches are applied by Buildroot's own infrastructure"
        echo " inside the build directory; this script does nothing with them.)"
        break
    done
fi

echo ">>> patches applied"
