# V8 0002 — build-system RV32 support

**Target:** `src/v8/build/` (V8's vendored `build/` git submodule;
matching commit `be09d50c38a902bf3ec39da64ff3773034b746fc` at the
Option-C pinned V8 SHA).

## What it does

Teaches the shared build system that `riscv32-linux-gnu` is a real
cross-compilation target:

| File | Change |
|---|---|
| `config/BUILD.gn` | RV32 case in the linker / compile-flag plumbing. |
| `config/clang/BUILD.gn` | Skip the compiler-rt builtin lookup when targeting `riscv32-unknown-linux-gnu` (the bundled Chromium clang doesn't ship it; we substitute an empty `libclang_rt.builtins.a` stub at build time — see `scripts/build-v8-d8.sh`). |
| `config/compiler/BUILD.gn` | RV32 ISA-detection clauses. |
| `config/rust.gni` | RV32 Rust toolchain target gating. |
| `rust/known-target-triples.txt` | Adds `riscv32-unknown-linux-gnu`. |
| `toolchain/linux/BUILD.gn` | Adds a `clang_riscv32` Linux cross-toolchain definition. |

## Note on the empty-archive stub

`config/clang/BUILD.gn` still emits a `-l<libclang_rt.builtins>` flag at
link time. The patch does not remove the flag; instead, the build script
creates an empty `ar` archive named `libclang_rt.builtins.a` under
`src/v8/third_party/llvm-build/.../lib/clang/*/lib/riscv32-unknown-linux-gnu/`
so the linker can locate "something" and we never actually need any
compiler-rt symbol (V8 cross-links with our own `libgcc.a`).
