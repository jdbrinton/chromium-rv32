# Running the RV32 guest under QEMU

`scripts/run-guest.sh` wraps `qemu-system-riscv32` for the typical M5/M6/M7
acceptance flows. This page documents what's under the wrapper so you
can hand-tune the invocation if needed.

## Reference invocation

```
qemu-system-riscv32 \
    -M virt -cpu rv32,sv32=on -m 2G -smp 4 \
    -nographic \
    -kernel  toolchain/buildroot-guest/output/images/Image \
    -initrd  toolchain/buildroot-guest/output/images/rootfs.cpio.gz \
    -bios    toolchain/buildroot-guest/output/images/fw_jump.bin \
    -append  "console=ttyS0,115200 earlycon=sbi rdinit=/sbin/init" \
    -drive   file=build/chromium-rootfs.ext4,if=none,format=raw,id=chromium,readonly=on \
    -device  virtio-blk-device,drive=chromium \
    -netdev  user,id=net0,hostfwd=tcp:127.0.0.1:9222-:9222 \
    -device  virtio-net-device,netdev=net0 \
    -no-reboot
```

## Kernel command-line tokens

| Token | Set by | What it does |
|---|---|---|
| `no-autorun-d8` | `--no-autorun` | `S99-run-d8` exits early without running the M2 d8 acceptance. |
| `no-autorun-content-shell-m5` | `--no-autorun` | `S98-run-content-shell-m5` exits early without launching content_shell. |
| `m5-svelte-host=URL` | `--svelte-host URL` | After the M5 inline-JS leg, run a second `content_shell` against URL (the M6 leg). |
| `m6-svelte-timeout=N` | `--gui` | The in-guest M6 `content_shell` invocation is wrapped by a SIGTERM-after-N watchdog. Default 120 s; `--gui` raises it to 3600 s. |
| `m6-no-poweroff` | `--gui` | After M6 prints its PASS/FAIL banner, block forever instead of `poweroff -f`. Lets a VNC session stay attached. |

## Process management on WSL2

The `--foreground` flag on `timeout` is **load-bearing** on WSL2. Without
it, GNU `timeout` creates a new process group for QEMU; QEMU's
`tcsetattr(stdio, …)` then raises `SIGTTOU`, which has the default
disposition of stopping the process. The result: a QEMU stuck in `Tl`
state, 0% CPU, no console output, "guest never boots" symptom.

`scripts/run-guest.sh` always uses `timeout --foreground`. If you write
your own wrapper, do the same.

## VirtIO networking

The default `-netdev user` (slirp NAT) is sufficient for the Svelte
demo:

* Guest is `10.0.2.15/24`.
* Host (gateway) is `10.0.2.2`.
* DNS is `10.0.2.3`.
* `hostfwd=tcp:127.0.0.1:9222-:9222` exposes the guest's content_shell
  DevTools endpoint to the host.

If you need bridged networking (e.g. real hardware) substitute
`-netdev bridge,id=net0,br=br0` and adjust the host server URL.

## Memory

`-m 2G` is the maximum the QEMU `virt` board exposes to rv32 sv32-paging
guests on the upstream `qemu-system-riscv32` build. The kernel still
only sees ~768 MB of *usable lowmem* — that's the sv32 page-table
constraint, independent of QEMU. The remainder is highmem, which the
kernel can use but the initramfs unpacker cannot. The cpio/ext4 split
described in [`architecture.md`](architecture.md) is what keeps us
under the lowmem ceiling.

## Choosing different machines or CPUs

We pin `-cpu rv32,sv32=on`. Other RV32 variants exist in QEMU 9+
(`rv32imafd`, etc.) but the buildroot toolchain only produces ISA
RVGC code, so `rv32` is the matching baseline.

`-M virt` is the only QEMU machine type with the right combination of
SBI firmware + UART + virtio-mmio. Other machines (`sifive_e`,
`microchip-icicle-kit`) are scoped at specific hardware variants.

## Console multiplexing

`-nographic` redirects all serial output to the controlling terminal's
stdio. ^A is QEMU's command-mode prefix:

| Keystroke | What |
|---|---|
| `^A x` | Quit immediately. |
| `^A c` | Toggle between QEMU monitor and serial console. |
| `^A h` | Print all command bindings. |

In `scripts/run-guest.sh --interactive` mode the script `exec`s qemu
directly; in default `auto` mode stdout is piped to the boot log file
under `logs/run-guest/`.
