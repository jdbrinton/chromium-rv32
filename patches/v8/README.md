# V8 patches

These patches sit on top of the pinned V8 snapshot fetched by
`scripts/fetch-sources.sh`. They are applied non-interactively by
`scripts/apply-patches.sh`.

Pin: `637ded7fab21c745f197b071dc63ac19cff74ee3` (last commit before
upstream began deprecating the RV32 backend; documented in
[`../../docs/build.md`](../../docs/build.md)).

| Patch | Scope | Target tree |
|---|---|---|
| `0001-chromium-rv32-cumulative.patch` | Make standalone V8 `d8` cross-compile + run on RV32. | `src/v8/` |
| `0002-chromium-rv32-build-system.patch` | RV32 awareness in V8's vendored `build/` submodule (Rust target triples, clang compiler-rt stubs, GN toolchain, install-build-deps). | `src/v8/build/` (a separate git submodule) |
| `0003-chromium-rv32-m9-trampoline-osr-urgency-scratch.patch` | M9 correctness: fix `Generate_InterpreterEntryTrampoline` `feedback_cell` clobber that previously SEGV'd every long-running JS function on RV32. Single-line change to use a real macro-assembler scratch in `ResetFeedbackVectorOsrUrgency`. | `src/v8/` |
| `0004-chromium-rv32-m10-atomicpairload-pin-and-cleanup.patch` | M10 correctness: pin `VisitWord32AtomicPairLoad`'s `(base, index)` inputs to fixed `(a3, a4)` (disjoint from the FIXED `a0`/`a1` outputs) so the register-allocator's spill destination cannot alias the load address. Restores upstream `CHECK_EQ` in `register-allocator-verifier.cc` and flips `V8_HOST_ARCH_32_BIT` → `V8_TARGET_ARCH_32_BIT` for cross-compile robustness in `code-assembler.h` + `builtins-sharedarraybuffer-gen.cc`. Allows `v8_enable_concurrent_mksnapshot=true`. | `src/v8/` |

Each patch has a sibling `.md` describing its intent, the files it touches,
and any known-deferred follow-ups.
