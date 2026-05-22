# Troubleshooting

Common failure modes and how to fix them.

---

## "Initramfs unpacking failed: write error" during boot

**Symptom:** QEMU prints kernel boot messages, decompresses the
initramfs, then aborts with `Initramfs unpacking failed: write error`
and never reaches userspace.

**Cause:** Total size of `rootfs.cpio.gz` exceeds the kernel's usable
lowmem budget (~768 MB on rv32 + sv32). Putting all of content_shell
into the cpio blows past this.

**Fix:** Run `scripts/install-content-shell-in-rootfs.sh` to produce
`build/chromium-rootfs.ext4` and ensure `scripts/run-guest.sh` is
attaching it as a virtio-blk device. Inside the guest, the cpio only
needs the launcher wrapper and mountpoint; everything heavy comes off
the ext4. See [`architecture.md`](architecture.md) for the split.

---

## QEMU appears to hang at 0 % CPU after `Booting Linux on physical CPU 0`

**Symptom:** `qemu-system-riscv32` reports the kernel handing off but
then nothing further; `ps` shows the qemu process in state `Tl`
(stopped, multi-threaded); `top` reports 0 % CPU.

**Cause:** GNU `timeout` wraps QEMU in a new process group via the
default `setpgid(0,0)`. QEMU's `tcsetattr` on stdio (used for the
`-nographic` mux) then raises `SIGTTOU`, whose default disposition
stops the process. Common on WSL2 after a host reboot; can also happen
on stock Linux when the script is run from a job-control-aware
terminal.

**Fix:** `scripts/run-guest.sh` already uses `timeout --foreground`
which keeps QEMU in the foreground process group. If you wrote your
own wrapper, do the same. To unstick a stopped QEMU: `kill -CONT
<pid>`.

---

## VNC client says "connection refused" on Windows / from outside WSL

**Symptom:** `vncviewer 127.0.0.1:5901` from Windows fails with `No
connection could be made because the target machine actively refused
it.`

**Cause:** The bridge is bound to `127.0.0.1` inside WSL2, which is
not reliably forwarded to the Windows host's `127.0.0.1` across distro
restarts.

**Fix:** Run with `--rfb-host 0.0.0.0`:

```bash
scripts/run-guest.sh --svelte-host http://10.0.2.2:3000/ \
                     --gui --rfb-host 0.0.0.0
```

The script prints the WSL `eth0` IP it will be listening on. From
Windows, point your VNC client at `<that-IP>:5901`.

If `0.0.0.0` isn't acceptable (security policy, etc.), a Windows-side
`netsh interface portproxy` rule works:

```powershell
netsh interface portproxy add v4tov4 listenport=5901 \
    listenaddress=0.0.0.0 connectport=5901 connectaddress=<WSL-eth0-IP>
```

then connect to `127.0.0.1:5901` on Windows.

---

## "connection dropped by server before the session could be
established"

**Symptom:** The VNC client gets past the initial TCP handshake but
the bridge closes the socket without a banner.

**Cause:** The bridge timed out waiting for content_shell's CDP
endpoint to come up. content_shell isn't running yet (QEMU hasn't
finished booting) or the boot failed.

**Fix:** Tail the bridge log printed by `scripts/run-guest.sh` (path
ends in `bridge-<ts>.log`). Common upstream causes:

1. The Svelte server isn't running at `--svelte-host`. Start it with
   `cd demo/svelte && npm run start`.
2. The guest never booted (see the "QEMU at 0 % CPU" entry above).
3. content_shell crashed during M5 inline-JS leg. Look for `SEGV` or
   `InterpreterEntryTrampoline` in the boot log.

---

## `gn gen` fails with `assert(enable_rust)` somewhere

**Symptom:** `scripts/build-content-shell.sh` aborts during `gn gen`
with an `assert(enable_rust)` somewhere in `//third_party/`.

**Cause:** Several Chromium sub-targets parse-time-assert that Rust is
enabled, even though their `rustc` invocations are lazy. The
`enable_rust = true` in `configs/gn/content-shell.args.gn` is required
to get past `gn gen`. If you've set it to `false`, undo that.

