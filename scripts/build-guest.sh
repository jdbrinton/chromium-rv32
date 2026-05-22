#!/usr/bin/env bash
#
# Build a bootable RV32 Linux guest image (kernel + initramfs).
#
# Re-uses the Buildroot source tree already extracted by
# scripts/build-sysroot.sh, but with a separate output directory
# (toolchain/buildroot-guest/) so the sysroot mirror stays untouched.
#
# Outputs:
#   toolchain/buildroot-guest/output/images/Image
#   toolchain/buildroot-guest/output/images/fw_jump.bin
#   toolchain/buildroot-guest/output/images/rootfs.cpio.gz
#   toolchain/buildroot-guest/output/host/bin/qemu-system-riscv32
#   toolchain/buildroot-guest/output/host/bin/qemu-riscv32

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${HERE}/env.sh"

BUILDROOT_SRC="${PROJECT_ROOT}/toolchain/buildroot"
GUEST_OUT="${PROJECT_ROOT}/toolchain/buildroot-guest"

[ -d "${BUILDROOT_SRC}" ] || {
    echo "missing ${BUILDROOT_SRC}; run scripts/build-sysroot.sh first" >&2
    exit 1
}
[ -d "${BR2_EXTERNAL}" ] || { echo "missing ${BR2_EXTERNAL}"; exit 1; }
[ -x "${BUILD_DIR}/m1-v8-d8/d8" ] || {
    echo "missing ${BUILD_DIR}/m1-v8-d8/d8; run scripts/build-v8-d8.sh first" >&2
    exit 1
}

# The guest defconfig pulls in $(BR2_EXTERNAL)/staged-rootfs/ as the
# third overlay layer; create the directory empty if the content_shell
# install step has not been run yet. (Buildroot otherwise warns and
# leaves the overlay unsourced.)
mkdir -p "${BR2_EXTERNAL}/staged-rootfs"

mkdir -p "${GUEST_OUT}"

echo ">>> applying rv32_guest_defconfig"
make -C "${BUILDROOT_SRC}" \
    O="${GUEST_OUT}" \
    BR2_EXTERNAL="${BR2_EXTERNAL}" \
    rv32_guest_defconfig

echo ">>> building guest image (slow on the first run; subsequent runs reuse ccache + dl/)"
make -C "${BUILDROOT_SRC}" \
    O="${GUEST_OUT}" \
    BR2_EXTERNAL="${BR2_EXTERNAL}" \
    -j"$(nproc)"

echo
echo ">>> built images:"
ls -lh "${GUEST_OUT}/images/"
echo
echo ">>> qemu binaries:"
ls -lh "${GUEST_OUT}/host/bin/qemu-system-riscv32" "${GUEST_OUT}/host/bin/qemu-riscv32" 2>/dev/null
echo
echo ">>> next: scripts/run-guest.sh"
