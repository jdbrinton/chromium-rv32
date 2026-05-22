# Known limitations

## Status legend

* **Workaround in place** — the user-visible behaviour is correct, but
  we ship a workaround for an underlying bug. Removing the workaround
  is a future task.
* **Deferred** — known correctness issue; the workaround disables a
  feature that would otherwise expose it.
* **Out of scope** — known to be slow or unsupported; not currently a
  goal.

---

## V8 correctness

### `Generate_InterpreterEntryTrampoline` bytecode-budget interrupt path

**Status:** **Fixed in M9** (`patches/v8/0003-chromium-rv32-m9-trampoline-osr-urgency-scratch.patch`).
**Original symptom:** Without the fix, the rv32 guest's `content_shell`
SEGVs inside `Builtins_InterpreterEntryTrampoline` early in any
non-trivial JavaScript program (`SEGV_MAPERR @ 0x8` is the canonical
signature). The Svelte 5 demo failed end-to-end on the first
long-running script.
**Root cause:** On RV32, `kJavaScriptCallDispatchHandleRegister`
resolves to `no_reg`, so the per-function `RegisterAllocator` is free
to hand `a4` to `feedback_cell`. The upstream V8 code then passes a
hard-coded `a4` as a scratch register to
`ResetFeedbackVectorOsrUrgency`, which clobbers `feedback_cell`. The
SEGV fires later in the same trampoline when the budget-interrupt
sequence dereferences the corrupted pointer. On RV64 the same source
code happens to be safe because `a4` is pinned to
`kJavaScriptCallDispatchHandleRegister` and `feedback_cell` cannot be
allocated to it.
**Fix:** Replace the hard-coded `a4` with a real macro-assembler
scratch obtained via `UseScratchRegisterScope::Acquire()`. This
matches the upstream pattern used at the secondary
`ResetFeedbackVectorOsrUrgency` call site in the same file. With the
fix applied, JS functions tier up via the normal interrupt-budget
mechanism on RV32 again. The previously-required M6 path-A workaround
(which disabled the budget-interrupt path entirely) is no longer
needed.

### Post-CallRuntime register-preservation bug

**Status:** **Not a real bug; closed in M9.**
**What we thought it was:** M6 hypothesised that the post-trampoline
SEGV signalled a generic "live registers clobbered across
`CallRuntime`" issue on RV32 that other builtins might also trip on.
**What it actually was:** The trampoline SEGV had a single specific
cause -- the OSR-urgency-scratch register collision described above --
and is gone with the M9 fix. There is no separate "post-CallRuntime
register clobber" pattern to audit. RV32 V8's standard `CallRuntime`
saves callee-saved registers correctly; the cited evidence from M6
was the same trampoline failure observed from a different angle.

### `kAtomicsLoad` register-allocator-verifier phi-input vreg mismatch

