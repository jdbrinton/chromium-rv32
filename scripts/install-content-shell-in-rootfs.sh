#!/usr/bin/env bash
#
# Stage content_shell + its runtime dependency closure for the rv32
# guest. The chromium payload is too large to fit in the rv32 Linux
# kernel's direct-mapped lowmem (~768 MB usable on qemu-system-riscv32
# sv32, regardless of the qemu -m value — the initramfs unpack hits
# "Initramfs unpacking failed: write error" once the tmpfs exceeds
# available lowmem). We therefore split the payload across two
# filesystems:
#
#   1) configs/buildroot/staged-rootfs/      (small cpio overlay)
#       - usr/local/bin/content_shell        (launcher wrapper)
#       - usr/local/chromium/.keep + README  (mountpoint stub)
#
#   2) build/chromium-rootfs.ext4            (separate ext4 disk)
#       - content_shell                       (rv32 PIE binary, stripped)
#       - chrome_crashpad_handler
#       - lib*.so                             (transitive NEEDED closure)
#       - libexpat.so.1                       (one external NEEDED)
#       - *.pak                               (Chromium resource bundles)
#       - test_fonts/                         (bundled fontconfig data)
#       - etc/fonts/fonts.conf                (fontconfig pointing at above)
#
# scripts/run-guest.sh attaches the ext4 to QEMU as a virtio-blk
# device; the in-guest /etc/init.d/S97-mount-chromium-rootfs mounts it
# at /usr/local/chromium before /etc/init.d/S98-run-content-shell-m5
# launches content_shell.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${HERE}/env.sh"

STAGE="${BR2_EXTERNAL}/staged-rootfs"
EXT4_OUT="${BUILD_DIR}/chromium-rootfs.ext4"
EXT4_WORK="${BUILD_DIR}/.chromium-ext4-staging"
BUILD="${BUILD_DIR}/m4-content-shell"
SVELTE_DIST="${PROJECT_ROOT}/demo/svelte/build"
SYSROOT_DIR="${PROJECT_ROOT}/toolchain/sysroot"

TC_BIN="${PROJECT_ROOT}/toolchain/buildroot/output/host/bin"
RE="${TC_BIN}/riscv32-buildroot-linux-gnu-readelf"
STRIP="${TC_BIN}/riscv32-buildroot-linux-gnu-strip"

[ -x "${BUILD}/content_shell" ] || {
    echo "missing ${BUILD}/content_shell; run scripts/build-content-shell.sh first" >&2
    exit 1
}
[ -x "${RE}" ]    || { echo "missing ${RE} (run scripts/build-sysroot.sh)"; exit 1; }
[ -x "${STRIP}" ] || { echo "missing ${STRIP} (run scripts/build-sysroot.sh)"; exit 1; }
command -v mke2fs >/dev/null || {
    echo "host mke2fs missing; please install e2fsprogs >= 1.43" >&2
    exit 1
}

echo ">>> staging cpio overlay tree:  ${STAGE}"
echo ">>> staging ext4 payload tree:  ${EXT4_WORK}"
rm -rf "${STAGE}" "${EXT4_WORK}"
mkdir -p "${STAGE}/usr/local/bin" \
         "${STAGE}/usr/local/chromium" \
         "${STAGE}/usr/local/share/svelte-demo" \
         "${EXT4_WORK}"

CHROOT="${EXT4_WORK}"

# --- Step 1: walk transitive NEEDED graph rooted at content_shell -----------

echo ">>> computing transitive NEEDED closure for content_shell"
CLOSURE_LIST="$(mktemp)"
EXTERNAL_LIST="$(mktemp)"
trap 'rm -f "${CLOSURE_LIST}" "${EXTERNAL_LIST}"' EXIT

RE="${RE}" BUILD="${BUILD}" python3 - "${CLOSURE_LIST}" "${EXTERNAL_LIST}" <<'PY'
import collections, os, subprocess, sys
build = os.environ['BUILD']
re_   = os.environ['RE']
cl_out, ex_out = sys.argv[1], sys.argv[2]

def needed(path):
    r = subprocess.run([re_, '-d', path], capture_output=True, text=True)
    out = []
    for line in r.stdout.splitlines():
        if '(NEEDED)' not in line: continue
        l = line.find('['); r2 = line.find(']')
        if l != -1 and r2 != -1: out.append(line[l+1:r2])
    return out

avail = {f for f in os.listdir(build) if f.endswith('.so')}
queue = collections.deque([os.path.join(build, 'content_shell'),
                           os.path.join(build, 'chrome_crashpad_handler')])
closure = set()
external = collections.Counter()
while queue:
    cur = queue.popleft()
    for d in needed(cur):
        if d in avail:
            if d not in closure:
                closure.add(d); queue.append(os.path.join(build, d))
        else:
            external[d] += 1

with open(cl_out, 'w') as f:
    for n in sorted(closure): f.write(n + '\n')
