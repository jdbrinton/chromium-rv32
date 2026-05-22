#!/usr/bin/env bash
#
# Cross-build Chromium content_shell for riscv32-linux-gnu.
#
# Prereqs:
#   * scripts/fetch-sources.sh                  (Chromium tree + depot_tools)
#   * scripts/apply-patches.sh                  (Chromium patches applied)
#   * scripts/build-sysroot.sh                  (toolchain/sysroot/ exists)
#
# Outputs:
#   build/m4-content-shell/content_shell        (~80 MB ELF)
#   build/m4-content-shell/lib*.so              (~400 .so closure)
#   build/m4-content-shell/*.pak                (Chromium resource paks)

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${HERE}/env.sh"

CHROMIUM_SRC="${SRC_DIR}/chromium/src"
OUT="${BUILD_DIR}/m4-content-shell"
ARGS_SRC="${PROJECT_ROOT}/configs/gn/content-shell.args.gn"

[ -d "${CHROMIUM_SRC}" ] || { echo "missing ${CHROMIUM_SRC}; run scripts/fetch-sources.sh"; exit 1; }
[ -d "${SYSROOT}" ]      || { echo "missing ${SYSROOT}; run scripts/build-sysroot.sh"; exit 1; }
[ -f "${ARGS_SRC}" ]     || { echo "missing ${ARGS_SRC}"; exit 1; }

mkdir -p "${OUT}"

sed "s|TO_BE_REPLACED_WITH_ABSOLUTE_SYSROOT_PATH|${SYSROOT}|" "${ARGS_SRC}" \
    > "${OUT}/args.gn"

echo ">>> args.gn:"
cat "${OUT}/args.gn"
echo

cd "${CHROMIUM_SRC}"
echo ">>> gn gen ${OUT}"
gn gen "${OUT}" --root="${CHROMIUM_SRC}"

echo ">>> ninja content_shell (this can take 30-90 minutes on first build)"
ninja -C "${OUT}" content_shell

echo
echo ">>> built content_shell:"
ls -la "${OUT}/content_shell"
file "${OUT}/content_shell" || true
echo
echo ">>> next: scripts/install-content-shell-in-rootfs.sh"
echo "         (packages the ELF + .so closure into chromium-rootfs.ext4 +"
echo "          drops a launcher into the staged-rootfs overlay)"
