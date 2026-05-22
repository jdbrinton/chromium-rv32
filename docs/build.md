# Building chromium-rv32 end-to-end

Every step is wrapped by a script under `scripts/`. The first time
through is slow (hours, mostly on `fetch chromium` and the initial
`ninja content_shell` build); subsequent runs are minutes.

## Prerequisites

| Tool | Why | Install on Ubuntu 22.04+ |
|---|---|---|
| `git`, `curl`, `python3 ≥ 3.10`, `ninja` | Build orchestration | `apt install git curl python3 ninja-build` |
| `node ≥ 22`, `npm` | SvelteKit demo | https://nodejs.org/ |
| `e2fsprogs ≥ 1.43` | `mke2fs -d` for the ext4 image | `apt install e2fsprogs` |
| `gn` | Provided by `depot_tools/`, no separate install | — |
| `python3-pip`, `websockets`, `pillow` | M6 / M7 host tools | `pip install --user websockets pillow` |

You do **not** need a host `clang`, `gcc`, or `qemu` — Chromium ships
its own clang, and Buildroot builds `qemu-system-riscv32` for us.

## Pinned upstream versions

| Component | Pin | Source |
|---|---|---|
| V8 | `637ded7fab21c745f197b071dc63ac19cff74ee3` (last commit before RV32 deprecation) | https://chromium.googlesource.com/v8/v8 |
| Chromium | HEAD at fetch time, tagged `chromium-rv32/pinned-<short_sha>` by `fetch-sources.sh` | https://chromium.googlesource.com/chromium/src |
| Buildroot | `2026.02.1` | https://buildroot.org/downloads/buildroot-2026.02.1.tar.xz |
| Linux kernel | `6.18.7` (set in `configs/buildroot/configs/rv32_guest_defconfig`) | Buildroot fetches it |
| OpenSBI | `1.6` | Buildroot fetches it |
| depot_tools | HEAD at clone time | https://chromium.googlesource.com/chromium/tools/depot_tools |

The V8 pin is enforced; the others are best-effort (you can roll
forward by editing the relevant config / script).

## Build order with rough timing

| # | Step | Wall-clock (first run) | Wall-clock (re-run) | Disk |
|---|---|---|---|---|
| 1 | `scripts/fetch-sources.sh` | 1 – 3 h (depot_tools, V8, Chromium) | 0 (skipped) | +80 GB |
| 2 | `scripts/apply-patches.sh` | <30 s | <30 s | — |
| 3 | `scripts/build-sysroot.sh` | 45 – 90 min | 1 – 2 min | +6 GB |
| 4 | `scripts/build-v8-d8.sh` | 15 – 40 min | 1 – 5 min | +3 GB |
| 5 | `scripts/build-content-shell.sh` | 30 – 90 min | 5 – 20 min | +20 GB |
| 6 | `scripts/install-content-shell-in-rootfs.sh` | 1 – 3 min | 1 – 3 min | +500 MB |
| 7 | `scripts/build-guest.sh` | 30 – 60 min (first run; Buildroot rebuilds gcc/glibc/kernel) | 1 – 3 min | +4 GB |
| 8 | `scripts/run-guest.sh --svelte-host …` | 90 s – 5 min (depends on TCG warmup) | 90 s – 5 min | — |

Times assume a 16-core / 32 GB host with `ccache` enabled.

## Step-by-step

### 1) `scripts/fetch-sources.sh`

```bash
scripts/fetch-sources.sh                     # all three (depot_tools + V8 + Chromium)
scripts/fetch-sources.sh --only-v8           # skip Chromium (handy for d8-only iteration)
scripts/fetch-sources.sh --no-pin-chromium   # skip the snapshot/bundle step
```

The `--no-history` and `--nohooks` flags keep the Chromium fetch as
small and fast as it can be. The bundle saved to
`toolchain/bundles/chromium-<short>.bundle` (~25 GB) lets you re-clone
the same snapshot later without going back to the network.

### 2) `scripts/apply-patches.sh`

Idempotent. Walks every `*.patch` under `patches/v8/` and
`patches/chromium/` and applies it to the correct sub-checkout. A patch
already applied is detected via `git apply --reverse --check` and
skipped. Re-run after any `gclient sync` that wipes the V8 third_party
tree.

### 3) `scripts/build-sysroot.sh`

