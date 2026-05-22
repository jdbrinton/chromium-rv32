# Chromium 0002 — RV32 fixes inside Chromium's pinned V8 checkout

**Target:** `src/chromium/src/v8/`.

These are V8 fixes that only surface during a **Chromium** build of V8
(M4), not a standalone V8 build (M1). They are kept as a separate patch
from `patches/v8/0001-…` so the standalone d8 milestone stays
self-contained.

## Files

| File | Change |
|---|---|
| `src/codegen/riscv/macro-assembler-riscv.cc` | RV32-specific assembler tweaks for the Chromium-bundled V8. |
| `src/common/segmented-table.h` | 32-bit cage size — duplicated from V8 patch 0001; needed again here because Chromium pins a slightly different V8 SHA than the M1 standalone V8. |
| `src/heap/memory-pool.h` | Same as above. |

## Note

There is intentional overlap with `patches/v8/0001-chromium-rv32-cumulative.patch`.
Chromium's vendored V8 lives at a different commit than the M1 standalone V8
(`637ded7…`), and the two trees drift between releases; reapplying the same
logical fix is cheaper than maintaining a single per-file delta that has to
match two upstream bases.
