#!/usr/bin/env bash
#
# Cross-build V8 d8 for riscv32-linux-gnu.
#
# Prereqs:
#   * scripts/fetch-sources.sh --only-v8        (or full fetch)
#   * scripts/apply-patches.sh                  (V8 patches applied)
#   * scripts/build-sysroot.sh                  (toolchain/sysroot/ exists)
#
# Outputs:
#   build/m1-v8-d8/d8
#   build/m1-v8-d8/snapshot_blob.bin
#   build/m1-v8-d8/icudtl.dat                  (if i18n enabled)

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${HERE}/env.sh"

V8="${SRC_DIR}/v8"
OUT="${BUILD_DIR}/m1-v8-d8"
ARGS_SRC="${PROJECT_ROOT}/configs/gn/v8-d8.args.gn"

[ -d "${V8}" ]       || { echo "missing ${V8}; run scripts/fetch-sources.sh"; exit 1; }
[ -d "${SYSROOT}" ]  || { echo "missing ${SYSROOT}; run scripts/build-sysroot.sh"; exit 1; }
[ -f "${ARGS_SRC}" ] || { echo "missing ${ARGS_SRC}"; exit 1; }

mkdir -p "${OUT}"

# Bundled Chromium clang doesn't ship a libclang_rt.builtins.a for
# riscv32-unknown-linux-gnu. We never actually need its symbols (we
# link with our own libgcc.a), but the clang driver still emits a
# -l<path> for it. Drop in an empty ar archive so the linker is happy.
CLANG_LIB_DIR="${V8}/third_party/llvm-build/Release+Asserts/lib/clang"
for vdir in "${CLANG_LIB_DIR}/"*/; do
    [ -d "${vdir}lib" ] || continue
    STUB_DIR="${vdir}lib/riscv32-unknown-linux-gnu"
    mkdir -p "${STUB_DIR}"
    if [ ! -s "${STUB_DIR}/libclang_rt.builtins.a" ]; then
        printf '!<arch>\n' > "${STUB_DIR}/libclang_rt.builtins.a"
        echo ">>> created stub ${STUB_DIR}/libclang_rt.builtins.a"
    fi
done

# Substitute the absolute sysroot path into the args.gn template.
sed "s|TO_BE_REPLACED_WITH_ABSOLUTE_SYSROOT_PATH|${SYSROOT}|" "${ARGS_SRC}" \
    > "${OUT}/args.gn"

echo ">>> args.gn:"
cat "${OUT}/args.gn"
echo

cd "${V8}"
echo ">>> gn gen"
gn gen "${OUT}" --root="${V8}"

echo ">>> ninja d8"
ninja -C "${OUT}" d8

echo
echo ">>> built d8:"
ls -la "${OUT}/d8"
file "${OUT}/d8" || true
echo
echo ">>> next: scripts/build-guest.sh (which will bake d8 into the rootfs)"
