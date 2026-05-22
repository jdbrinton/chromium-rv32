# Architecture

What runs where, and how the pieces are connected.

## The moving parts

```
┌──────────────────────────────  Host  ───────────────────────────────┐
│                                                                     │
│  ┌────────────────────────┐    ┌────────────────────────────────┐   │
│  │  demo/svelte/  (Node)  │    │  scripts/run-guest.sh           │   │
│  │  SvelteKit + adapter-  │    │   ├─ qemu-system-riscv32        │   │
│  │  node, port 3000       │    │   │    -M virt -cpu rv32        │   │
│  └─────────┬──────────────┘    │   │    -nographic               │   │
│            │ HTTP (slirp NAT)  │   │    -netdev user,hostfwd...  │   │
│            │ 10.0.2.2:3000     │   │    -drive ext4 (virtio-blk) │   │
│            ▼                   │   │                             │   │
│  ┌────────────────────────────────▼───────────────────────────────┐ │
│  │                       qemu-system-riscv32                       │ │
│  │  ┌──────────────────────────────────────────────────────────┐  │ │
│  │  │ rv32 Linux 6.18 guest (sv32 paging, ~768 MB lowmem)       │  │ │
│  │  │ ┌──────────────────────────────────────────────────────┐ │  │ │
│  │  │ │ /sbin/init -> rcS -> S97-mount-chromium-rootfs        │ │  │ │
│  │  │ │            -> S98-run-content-shell-m5                │ │  │ │
│  │  │ │                                                       │ │  │ │
│  │  │ │  content_shell (rv32 ELF, ~80 MB; 400-lib .so closure │ │  │ │
│  │  │ │  loaded from ext4 mounted at /usr/local/chromium)     │ │  │ │
│  │  │ │  ┌─────────────────────────────────────────────────┐  │ │  │ │
│  │  │ │  │ V8 isolate (rv32 codegen; Maglev/Sparkplug off) │  │ │  │ │
│  │  │ │  │ Blink + Skia CPU rasteriser                     │  │ │  │ │
│  │  │ │  │ CDP server on 0.0.0.0:9222                      │  │ │  │ │
│  │  │ │  └─────────────────────────────────────────────────┘  │ │  │ │
│  │  │ └──────────────────────────────────────────────────────┘ │  │ │
│  │  └──────────────────────────────────────────────────────────┘  │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                            ▲                                        │
│                            │ qemu hostfwd 9222:9222                 │
│                            │ CDP / WebSocket                        │
│  ┌─────────────────────────┴──────────────────────────────────────┐ │
│  │  tools/cdp-vnc-bridge.py      (only running for --gui mode)    │ │
│  │   ├─ Page.startScreencast → JPEG frames → PIL → RFB raw        │ │
│  │   └─ RFB pointer/key events ← VNC client                       │ │
│  │      Translated to Input.dispatchMouseEvent / KeyEvent CDP     │ │
│  └─────────────────────────┬──────────────────────────────────────┘ │
│                            │ RFB v3.8                               │
│                            │ 127.0.0.1:5901 (or 0.0.0.0)            │
│                            ▼                                        │
│                  ┌──────────────────┐                               │
│                  │  VNC client      │                               │
│                  │  (TigerVNC etc.) │                               │
│                  └──────────────────┘                               │
└─────────────────────────────────────────────────────────────────────┘
```

## Why each piece exists

### `qemu-system-riscv32` on the `virt` board

A vanilla rv32 Linux kernel boots in seconds; the `virt` board exposes
16550 UART + virtio-mmio bus + an SBI test device, which is everything
we need. We do not run a graphical QEMU window — see GUI below.

### Buildroot for kernel + rootfs

* **Why Buildroot, not Yocto / debootstrap / a hand-rolled toolchain?**
  Buildroot has a stable RV32 path, can produce both an x86_64 →
  riscv32 cross-toolchain *and* a qemu-system-riscv32 host binary, and
  has a tiny enough scope that we can hand-curate every package via a
  defconfig. The full pipeline (toolchain + glibc + libstdc++ + kernel
  + initramfs + qemu) is one `make` away.

* The same Buildroot tree builds **two** outputs: a *sysroot-only*
  configuration (just the rv32 glibc + libstdc++ + cross binaries) used
  by Chromium/V8 cross-compilation, and a *guest* configuration that
  produces a bootable Linux 6.18 + busybox image plus the
  `qemu-system-riscv32` host binary. See `configs/buildroot/README.md`.

### Rootfs split: cpio vs ext4

A vanilla rv32 Linux 6.18 kernel on the QEMU `virt` board, paging via
sv32, has roughly **768 MB of usable lowmem** regardless of what we
pass to QEMU's `-m`. Our content_shell binary + its 400-shared-library
closure + Chromium resource paks comes to ~417 MB. Putting all of that
in an initramfs blows past the kernel's `unpack_to_rootfs()` budget and
the boot fails with `Initramfs unpacking failed: write error`.

The workaround: split the payload across **two filesystems**:

