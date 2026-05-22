#!/usr/bin/env bash
#
# Build a riscv32-linux-gnu sysroot (glibc + libstdc++ + common libs)
# from Buildroot. Mirrors the resulting tree into toolchain/sysroot/
# and copies the gcc-runtime crt*.o / libgcc.a / libatomic.* under
# toolchain/sysroot/usr/lib/ where Chromium's `-nostdlib` link line
# expects to find them.
#
# Outputs:
#   toolchain/buildroot/                          (Buildroot source + build)
#   toolchain/sysroot/                            (rsync'd sysroot mirror)
#   toolchain/host-bin/riscv32-buildroot-linux-gnu-*  (cross binary symlinks)
#   toolchain/triple.txt                          (cross-triple name)

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${HERE}/env.sh"

BUILDROOT_VER="2026.02.1"
BUILDROOT_DIR="${PROJECT_ROOT}/toolchain/buildroot"
BUILDROOT_TARBALL="${PROJECT_ROOT}/toolchain/buildroot-${BUILDROOT_VER}.tar.xz"
BUILDROOT_URL="https://buildroot.org/downloads/buildroot-${BUILDROOT_VER}.tar.xz"

mkdir -p "${PROJECT_ROOT}/toolchain"

if [ ! -d "${BUILDROOT_DIR}" ]; then
    if [ ! -f "${BUILDROOT_TARBALL}" ]; then
        echo ">>> downloading buildroot ${BUILDROOT_VER}"
        curl -fL -o "${BUILDROOT_TARBALL}" "${BUILDROOT_URL}"
    fi
    echo ">>> extracting buildroot"
    tar xJf "${BUILDROOT_TARBALL}" -C "${PROJECT_ROOT}/toolchain"
    mv "${PROJECT_ROOT}/toolchain/buildroot-${BUILDROOT_VER}" "${BUILDROOT_DIR}"
fi

DEFCONFIG_SRC="${BR2_EXTERNAL}/configs/rv32_sysroot_defconfig"
[ -f "${DEFCONFIG_SRC}" ] || {
    echo "error: missing ${DEFCONFIG_SRC}" >&2
    exit 1
}

# Buildroot reads defconfigs from <buildroot>/configs/ or from the
# BR2_EXTERNAL/configs/ directory. We put it in both places to be safe
# across Buildroot versions.
mkdir -p "${BUILDROOT_DIR}/configs"
cp "${DEFCONFIG_SRC}" "${BUILDROOT_DIR}/configs/rv32_sysroot_defconfig"

echo ">>> applying rv32_sysroot_defconfig"
make -C "${BUILDROOT_DIR}" \
    BR2_EXTERNAL="${BR2_EXTERNAL}" \
    rv32_sysroot_defconfig

echo ">>> building sysroot (slow first time, fast on re-run)"
make -C "${BUILDROOT_DIR}" \
    BR2_EXTERNAL="${BR2_EXTERNAL}" \
    -j"$(nproc)"

SYS_INNER="$(find "${BUILDROOT_DIR}/output/host" -maxdepth 4 -type d -name sysroot | head -1)"
[ -n "${SYS_INNER}" ] || {
    echo "error: could not find buildroot sysroot" >&2
    exit 1
}
echo ">>> buildroot sysroot: ${SYS_INNER}"

mkdir -p "${PROJECT_ROOT}/toolchain/sysroot"
rsync -a --delete "${SYS_INNER}/" "${PROJECT_ROOT}/toolchain/sysroot/"
echo ">>> mirrored to ${PROJECT_ROOT}/toolchain/sysroot/"

mkdir -p "${PROJECT_ROOT}/toolchain/host-bin"
for f in "${BUILDROOT_DIR}/output/host/bin/"riscv32-*; do
    [ -e "$f" ] || continue
    ln -sfn "$f" "${PROJECT_ROOT}/toolchain/host-bin/$(basename "$f")"
done
echo ">>> linked riscv32-* binaries into ${PROJECT_ROOT}/toolchain/host-bin/"

TRIPLE="$(basename "$(dirname "${SYS_INNER}")")"
echo "${TRIPLE}" > "${PROJECT_ROOT}/toolchain/triple.txt"
echo ">>> cross triple: ${TRIPLE}"

# --- post-step: copy gcc-runtime artifacts Chromium's link line wants ---
GCC_DIR=$(echo "${BUILDROOT_DIR}/output/host/lib/gcc/${TRIPLE}/"*)
DST="${PROJECT_ROOT}/toolchain/sysroot/usr/lib"
mkdir -p "${DST}"
echo ">>> copying gcc runtime objects from ${GCC_DIR}"
for f in crtbegin crtbeginS crtbeginT crtend crtendS; do
    cp -f "${GCC_DIR}/${f}.o" "${DST}/"
done
cp -f "${GCC_DIR}/libgcc.a" "${DST}/"

BR_SYSLIB="${BUILDROOT_DIR}/output/host/${TRIPLE}/sysroot/lib"
echo ">>> copying libatomic from ${BR_SYSLIB}"
cp -f "${BR_SYSLIB}/libatomic."* "${DST}/" || true

echo ">>> sysroot ready (crt*, libgcc.a, libatomic.* present in ${DST})"
echo ">>> next: scripts/build-v8-d8.sh"
