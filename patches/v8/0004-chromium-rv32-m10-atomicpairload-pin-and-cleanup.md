# patches/v8/0004-chromium-rv32-m10-atomicpairload-pin-and-cleanup.patch

**Milestone:** M10 (deferred V8 cleanup).

**Target:** V8 sources inside the V8 checkout that `scripts/fetch-sources.sh`
brings down. Four files:

- `src/compiler/backend/riscv/instruction-selector-riscv32.cc`
- `src/compiler/backend/register-allocator-verifier.cc`
- `src/compiler/code-assembler.h`
- `src/builtins/builtins-sharedarraybuffer-gen.cc`

## What this patch does

1. **`instruction-selector-riscv32.cc::VisitWord32AtomicPairLoad`** — pins
   the `(base, index)` inputs of `kRiscvWord32AtomicPairLoad` to fixed
   registers `a3` and `a4` (instead of `g.UseRegister(...)`). The change
   is the real M10 fix; it lifts the `register-allocator-verifier` phi-input
   vreg mismatch under `kAtomicsLoad` on rv32 by guaranteeing that the
   load's address registers can never be the same register the constraint
   resolver picks to spill the constant in `a0` across the C-call sequence
   inside the atomic-pair-load codegen.
2. **`register-allocator-verifier.cc`** — restores upstream `CHECK_EQ` in
   the `ValidatePendingAssessment::Final` case. The cumulative M6 probe
   patch (`patches/v8/0001-...`) added a `V8_TARGET_ARCH_RISCV32` log-and-
   continue path so we could enumerate every failing builtin during M6/M9
   triage. With the M10 InstructionSelector fix that escape hatch is no
   longer necessary; the verifier walks clean on rv32 mksnapshot.
3. **`code-assembler.h`** — switches the `BInt`, `AtomicInt64`,
   `AtomicUint64` type aliases from `V8_HOST_ARCH_32_BIT` to
   `V8_TARGET_ARCH_32_BIT`. Upstream's choice happens to work because for
   every shipped V8 cross-compile, host bitness == target bitness. It is
   strictly weaker than the M10 behaviour: for our chromium-rv32 build
   `V8_HOST_ARCH_32_BIT` is already true (because v8's mksnapshot toolchain
   builds as a 32-bit i386 binary on x86_64 hosts), but a 64-bit-host →
   RV32-target cross-compile would silently emit `Word64`
   `BigIntFromInt64()` CSA calls and force the Turboshaft
   `Int64LoweringReducer` to split them. Using the *target* macro pins the
   correct code path regardless of what host the v8 snapshot toolchain
   happens to be compiled for.
4. **`builtins-sharedarraybuffer-gen.cc`** — the matching change in the
   one CSA builtin that branches on the same macro.

## Why it's needed

The rv32 `kRiscvWord32AtomicPairLoad` codegen lowers to:

```asm
AddWord(a0, InputReg0, InputReg1)        # form address
PushCallerSaved(SaveFPRegsMode::kIgnore, a0, a1)
PrepareCallCFunction(1, 0, kScratchReg)
CallCFunction(atomic_pair_load_function, 1, 0)
PopCallerSaved(SaveFPRegsMode::kIgnore, a0, a1)
```

The InstructionSelector declared:

- inputs `(base, index)` with policy `MUST_HAVE_REGISTER` (allocator picks).
- outputs `(low, high)` with policy `FIXED_REGISTER: a0` and
  `FIXED_REGISTER: a1`.

This is a perfectly valid declaration for the *generated machine code*:
`a0`/`a1` are clobbered (output) and `(base, index)` live in caller-saved
regs so `PushCallerSaved` preserves them across the C call.

What it does **not** account for is values that are **live across the op
in registers `a0`/`a1`**. In `kAtomicsLoad` we have the constant Smi `1`
(virtual reg `v98`) sitting in `a0` from earlier in the function and
still live after the atomic load. The constraint resolver must spill that
constant before the load runs, and on this hot path it picks `a2`. But
`a2` is *also* where the allocator landed the address input (`v150`,
output of `RiscvAdd32`). The pre-load parallel move `[a2 := a0]` then
overwrites `a2` with the constant Smi `1`, so when
`AddWord(a0, a2, a3)` runs at the top of `kRiscvWord32AtomicPairLoad`,
the load reads the wrong address.

Pinning the two inputs to `a3`/`a4` (both caller-saved, both disjoint
from the FIXED `a0`/`a1` outputs) removes the option of choosing `a2`
for either input, so the constraint resolver can use `a2` as the
spill destination without aliasing the load's address register.

## Verification

- `milestones/m10-deferred-v8-cleanup/logs/atomicsload-trace-*.log`:
  pre-fix `mksnapshot` with `--trace-turbo --trace-turbo-filter=AtomicsLoad`
  showing 7 `phi-input vreg mismatch: actual=98 expected=150
  operand=[a0|R|w32]` lines under `kAtomicsLoad`.
- `milestones/m10-deferred-v8-cleanup/logs/atomicload-pin-*.log`: same
  mksnapshot after pinning, showing **0** mismatches.
- `milestones/m10-deferred-v8-cleanup/logs/m10-strict-build-*.log`: full
  `content_shell` rebuild with the upstream `CHECK_EQ` restored *and*
  `v8_enable_concurrent_mksnapshot=true` (both were off in M9), no
  abort.

## Effect on the rest of the port

- `v8_enable_concurrent_mksnapshot` flips from `false` (M6/M9) to `true`.
- The `register-allocator-verifier` runs full upstream `CHECK_EQ` on rv32
  again; there is no rv32-specific code path left in the verifier.
- No effect on rv64 or any non-riscv backend.
- No new dependencies, no new symbols, no new GN args.

## Scope

- Four files, ~25 lines of semantic change.
- Touches RV32 backend code only (instruction-selector-riscv32.cc) plus
  cross-arch source on macros that already exist (`V8_TARGET_ARCH_*`).
- Independent of `0003-chromium-rv32-m9-trampoline-osr-urgency-scratch.patch`;
  the two patches stack cleanly.