1. A small **cpio overlay** (`rootfs.cpio.gz`, ~30 MB compressed)
   contains the launcher wrapper, mountpoint stub, and init scripts.
2. The large **`chromium-rootfs.ext4`** is attached as a separate
   virtio-blk device; the in-guest `S97-mount-chromium-rootfs` init
   script mounts it read-only at `/usr/local/chromium`. The ELF runs
   directly off that mount via `mmap` — no expansion into tmpfs.

### V8 + Chromium pins

V8 is pinned to commit **`637ded7…`**, the last commit before the RV32
backend started being deprecated. Newer V8 tags compile-time-fail with
`v8_riscv_enable_deprecated_riscv32=true`; older ones predate features
Chromium needs.

The Chromium tip is whatever `fetch chromium` returned when we
captured it; `scripts/fetch-sources.sh` snapshots the SHA + tags it +
optionally `git bundle`s it. The exact tag is recorded in
[`build.md`](build.md).

### Headless Ozone + Skia CPU

`use_ozone = true`, `ozone_platform = "headless"`, plus the upstream
headless preset (`headless_use_embedded_resources`,
`headless_use_prefs = false`, `use_bundled_fontconfig`, etc.). All
GPU paths are off:

* `enable_swiftshader = false`, `angle_enable_swiftshader = false`,
  `dawn_use_swiftshader = false` — SwiftShader's Subzero JIT only ships
  X86/X86_64/ARM/MIPS backends, no RV32.
* `enable_vulkan = false`, `angle_enable_vulkan = false`, `use_dawn =
  false`, `skia_use_dawn = false`.
* `enable_swiftshader_vulkan = false` — disables the
  `libvk_swiftshader.so` build that pulls in those missing backends.

Skia's CPU rasteriser handles all the painting; it's slow under QEMU
TCG but correct.

### Fonts: bundled `test_fonts`

`content_shell` constructs MdTextButton early in startup, which
unconditionally goes through fontconfig + Skia to find a default font.
The guest has neither a host fontconfig nor a host
`/usr/share/fonts/`. We ship Chromium's `third_party/test_fonts/`
(DejaVu Sans + Tinos + Arimo + a few CJK / Khmer / emoji glyphs,
~50 MB) inside `chromium-rootfs.ext4` along with an absolute-path
`fonts.conf` that points fontconfig there. The cache is on tmpfs
(`/tmp/fontconfig-cache`) because the ext4 mount is read-only.

### The host-side CDP→RFB bridge

QEMU has graphical output backends (SDL, GTK, VNC, SPICE), and rv32
Linux can drive `virtio-gpu-device` to provide a framebuffer console,
but bringing up a full Xorg / Weston compositor + virtio-input drivers
inside the rv32 guest is far more invasive than the M7 goal called for.

Instead we add a **host-side** bridge:

1. content_shell exposes the Chrome DevTools Protocol on `:9222`
   inside the guest. QEMU's `hostfwd` makes that reachable from the
   host as `127.0.0.1:9222`.
2. `tools/cdp-vnc-bridge.py` connects to CDP, calls
   `Page.startScreencast` (JPEG frames at 15 fps), decodes them with
   Pillow, and re-encodes as RFB v3.8 raw rectangle updates.
3. Any VNC client (TigerVNC, Remmina, RealVNC, …) connecting to the
   bridge sees the rendered Svelte demo and can move the mouse / type;
   the bridge converts every RFB pointer/key event back into a CDP
   `Input.dispatchMouseEvent` / `Input.dispatchKeyEvent` call.

This avoids touching the kernel `linux.fragment` or shipping X.

## Boot sequence end-to-end

```
0.000   QEMU starts; OpenSBI prints fw_jump banner.
0.4-0.8  Linux 6.18 kernel decompresses, mounts initramfs.
0.9-1.5  busybox init runs rcS:
            ... S40network    (udhcpc on eth0)
            ... S97-mount-chromium-rootfs  (mount /dev/vda -> /usr/local/chromium)
            ... S98-run-content-shell-m5   (start m5-acceptance.sh)
            ...    -> content_shell --headless --remote-debugging-port=9222
                     data:text/html,<script>...</script>      (M5 leg)
            ...    -> looks for /etc/m5-svelte-host or kernel
                       m5-svelte-host=URL token;
                     -> content_shell --remote-debugging-port=9222 URL  (M6 leg)
~75       Svelte page hydrates; m6:hydrated, m6:dom-update, m6:fetch-ok, m6:sse-tick.
~76       $effect prints m6:all-green.
~76       (host) tools/capture-screenshot.py saves a PNG via CDP.
~76+      (host, only if --gui) tools/cdp-vnc-bridge.py is already
          streaming pixels to whatever VNC client is attached.
~196      (M6 default) content_shell timeout fires; m5-acceptance.sh
          prints "M6 PASS" and the guest powers off.
          (--gui mode replaces this with: hold open indefinitely, no
           poweroff, until host script is killed.)
```
