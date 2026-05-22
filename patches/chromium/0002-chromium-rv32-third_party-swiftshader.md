# Chromium 0002 — SwiftShader third_party RV32 fix

**Target:** `src/chromium/src/third_party/swiftshader/`.

## Background

SwiftShader is Chromium's software GL/Vulkan renderer. Its Subzero
JIT-style codegen only ships X86, X86_64, ARM32, and MIPS32 target
lowering modules — there is **no** RV32 backend. The GN args also
disable SwiftShader (`enable_swiftshader = false`,
`angle_enable_swiftshader = false`, `dawn_use_swiftshader = false`),
but a few `data_dep` chains and per-target `BUILD.gn` files still
unconditionally enumerate the supported CPUs and choke when RV32
matches none of them.

## What this patch does

| File | Change |
|---|---|
| `third_party/llvm-10.0/BUILD.gn` | Adds an RV32 source-set that is empty (no LLVM target lowering for RV32 in the bundled LLVM 10). |
| `third_party/llvm-16.0/BUILD.gn` | Same, for the vendored LLVM 16. |
| `third_party/marl/BUILD.gn` | Disables marl's fiber-switching asm on RV32 (marl ships fiber implementations for X86/X86_64/ARM32/ARM64/MIPS only). |

## Runtime consequence

SwiftShader is not built into our `content_shell`, so this never runs.
The Skia CPU rasteriser does all software rendering for the M6/M7
demos.
