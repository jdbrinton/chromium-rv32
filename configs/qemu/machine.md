# QEMU machine configuration

The reference invocation built by `scripts/run-guest.sh` for the M5 / M6 /
M7 demos:

```
qemu-system-riscv32 \
    -machine virt \
    -smp 4 \
    -m 1024 \
    -nographic \
    -kernel  toolchain/buildroot-guest/output/images/Image \
    -initrd  toolchain/buildroot-guest/output/images/rootfs.cpio.gz \
    -bios    toolchain/buildroot-guest/output/images/fw_jump.bin \
    -append  "console=ttyS0,115200 earlycon=sbi rdinit=/sbin/init <extra...>" \
    -netdev  user,id=net0,hostfwd=tcp:127.0.0.1:9222-:9222 \
    -device  virtio-net-device,netdev=net0 \
    -drive   if=none,id=cd,format=raw,readonly=on,file=chromium-rootfs.ext4 \
    -device  virtio-blk-device,drive=cd \
    -no-reboot
```

## Why each flag

| Flag | Why |
|---|---|
| `-machine virt` | Generic riscv `virt` board. Has 16550 UART + virtio-mmio bus + a single SBI test device. |
| `-smp 4` | M2-M7 acceptance scripts run in seconds with 4 cores. content_shell spawns a couple of utility threads; 4 is sufficient. |
| `-m 1024` | rv32 (sv32) lowmem ceiling is ~768 MB usable. We request 1 GiB so the kernel sees a comfortable margin. Going higher does not help — sv32 caps it. |
| `-nographic` | Multiplexes UART onto stdio. The CDP/RFB bridge does its own framebuffer transport, so we don't need a QEMU window. |
| `-kernel`, `-initrd`, `-bios` | Direct kernel boot via OpenSBI fw_jump. |
| `console=ttyS0,115200 earlycon=sbi` | Kernel command-line: 16550 UART + early SBI console so the boot log is visible from the very first instruction. |
| `rdinit=/sbin/init` | Tell the kernel to exec busybox init out of initramfs. |
| `hostfwd=tcp:127.0.0.1:9222-:9222` | Forwards the host's localhost:9222 to the guest's :9222 (where `content_shell --remote-debugging-port=9222` listens). Used by `tools/capture-screenshot.py` and `tools/cdp-vnc-bridge.py`. |
| `-drive if=none,id=cd,format=raw,readonly=on,file=chromium-rootfs.ext4` `-device virtio-blk-device,drive=cd` | Attach the `content_shell` payload as a virtio-blk device. Mounted at `/usr/local/chromium` by the `S97-mount-chromium-rootfs` init script. |
| `-no-reboot` | If something inside the guest issues `reboot`, QEMU exits instead of restarting. Saves us from infinite loops on broken builds. |

## Extra append tokens

| Token | Set by | Behaviour |
|---|---|---|
| `no-autorun-content-shell-m5` | `scripts/run-guest.sh --no-autorun` | Skip the M5/M6 acceptance hook (drop straight to a shell prompt). |
| `m5-svelte-host=URL` | `scripts/run-guest.sh --svelte-host URL` | Tell the in-guest acceptance script to run the M6 leg against this URL. |
| `m6-svelte-timeout=N` | `scripts/run-guest.sh --gui` | Extend `content_shell`'s in-guest run time from 120 s to N s. |
| `m6-no-poweroff` | `scripts/run-guest.sh --gui` | Block forever after M6 instead of `poweroff -f`, so the VNC session can stay attached. |

## Performance expectations

| Step | Wall-clock (4 vCPU, host 16 core / 32 GB) |
|---|---|
| Cold boot to `Welcome to Buildroot` | 1–3 s |
| M2 d8 acceptance pass | 5–15 s |
| M5 content_shell on a `data:` URL | 30–60 s (V8 isolate + snapshot decode is dominant) |
| M6 Svelte hydration + first `m6:all-green` | ~75 s wall-clock from QEMU start |
| Interactive M7 GUI input latency | 300 ms–1.2 s per click (TCG + content_shell paint + JPEG screencast) |

These are dominated by **QEMU TCG translation** of unfamiliar RV32 code
paths. After the JIT warms up subsequent passes are 2–3× faster.
