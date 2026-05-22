# scripts/

Every script sources `env.sh` first so paths (`PROJECT_ROOT`, `SRC_DIR`,
`BUILD_DIR`, `SYSROOT`, `BR2_EXTERNAL`) are consistent across the
pipeline. To run any of them by hand you do **not** need to `source
env.sh` yourself — they handle that internally.

## End-to-end order

```text
1.  scripts/fetch-sources.sh                # depot_tools + V8 + Chromium
2.  scripts/apply-patches.sh                # patches/{v8,chromium}/
3.  scripts/build-sysroot.sh                # toolchain/sysroot/
4.  scripts/build-v8-d8.sh                  # build/m1-v8-d8/d8 (M2 acceptance)
5.  scripts/build-content-shell.sh          # build/m4-content-shell/content_shell
6.  scripts/install-content-shell-in-rootfs.sh
                                            # build/chromium-rootfs.ext4
                                            # + configs/buildroot/staged-rootfs/
7.  scripts/build-guest.sh                  # rootfs.cpio.gz + Image + fw_jump.bin
8.  scripts/run-guest.sh --svelte-host URL  # M6 svelte demo + M5 inline JS
    scripts/run-guest.sh --svelte-host URL --gui  # M7 interactive VNC
```

(See [`../docs/build.md`](../docs/build.md) for timing estimates and
prereqs at each step.)

## Common flags

| Flag (run-guest.sh) | What it does |
|---|---|
| `--interactive`        | Drop you into the live qemu serial; ^A x to quit. |
| `--no-autorun`         | Like `--interactive` but also skip the M5/M6 auto-acceptance hooks. |
| `--svelte-host URL`    | Tell the in-guest acceptance script to run content_shell against URL. |
| `--timeout SECONDS`    | Override the 600-second QEMU wall-clock timeout. |
| `--screenshot DIR`     | Capture a PNG via CDP when the page hits `m6:all-green`. |
| `--gui`                | M7 interactive VNC. Spawns `tools/cdp-vnc-bridge.py`. |
| `--gui-capture DIR`    | M7 regression: spawn bridge + `rfb-capture.py`, write 1-2 PNGs. |
| `--gui-click X Y`      | (with `--gui-capture`) inject a click between the two frames. |
| `--rfb-port N`         | Override the VNC port (default 5901). |
| `--rfb-host ADDR`      | Override the bridge bind address. `0.0.0.0` exposes it on every NIC. |
| `--help`               | Print just the docstring at the top. |

## Idempotency

* `fetch-sources.sh` skips clones / fetches that already exist; it
  re-checks the V8 pin SHA every run.
* `apply-patches.sh` detects already-applied patches and skips them
  (via `git apply --reverse --check`).
* `build-sysroot.sh` / `build-guest.sh` reuse Buildroot's `dl/` cache
  and `O=` output directories. The first build is slow; subsequent ones
  are minutes.
* `build-v8-d8.sh` / `build-content-shell.sh` are plain
  `gn gen` + `ninja`. Re-run after editing `configs/gn/*.gn` or any
  patched source.
* `install-content-shell-in-rootfs.sh` rebuilds the ext4 from scratch
  each invocation (cheap; the staging dir is wiped and rebuilt).
* `run-guest.sh` is stateless; it just launches qemu.
