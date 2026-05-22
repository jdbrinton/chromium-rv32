# Chromium patches

Applied on top of the pinned Chromium snapshot fetched by
`scripts/fetch-sources.sh`. Applied non-interactively by
`scripts/apply-patches.sh`, in numeric order.

| Patch | Scope | Target tree |
|---|---|---|
| `0001-chromium-rv32-chromium-side.patch` | All RV32-aware changes inside `src/chromium/src/` itself. PartitionAlloc 32-bit pointer support, build_config flag plumbing, net/cert/system_trust_store fallbacks, dawn/swiftshader disablers, etc. | `src/chromium/src/` |
| `0002-chromium-rv32-third_party-angle.patch` | ANGLE GN gating: treat RV32 as a 32-bit ISA in `gni/angle.gni`. | `src/chromium/src/third_party/angle/` |
| `0002-chromium-rv32-third_party-lss.patch` | linux-syscall-support RV32 path: a small set of syscall wrappers for `__riscv && __riscv_xlen==32`. | `src/chromium/src/third_party/lss/` |
| `0002-chromium-rv32-third_party-swiftshader.patch` | SwiftShader LLVM/marl gating: disables RV32 paths whose codegen library only ships X86/X86_64/ARM/MIPS backends. | `src/chromium/src/third_party/swiftshader/` |
| `0002-chromium-rv32-v8.patch` | A handful of V8 fixes that surface only inside the Chromium build of V8 (post-M1). | `src/chromium/src/v8/` |
| `0003-chromium-rv32-m10-rv32-user-agent.patch` | M10: surface the real `riscv32` / `riscv` tokens in `navigator.userAgent` and `navigator.userAgentData.architecture` (`components/embedder_support/user_agent_utils.cc`) instead of the `x86_64` default. Also silences the per-startup "Unrecognized CPU Architecture: riscv32" DLOG. | `src/chromium/src/` |

The numbering convention: `0001-…` and `0003-…` live in the main
Chromium repo; all `0002-…` patches live inside one of Chromium's
submodules / pinned third-party trees (each is a separate git checkout
under `src/chromium/src/third_party/…` or `src/chromium/src/v8/`).