with open(ex_out, 'w') as f:
    for n,c in sorted(external.items()): f.write(f'{n}\t{c}\n')
PY

closure_count=$(wc -l <"${CLOSURE_LIST}")
echo ">>> closure: ${closure_count} shared libraries"
echo ">>> external NEEDEDs (expected to be in the guest's /lib already):"
sed 's/^/    /' "${EXTERNAL_LIST}"

# --- Step 2: copy + strip each lib in the closure ---------------------------

echo ">>> copy + strip closure"
while IFS= read -r lib; do
    cp -a "${BUILD}/${lib}" "${CHROOT}/${lib}"
    "${STRIP}" --strip-unneeded "${CHROOT}/${lib}"
done <"${CLOSURE_LIST}"

# --- Step 3: copy + strip the binaries ---------------------------------------

echo ">>> copy + strip binaries"
cp -a "${BUILD}/content_shell" "${CHROOT}/content_shell"
"${STRIP}" --strip-unneeded "${CHROOT}/content_shell"
if [ -x "${BUILD}/chrome_crashpad_handler" ]; then
    cp -a "${BUILD}/chrome_crashpad_handler" "${CHROOT}/chrome_crashpad_handler"
    "${STRIP}" --strip-unneeded "${CHROOT}/chrome_crashpad_handler"
fi

# --- Step 4: resource bundles + v8 snapshot blob ----------------------------

echo ">>> copy resource bundles + snapshot blob"
for pak in content_shell.pak shell_resources.pak ui_resources_100_percent.pak ui_test.pak; do
    if [ -f "${BUILD}/${pak}" ]; then
        install -m 0644 "${BUILD}/${pak}" "${CHROOT}/${pak}"
    fi
done
if [ -f "${BUILD}/snapshot_blob.bin" ]; then
    install -m 0644 "${BUILD}/snapshot_blob.bin" "${CHROOT}/snapshot_blob.bin"
fi
if [ -f "${BUILD}/icudtl.dat" ] && [ "$(stat -c%s "${BUILD}/icudtl.dat" 2>/dev/null || echo 0)" -gt 0 ]; then
    install -m 0644 "${BUILD}/icudtl.dat" "${CHROOT}/icudtl.dat"
fi

# --- Fontconfig + bundled test_fonts ----------------------------------------
# content_shell unconditionally constructs an MdTextButton with a default
# Skia font during startup. Under qemu-user the host fontconfig leaks in
# via the syscall translator, but qemu-system has neither host fonts nor
# a host /etc/fonts; the lookup hits NOTREACHED. We ship the bundled
# Chromium test fonts (DejaVu Sans + Tinos + Arimo, ~50 MB) plus an
# absolute-path fonts.conf with the cache on tmpfs (the ext4 is mounted
# read-only).

if [ -d "${BUILD}/test_fonts" ]; then
    echo ">>> staging test_fonts -> ext4://test_fonts/"
    mkdir -p "${CHROOT}/test_fonts"
    cp -a "${BUILD}/test_fonts/." "${CHROOT}/test_fonts/"
fi

mkdir -p "${CHROOT}/etc/fonts"
cat >"${CHROOT}/etc/fonts/fonts.conf" <<'FCONF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <cachedir>/tmp/fontconfig-cache</cachedir>
  <dir>/usr/local/chromium/test_fonts</dir>

  <match target="font">
    <edit name="embeddedbitmap" mode="append_last"><bool>false</bool></edit>
  </match>

  <match target="pattern">
    <test qual="any" name="family"><string>Times</string></test>
    <edit name="family" mode="assign"><string>Tinos</string></edit>
  </match>
  <match target="pattern">
    <test qual="any" name="family"><string>serif</string></test>
    <edit name="family" mode="assign"><string>Tinos</string></edit>
  </match>
  <match target="pattern">
    <test qual="any" name="family"><string>sans</string></test>
    <edit name="family" mode="assign"><string>DejaVu Sans</string></edit>
  </match>
  <match target="pattern">
    <test qual="any" name="family"><string>sans-serif</string></test>
    <edit name="family" mode="assign"><string>DejaVu Sans</string></edit>
  </match>
  <match target="pattern">
    <test qual="any" name="family"><string>monospace</string></test>
    <edit name="family" mode="assign"><string>Cousine</string></edit>
  </match>

  <alias>
    <family>system-ui</family>
    <prefer><family>DejaVu Sans</family></prefer>
  </alias>
</fontconfig>
FCONF

# --- libexpat.so.1 from the rv32 sysroot ------------------------------------
# Only external NEEDED that the M2 buildroot guest's /lib doesn't already
# carry. Pulled in by libthird_party_fontconfig.so.