Downloads Buildroot `2026.02.1` (~30 MB), extracts to
`toolchain/buildroot/`, applies `rv32_sysroot_defconfig`, and builds
the `riscv32-buildroot-linux-gnu-{gcc,g++,…}` cross toolchain plus the
glibc + libstdc++ sysroot. The sysroot is `rsync`'d into
`toolchain/sysroot/` (a stable path for Chromium/V8 `--sysroot=` to
reference) and the gcc-runtime objects (`crt*.o`, `libgcc.a`,
`libatomic.*`) are copied alongside.

### 4) `scripts/build-v8-d8.sh`

`gn gen build/m1-v8-d8` with `configs/gn/v8-d8.args.gn` (with
`TO_BE_REPLACED_WITH_ABSOLUTE_SYSROOT_PATH` substituted), then `ninja
-C build/m1-v8-d8 d8`. Outputs:

* `build/m1-v8-d8/d8` — the rv32 ELF.
* `build/m1-v8-d8/snapshot_blob.bin` — V8 startup snapshot.
* `build/m1-v8-d8/icudtl.dat` — only if `v8_enable_i18n_support=true`.

You can sanity-check the binary with the M2 acceptance script in
`configs/buildroot/board/rv32-d8/m2-acceptance.sh` (runs `hello.js`
inside the guest and reports timing).

### 5) `scripts/build-content-shell.sh`

`gn gen build/m4-content-shell` with
`configs/gn/content-shell.args.gn`, then `ninja content_shell`. This
is by far the slowest step the first time through — Chromium has
~50,000 compilation units. Subsequent builds reuse ninja's incremental
hashes and finish in minutes.

### 6) `scripts/install-content-shell-in-rootfs.sh`

* Walks the transitive `DT_NEEDED` graph from
  `build/m4-content-shell/content_shell` and copies every reachable
  `.so` to a staging tree. Strips them (`riscv32-…-strip
  --strip-unneeded`).
* Adds Chromium resource bundles (`*.pak`), the V8 snapshot blob, the
  bundled test fonts (`test_fonts/`), and the absolute-path
  `fonts.conf`.
* Copies `libexpat.so.1` from the sysroot (the only external NEEDED
  that the M2 guest's `/lib` doesn't already carry).
* Generates the launcher wrapper at
  `staged-rootfs/usr/local/bin/content_shell` (sets `LD_LIBRARY_PATH`
  + headless flags).
* Calls `mke2fs -d` to produce `build/chromium-rootfs.ext4`.

### 7) `scripts/build-guest.sh`

Re-uses the Buildroot tree from step 3 with `O=toolchain/buildroot-guest/`
and applies `rv32_guest_defconfig`. Produces:

* `toolchain/buildroot-guest/output/images/Image` — bzImage equivalent.
* `toolchain/buildroot-guest/output/images/rootfs.cpio.gz` — initramfs.
* `toolchain/buildroot-guest/output/images/fw_jump.bin` — OpenSBI.
* `toolchain/buildroot-guest/output/host/bin/qemu-system-riscv32` —
  qemu host binary (built by Buildroot, so its host-side QEMU is
  always in sync with the guest images).
* `toolchain/buildroot-guest/output/host/bin/qemu-riscv32` —
  user-mode QEMU for the M2 standalone d8 smoke (`qemu-user`).

### 8) Run the SvelteKit demo on the host

```bash
cd demo/svelte
npm install                # one-off
npm run build              # produces build/ (SvelteKit adapter-node)
npm run start              # serves http://localhost:3000
```

Leave it running. The dev binding is `0.0.0.0`, so the guest can reach
it at `http://10.0.2.2:3000/` via QEMU user-mode slirp.

### 9) Boot the guest

```bash
scripts/run-guest.sh --svelte-host http://10.0.2.2:3000/ \
                     --screenshot artifacts/runs/
```

The script tails the boot log, prints `M6 PASS` on success, and
captures a `m6-screenshot-<ts>.png` into `artifacts/runs/`.

### 10) Interactive GUI

```bash
scripts/run-guest.sh --svelte-host http://10.0.2.2:3000/ --gui
# In another terminal:
vncviewer 127.0.0.1:5901
```

See [`gui.md`](gui.md) for the details on WSL2 networking, RFB host
binding, and how the bridge translates RFB pointer/key events into CDP
input.
