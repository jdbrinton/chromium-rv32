# Buildroot configuration

This directory is the project's `BR2_EXTERNAL` tree. It is fed to
upstream Buildroot via:

```
make BR2_EXTERNAL=$(realpath configs/buildroot) \
     O=toolchain/buildroot-guest \
     rv32_guest_defconfig
```

The wrapper scripts in `scripts/` (`build-sysroot.sh`, `build-guest.sh`)
do this for you.

## Defconfigs

| File | Purpose | Outputs |
|---|---|---|
| `configs/rv32_sysroot_defconfig` | Build only the rv32 glibc + libstdc++ sysroot and the cross binaries. Used to satisfy Chromium/V8's `--sysroot=` link line. | `toolchain/buildroot/output/host/.../sysroot/` |
| `configs/rv32_guest_defconfig` | Full bootable RV32 Linux guest: kernel 6.18, OpenSBI, busybox userspace, qemu-system-riscv32 + qemu-riscv32 host binaries. | `toolchain/buildroot-guest/output/images/{Image,fw_jump.bin,rootfs.cpio.gz}` |

## Boards

| Directory | What it is |
|---|---|
| `board/rv32-d8/` | M2 d8 acceptance: post-build hook that copies the V8 d8 binary into `/opt/v8/` inside the guest, plus the `init.d` hook that runs it at boot. |
| `board/rv32-chromium/` | M5 / M6 content_shell acceptance: `init.d` hooks that mount the chromium ext4 image and run `content_shell` against an inline-JS data URL (M5) and the host SvelteKit demo (M6). |

## Rootfs overlay stack

The guest defconfig sets `BR2_ROOTFS_OVERLAY` to three layers, in order:

1. `$(BR2_EXTERNAL)/board/rv32-d8/rootfs-overlay/` — `S99-run-d8`.
2. `$(BR2_EXTERNAL)/board/rv32-chromium/rootfs-overlay/` — `S97`,
   `S98`, and the in-guest `m5-acceptance.sh`.
3. `$(BR2_EXTERNAL)/staged-rootfs/` — populated by
   `scripts/install-content-shell-in-rootfs.sh`. **Generated and
   gitignored.** `scripts/build-guest.sh` will create an empty directory
   here if the install script has not been run yet, so the overlay stack
   still resolves cleanly.

The bulk of the content_shell payload (the ELF + ~400 .so closure +
Chromium resource paks ~ 417 MB) does **not** live in the cpio. It is
packaged separately as `chromium-rootfs.ext4` and attached to QEMU as a
virtio-blk device. The rv32 Linux 6.18 kernel's lowmem ceiling
(~768 MB usable on the QEMU `virt` board with sv32 paging) is too small
for the entire payload to fit in an initramfs.

## Linux kernel fragment

`board/rv32-d8/linux.fragment` carries the additional kernel knobs we
need on top of upstream `rv32_defconfig`:

* `CONFIG_VIRTIO_*` for virtio-blk / virtio-net / virtio-balloon
* `CONFIG_NET_9P*` for 9P sharing
* `CONFIG_DEVTMPFS_MOUNT` etc.

Pinned kernel version: **6.18.7** (set in `rv32_guest_defconfig`).

## Acceptance scripts

* `board/rv32-d8/m2-acceptance.sh` — copied into `/opt/v8/m2-acceptance.sh`
  by the post-build hook. Runs `d8` on the canonical `hello.js`,
  exercises an inline JS expression, and reaches the host server (if
  it's running) for a fetch-POST round-trip.
* `board/rv32-chromium/rootfs-overlay/usr/local/share/m5-content-shell/m5-acceptance.sh`
  — built straight into the rootfs overlay. Runs `content_shell` on an
  inline-JS `data:` URL (M5 leg) and then on the host Svelte demo (M6
  leg). Prints `m6:all-green` once the four-light board converges.
* The M5 acceptance script also honours two `/proc/cmdline` tokens used
  by the M7 interactive GUI path:
  * `m6-svelte-timeout=N` — extend the `content_shell` run from the
    default 120 s to N seconds.
  * `m6-no-poweroff` — at the end of M6, block forever instead of
    calling `poweroff -f`, so the VNC client stays connected.