EXPAT_REAL="$(readlink -f "${SYSROOT_DIR}/usr/lib/libexpat.so.1" 2>/dev/null || true)"
if [ -n "${EXPAT_REAL}" ] && [ -f "${EXPAT_REAL}" ]; then
    cp "${EXPAT_REAL}" "${CHROOT}/libexpat.so.1"
    chmod 0755 "${CHROOT}/libexpat.so.1"
    "${STRIP}" --strip-unneeded "${CHROOT}/libexpat.so.1" || true
    echo ">>> installed libexpat.so.1 from ${EXPAT_REAL}"
else
    echo "WARNING: libexpat.so.1 not found in ${SYSROOT_DIR}/usr/lib/" >&2
fi

# --- launcher wrapper -------------------------------------------------------

cat >"${STAGE}/usr/local/bin/content_shell" <<'WRAP'
#!/bin/sh
# Launcher wrapper for chromium-rv32 content_shell.
#
# Sets LD_LIBRARY_PATH to /usr/local/chromium (where the
# chromium-rootfs.ext4 image is mounted by S97-mount-chromium-rootfs),
# points fontconfig at the bundled test_fonts (cache on tmpfs because
# the ext4 mount is read-only), and prepends headless / single-process
# / no-sandbox / disable-gpu defaults.
if [ ! -x /usr/local/chromium/content_shell ]; then
    echo "content_shell wrapper: /usr/local/chromium/content_shell missing." >&2
    echo "  Attach chromium-rootfs.ext4 as a virtio-blk device and let" >&2
    echo "  S97-mount-chromium-rootfs mount it at /usr/local/chromium." >&2
    exit 127
fi
mkdir -p /tmp/fontconfig-cache
exec env \
    LD_LIBRARY_PATH=/usr/local/chromium \
    FONTCONFIG_FILE=/usr/local/chromium/etc/fonts/fonts.conf \
    HOME=/tmp \
    XDG_CACHE_HOME=/tmp \
    /usr/local/chromium/content_shell \
    --no-sandbox \
    --single-process \
    --headless \
    --disable-gpu \
    --enable-logging=stderr \
    --v=0 \
    "$@"
WRAP
chmod 0755 "${STAGE}/usr/local/bin/content_shell"

mkdir -p "${STAGE}/usr/local/chromium"
cat >"${STAGE}/usr/local/chromium/README.txt" <<'TXT'
This directory is the mountpoint for chromium-rootfs.ext4 (built by
chromium-rv32/scripts/install-content-shell-in-rootfs.sh). If you see
this file at runtime, the ext4 image was not attached to the guest. Boot
qemu-system-riscv32 with:

  -drive file=<path-to-chromium-rootfs.ext4>,if=none,format=raw,id=cdrv,readonly=on
  -device virtio-blk-device,drive=cdrv

and let /etc/init.d/S97-mount-chromium-rootfs mount /dev/vda (or /dev/vdb,
etc.) here.
TXT

# --- Optional: Svelte 5 demo dist -------------------------------------------
#
# The default M6 flow runs the SvelteKit Node server on the host and the
# guest fetches it over slirp at http://10.0.2.2:3000/. The static-asset
# path under /usr/local/share/svelte-demo/ is only useful if a future
# milestone wants to serve the demo entirely from within the guest. We
# copy a SvelteKit production build's `build/` tree if it exists; the
# normal SSR Node server is *not* able to be replaced by these files
# alone (they need a node runtime). Treat this as a placeholder.

if [ -d "${SVELTE_DIST}" ]; then
    echo ">>> staging demo/svelte/build/ -> /usr/local/share/svelte-demo/"
    cp -a "${SVELTE_DIST}/." "${STAGE}/usr/local/share/svelte-demo/"
else
    echo ">>> demo/svelte/build/ missing; not staging static svelte assets (this is fine; the M6 demo is served from the host)"
fi

# --- Build chromium-rootfs.ext4 from the staged tree ------------------------

echo ">>> building ext4 image at: ${EXT4_OUT}"
EXT4_PAYLOAD_BYTES=$(du -sb "${EXT4_WORK}" | awk '{print $1}')
EXT4_SIZE_M=$(( (EXT4_PAYLOAD_BYTES / 1024 / 1024) * 12 / 10 + 32 ))
echo "    payload: ${EXT4_PAYLOAD_BYTES} bytes ; image size: ${EXT4_SIZE_M} MiB"
mkdir -p "$(dirname "${EXT4_OUT}")"
rm -f "${EXT4_OUT}"
mke2fs -q -F -t ext4 -L m5-chromium \
    -d "${EXT4_WORK}" \
    -E lazy_itable_init=0,lazy_journal_init=0 \
    "${EXT4_OUT}" "${EXT4_SIZE_M}M"

rm -rf "${EXT4_WORK}"

echo
echo "===== staging inventory ====="
echo "stage root (cpio overlay): ${STAGE}"
echo "ext4 image:                ${EXT4_OUT}"
echo
echo "next:"
echo "  scripts/build-guest.sh           # regenerate rootfs.cpio.gz with overlay"
echo "  scripts/run-guest.sh             # boot w/ ext4 attached"
