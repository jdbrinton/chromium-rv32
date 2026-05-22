# Chromium 0002 — ANGLE third_party RV32 fix

**Target:** `src/chromium/src/third_party/angle/`.

Two-line change, but compilation of ANGLE fails without it on RV32:

* `gni/angle.gni` — joins RV32 to the existing 32-bit-CPU cohort
  (`arm`, `x86`, `mipsel`, `s390`) so `angle_64bit_current_cpu` is
  initialised to `false` instead of left undefined.
* `src/common/SimpleMutex.cpp` — RV32-safe atomic-size gating for
  the spin-lock fallback.

Notes:

* The GN args also set `angle_enable_vulkan = false` and
  `angle_enable_swiftshader = false` (see
  `configs/gn/content-shell.args.gn`), so the larger ANGLE Vulkan/
  SwiftShader code paths never get exercised on RV32.
* This patch only fixes compilation. ANGLE's RV32 runtime behaviour
  is untested — we don't enable hardware GL.
