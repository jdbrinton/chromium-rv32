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

Each patch has a sibling `.md` describing its intent, the files it touches,
and any known-deferred follow-ups.
