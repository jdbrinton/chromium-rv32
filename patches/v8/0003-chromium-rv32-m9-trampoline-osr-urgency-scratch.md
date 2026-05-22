# patches/v8/0003-chromium-rv32-m9-trampoline-osr-urgency-scratch.patch

**Milestone:** M9 (V8 RV32 correctness).

**Target:** `src/builtins/riscv/builtins-riscv.cc` inside the V8 checkout
that `scripts/fetch-sources.sh` brings down.

## What this patch does

Replaces a single hard-coded register in
`Builtins::Generate_InterpreterEntryTrampoline` so that the call to
`ResetFeedbackVectorOsrUrgency` no longer clobbers the register that
holds the function's `feedback_cell` on RV32.

The upstream code is:

```cpp
ResetFeedbackVectorOsrUrgency(masm, feedback_vector, a4);
```

The patch changes that single line to:

```cpp
{
  UseScratchRegisterScope temps(masm);
  ResetFeedbackVectorOsrUrgency(masm, feedback_vector, temps.Acquire());
}
```

This matches the upstream pattern used at the secondary
`ResetFeedbackVectorOsrUrgency` call site higher up in the same file.

## Why it's needed

`Generate_InterpreterEntryTrampoline` pins `a4` to
`kJavaScriptCallDispatchHandleRegister` only on RV64
(`#ifdef V8_TARGET_ARCH_RISCV64`). On RV32,
`kJavaScriptCallDispatchHandleRegister` is `no_reg`, so `a4` is left in
the per-function `RegisterAllocator` pool. The allocator then hands
`a4` to `feedback_cell` (a `DEFINE_REG` slot). The very next line in
the upstream code passes that same `a4` as a scratch register to
`ResetFeedbackVectorOsrUrgency`, which clobbers it. Several
instructions later the trampoline does

```cpp
__ Lw(scratch, FieldMemOperand(feedback_cell,
                               offsetof(FeedbackCell, interrupt_budget_)));
```

and dereferences whatever low byte the OSR-urgency reset wrote into
`a4`. Every user function that exhausts its interrupt budget (~10
invocations of any callback) faults at `libv8.so+<Builtins_InterpreterEntryTrampoline>+0x118`
with `SIGSEGV MAPERR @ 0x8`. This is the SEGV that the M6 path-A
workaround masked by removing the budget-interrupt mechanism
entirely on RV32.

## Verification

* `milestones/m6-svelte-in-browser/probe/d8-triggers/`: all 10
  qemu-user reproducers (`T1-from5-arrow-i` ... `T10-from50-no-mapper`)
  PASS with `rc=0` after this patch. Without this patch, T2-T10
  produce `SEGV_MID`.
* `milestones/m9-v8-correctness/`: a full `content_shell` boot inside
  `qemu-system-riscv32` against the SvelteKit hydration demo captures
  `m6:hydrated`, `m6:dom-update`, `m6:fetch-ok`, `m6:sse-tick`, and
  `m6:all-green` console sentinels (`trampoline SEGV markers in log:
  0`) and writes
  `milestones/m9-v8-correctness/artifacts/m6-screenshot-*.png`
  showing the four green status lights.

## Effect on the rest of the port

Tier-up via the interrupt-budget mechanism is now functional on RV32.
JS functions can again be promoted from the bytecode interpreter to
TurboFan via the usual `Runtime::kBytecodeBudgetInterrupt_Ignition`
path, so the M6 path-A workaround that disabled this mechanism is no
longer needed. Sparkplug and Maglev remain disabled
(`v8_enable_sparkplug=false`, `v8_enable_maglev=false`) -- those
tiers have separate, unrelated RV32 issues.

## Scope

* Single-line semantic change, plus inline comment.
* Touches RV32/RV64 code path only; non-`riscv/` builtins are
  unaffected.
* No new dependencies, no new symbols, no new GN args.