**Status:** **Fixed in M10**
(`patches/v8/0004-chromium-rv32-m10-atomicpairload-pin-and-cleanup.patch`).
**Original symptom:** Building V8 with the upstream
`--turbo_verify_allocation` flag (which is on by default under DCHECK
builds) tripped seven
`register-allocator-verifier.cc:CHECK_EQ(actual, expected)` aborts
during `kAtomicsLoad` codegen with operand
`[a0|R|w32]`, `actual = vreg 98`, `expected = vreg 150`. M6/M9 worked
around it with `v8_enable_concurrent_mksnapshot = false` plus a
log-and-continue relaxation in `register-allocator-verifier.cc`, which
let mksnapshot finish but generated **incorrect** machine code for any
JS call that hit `Atomics.load(BigInt64Array, …)`.
**Root cause:** the rv32 InstructionSelector for
`RiscvWord32AtomicPairLoad` declared its `(base, index)` inputs with
the generic `g.UseRegister(...)` policy while pinning its
`(low, high)` outputs to FIXED `a0`/`a1`. The register allocator was
therefore free to pick `a2` for the address input (output of
`RiscvAdd32`) *and* `a2` for the spill destination of the live value
in `a0` that the C-call sequence inside the codegen would clobber.
The constraint resolver then emitted a parallel move `[a2 := a0]`
right before the load, overwriting the load's address with the
unrelated value previously in `a0`.
**Fix:** pin the `(base, index)` inputs of
`VisitWord32AtomicPairLoad` to FIXED `a3` / `a4` so the allocator can
never choose `a2` for either of them. With the pin in place the
constraint resolver still picks `a2` as its spill destination but it
no longer clobbers anything live.
**Effect:** `v8_enable_concurrent_mksnapshot` flips back to `true`,
the verifier runs full upstream `CHECK_EQ` on rv32 again, and
`Atomics.load` against `BigInt64Array` returns the correct value (not
the previous "value of whatever happened to be in a0 at the call
site").

### Disabled or untested optimisation tiers

| Tier | State | Why |
|---|---|---|
| Ignition (interpreter) | ON | Required; the baseline tier. |
| Turbofan | ON | Required for many shared codegen files to compile. |
| Turboshaft | ON, full upstream verifier (M10) | See the kAtomicsLoad entry. |
| Sparkplug | OFF (`v8_enable_sparkplug = false`) | M10 enabled it and confirmed `v8/src/baseline/riscv/` shares its rv32 codegen with rv64 through `kSystemPointerSize`-parameterised helpers, but the larger Sparkplug-enabled torque-csa graph triggers clang frontend signals during compilation in this build environment (likely memory pressure at default ninja parallelism). The signal is unrelated to the rv32 V8 patches landed in M9/M10. A clean repro requires either a host with more RAM or per-step memory profiling; out of scope for M10. |
| Maglev | OFF (`v8_enable_maglev = false`) | `v8/src/maglev/riscv/maglev-ir-riscv.cc` carries `V8_TARGET_ARCH_RISCV32` `#ifdef`s, but the wider Maglev integration (deopt-frame layout, on-stack-replacement, tier-up trampoline) has not been audited under our M9 trampoline fix. Deferred to M11+. |
| LiftOff (Wasm baseline) | ON (codegen-static-asserts patched) | Required by enabled `v8_enable_webassembly`; not exercised by the M6 demo. |

The demo runs on Ignition + Turbofan, with tier-up via the
interrupt-budget mechanism restored by the M9 trampoline fix.
Performance numbers are in the "Performance expectations under QEMU"
section below.

---

## M7 GUI / input

* RFB security type `None`. No auth. Trusts whoever can connect.
* `--rfb-host 0.0.0.0` opens the bridge on every NIC; the bridge does
  not enforce LAN-only.
* Single VNC client at a time is the supported configuration. The
  bridge accepts multiple but pointer/key events from concurrent
  clients can interleave.
* No clipboard, no audio, no file transfer over RFB.
* Frame rate caps at ~15 fps (CDP `everyNthFrame=4`).
* Input latency 300 ms – 1.2 s under QEMU TCG.

---

## QEMU + rv32 Linux

* Maximum usable memory ~768 MB regardless of `-m` due to sv32 paging.
  Workaround: split content_shell across an initramfs overlay + an
  ext4 disk (`scripts/install-content-shell-in-rootfs.sh`).
* QEMU `-cpu rv32,sv32=on` only; no SMP scaling past 4 vCPU (the
  paging walker doesn't benefit further on this workload).
* `timeout --foreground` required on WSL2 to avoid `SIGTTOU` stops.
  Documented in [`troubleshooting.md`](troubleshooting.md).

---

## Performance expectations under QEMU

Single-host, AMD Ryzen 9 5950X (16 c) host, 32 GB RAM, WSL2, default
Chromium build, V8 tiers as above:

| Workload | Wall-clock |
|---|---|
| QEMU cold boot to `Welcome to Buildroot` | 1–3 s |
| `d8 hello.js` first call (cold V8) | 1.5–3 s |
| `d8` JIT-cached subsequent calls | 0.2–0.5 s |
| `content_shell --dump-dom` on a `data:` URL | 30–60 s |
| Svelte 5 demo hydrate + `m6:all-green` | ~75 s from QEMU start |
| Click → next frame in M7 VNC | 0.3–1.2 s |

These are dominated by **QEMU TCG translation**, not by V8 tier-down.
Profiling on real RV32 hardware (Efinix Ti375 / SiFive U-series) would
look very different.

---

## Graphics

* `enable_swiftshader = false`, `angle_enable_swiftshader = false`,
  `dawn_use_swiftshader = false` — SwiftShader Subzero JIT only ships
  X86/X86_64/ARM/MIPS backends. No RV32 path.
* `enable_vulkan = false`, `enable_swiftshader_vulkan = false` — no
  Vulkan, no `libvk_swiftshader.so`.
* WebGL, WebGPU: untested. Likely unusable (no GPU path).
* Skia CPU rasteriser handles everything. Fine for HTML / CSS /
  basic 2D canvas; not fine for `<video>` or heavy WebGL.

---

## Media

* `media_use_ffmpeg = false`, `enable_ffmpeg_video_decoders = false`
  — Chromium ships FFmpeg pre-generated config headers for
  {ia32,x64,arm,arm-neon,arm64,riscv64}, **no** RV32. Wiring the
  generator on RV32 is doable but not done.
* No audio (`use_alsa = false`, `use_pulseaudio = false`,
  `use_cras = false`).
* MediaStream / WebRTC: untested.

---

## Out of scope for this repo

* Bringing up `chromium-rv32` on **real RV32 hardware** (Efinix Ti375,
  SiFive U-series). The pipeline is portable in principle; M8 only
  validates the QEMU path.
* The deferred V8 correctness work above. Each item is a separate
  follow-up milestone (`m9-*`, `m10-*`, …).
* Sandbox / multi-process content_shell. We use
  `--single-process --no-sandbox`; the sandbox helper's seccomp
  filters and zygote on RV32 are untested.
