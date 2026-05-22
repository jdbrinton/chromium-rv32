#!/usr/bin/env bash
#
# Buildroot ROOTFS_POST_BUILD hook. Runs after target/ is fully
# populated but before the rootfs image is packed. We use it to drop
# the cross-built V8 d8 binary, its data files, and the canonical
# hello.js into /opt/v8/ inside the guest.
#
# TARGET_DIR is set by buildroot.

set -euo pipefail

# BR2_EXTERNAL_CHROMIUM_RV32_PATH points at configs/buildroot/ in this
# repo; the project root sits two levels above it.
PROJECT_ROOT="$(cd "${BR2_EXTERNAL_CHROMIUM_RV32_PATH}/../.." && pwd)"
BUILD="${PROJECT_ROOT}/build/m1-v8-d8"

if [ ! -x "${BUILD}/d8" ]; then
	echo "post-build: missing ${BUILD}/d8; build it via scripts/build-v8-d8.sh first" >&2
	exit 1
fi

echo "post-build: installing d8 into ${TARGET_DIR}/opt/v8/"
install -d "${TARGET_DIR}/opt/v8"
install -m 0755 "${BUILD}/d8"                 "${TARGET_DIR}/opt/v8/d8"
install -m 0644 "${BUILD}/snapshot_blob.bin"  "${TARGET_DIR}/opt/v8/snapshot_blob.bin"
if [ -f "${BUILD}/icudtl.dat" ]; then
	install -m 0644 "${BUILD}/icudtl.dat"     "${TARGET_DIR}/opt/v8/icudtl.dat"
fi
if [ -f "${PROJECT_ROOT}/configs/buildroot/board/rv32-d8/hello.js" ]; then
	install -m 0644 "${PROJECT_ROOT}/configs/buildroot/board/rv32-d8/hello.js" \
	                "${TARGET_DIR}/opt/v8/hello.js"
else
	cat > "${TARGET_DIR}/opt/v8/hello.js" <<'EOF'
print("hello, rv32 d8");
print("typeof Promise =", typeof Promise);
print("Math.sqrt(2) =", Math.sqrt(2));
EOF
fi

# A separate, slightly fancier acceptance script that the init unit
# below runs at boot.
install -m 0755 "${BR2_EXTERNAL_CHROMIUM_RV32_PATH}/board/rv32-d8/m2-acceptance.sh" \
                "${TARGET_DIR}/opt/v8/m2-acceptance.sh"

# Symlink /usr/local/bin/d8 -> /opt/v8/d8 so `d8` works without a full path.
install -d "${TARGET_DIR}/usr/local/bin"
ln -sf /opt/v8/d8 "${TARGET_DIR}/usr/local/bin/d8"

echo "post-build: done"
