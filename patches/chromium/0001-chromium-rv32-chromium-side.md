# Chromium 0001 — RV32 changes inside `src/chromium/src/`

The big one. ~520 lines of diff across PartitionAlloc, base, build, and a
handful of net/cert files.

## What it does (by area)

### PartitionAlloc (`base/allocator/partition_allocator/`)
* `partition_alloc.gni` — `current_cpu == "riscv32"` joins the 32-bit
  pointer cohort. Without this, PA's `has_64_bit_pointers` falls into
  an `assert(false)` because RV32 wasn't enumerated.
* `src/partition_alloc/build_config.h` — RV32 ISA detection.
* `src/partition_alloc/spinning_mutex.cc` — RV32 fallback when the
  futex/sysv `umtx` paths are guarded behind 64-bit-only `#ifdef`s.

### base/ runtime support
* `base/profiler/stack_copier_signal.cc` — skip the
  ARM/x86-specific async-unwind code on RV32 (we don't expose CPU
  profiling on this port).
* `base/sampling_heap_profiler/lock_free_bloom_filter.h` — 32-bit-safe
  bitmap-word layout.
* `base/synchronization/lock_subtle.h` — RV32 atomic-size gating.

### build/
* `build/build_config.h` — defines `ARCH_CPU_RISCV32`, the matching
  `ARCH_CPU_32_BITS`, and `ARCH_CPU_LITTLE_ENDIAN`.
* `build/config/BUILD.gn` — RV32 added to the toolchain dispatch.

### net/cert + chrome root store
* The Chrome Root Store helpers are normally gated on `USE_NSS_CERTS`;
  this patch loosens that so we get cert verification without dragging
  NSS into the sysroot.

## What it does NOT do

* It does not enable Maglev or Sparkplug tiers (those are off in the GN
  args, see `configs/gn/content-shell.args.gn`).
* It does not touch SwiftShader, ANGLE, or LSS — those have their own
  `0002-…` patches against their respective sub-checkouts.
* It does not "fix" the deferred V8 correctness issues; the workarounds
  for those are in the V8 patches.