**Fix:** If a real `rustc` invocation fails later at ninja time, patch
that sub-target individually (or accept a partial build by excluding
it from `ninja content_shell`).

---

## `ninja content_shell` fails with `undefined reference to xnn_*`

**Symptom:** Late in the link of
`libservices_webnn_webnn_service.so`, the linker reports undefined
references to `xnn_run_transpose_nd_x{8,16,32,64}` and friends.

**Cause:** XNNPACK's `BUILD.gn` only enumerates source sets for x86,
x64, arm, arm64, riscv64; **no riscv32**. The header still declares
the symbols, so any caller emits a reference, but no .o defines them.

**Fix:** Set in `configs/gn/content-shell.args.gn`:

```
build_tflite_with_xnnpack = false
webnn_use_tflite          = false
webnn_use_litert          = false
```

(Already set in the shipped args.)

---

## `ninja content_shell` fails with `undefined reference to X8632::… /
X8664::…` in libvk_swiftshader.so

**Symptom:** Link error from SwiftShader's vulkan stub library
referencing X86 / ARM-only namespace symbols.

**Cause:** `enable_swiftshader_vulkan` defaults to true in HEAD
Chromium and pulls SwiftShader's Subzero LLVM-based codegen, which
only ships X86 / X86_64 / ARM32 / MIPS32 target lowering libs. No
RV32 backend exists.

**Fix:** Set in `configs/gn/content-shell.args.gn`:

```
enable_swiftshader         = false
enable_swiftshader_vulkan  = false
angle_enable_swiftshader   = false
dawn_use_swiftshader       = false
```

(Already set in the shipped args.)

---

## `mke2fs -d` fails with "Path … is not a directory"

**Symptom:** `scripts/install-content-shell-in-rootfs.sh` aborts on
the `mke2fs -d` call.

**Cause:** Your distro's `e2fsprogs` is older than 1.43, when
`mke2fs -d` was added.

**Fix:** Upgrade `e2fsprogs`. On Ubuntu 22.04+ the stock package
should work; on older distros you may need a PPA.

---

## "M6 FAIL — no sentinel" but the page renders fine in a real browser

**Symptom:** `scripts/run-guest.sh --svelte-host …` reports M6 FAIL.
Tail of the boot log shows content_shell ran but the four
`m6:hydrated:`/`m6:dom-update:`/`m6:fetch-ok:`/`m6:sse-tick:` lines
are missing.

**Cause #1:** content_shell timed out (default 120 s) before V8
finished compiling Svelte's bundle. QEMU TCG translation is slow.

**Fix:** `scripts/run-guest.sh --timeout 600` to give the boot a
longer wall-clock budget, **and** consider passing `--gui` which
implicitly bumps the in-guest content_shell timeout to 3600 s.

**Cause #2:** The host's Svelte server isn't reachable at the
specified URL. The guest's network is qemu user-mode slirp; reach the
host at `10.0.2.2`, not `127.0.0.1`.

**Fix:** `--svelte-host http://10.0.2.2:3000/`. Sanity-check from the
guest with `--no-autorun` + `wget -q -O - 10.0.2.2:3000/api/healthz`.

---

## V8 build complains about a missing `libclang_rt.builtins.a`

**Symptom:** Linker error during d8 build referencing a missing
`libclang_rt.builtins.a` under `third_party/llvm-build/.../lib/clang/.../lib/riscv32-unknown-linux-gnu/`.

**Cause:** The bundled Chromium clang doesn't ship a compiler-rt
builtins archive for `riscv32-unknown-linux-gnu`. We don't actually
need its symbols (we link with `-nodefaultlibs + libgcc.a`), but the
driver still emits a `-l<path>` for it.

**Fix:** `scripts/build-v8-d8.sh` automatically creates an empty `ar`
archive named `libclang_rt.builtins.a` at the expected path before
invoking `gn gen`. If you ran a manual `gn gen`, the same trick works:

```bash
mkdir -p .../lib/clang/<ver>/lib/riscv32-unknown-linux-gnu
printf '!<arch>\n' > .../lib/clang/<ver>/lib/riscv32-unknown-linux-gnu/libclang_rt.builtins.a
```
