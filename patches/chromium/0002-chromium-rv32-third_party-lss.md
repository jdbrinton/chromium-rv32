# Chromium 0002 — linux-syscall-support RV32 fix

**Target:** `src/chromium/src/third_party/lss/`.

linux-syscall-support is Google's tiny header-only library that wraps
raw `syscall(2)`-style invocations without touching libc state. Its
header `linux_syscall_support.h` enumerates supported ISAs with a long
`#if defined(__i386__) || defined(__x86_64__) || …` block; RV32 isn't
in the list.

## What this patch adds

* `__riscv && __riscv_xlen == 32` is added to the supported-arch guard.
* A small RV32 syscall stub block (matches the existing RISC-V 64
  stubs, but uses the 32-bit ABI conventions for register allocation).

## Why it matters

Without LSS, `base/profiler/` and `base/debug/stack_trace_linux.cc`
won't link. The patch is purely build-fixing; LSS is rarely called at
runtime in our headless content_shell smoke test.
