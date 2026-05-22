# GN args

Two argument files, both consumed by the corresponding build scripts:

| File | Consumer | What it builds |
|---|---|---|
| `v8-d8.args.gn` | `scripts/build-v8-d8.sh` | Standalone V8 `d8` for `riscv32-linux-gnu`. |
| `content-shell.args.gn` | `scripts/build-content-shell.sh` | Chromium `content_shell` (headless Ozone) for `riscv32-linux-gnu`. |

Both files contain the literal placeholder
`TO_BE_REPLACED_WITH_ABSOLUTE_SYSROOT_PATH`. The build scripts use
`sed` to substitute the absolute path of `toolchain/sysroot/` (produced
by `scripts/build-sysroot.sh`) at `gn gen` time.

## Why a separate file per build?

The two files share most flags (target_cpu, sysroot, ccache, disabled
sandbox, etc.), but `content-shell.args.gn` adds ~80 more flags to
disable SwiftShader, Dawn, FFmpeg, XNNPACK, Vulkan, NSS, PulseAudio,
ALSA, GTK, Qt, and the headless Ozone preset.

Keeping the two files distinct means a developer iterating on d8 alone
doesn't have to ferret out which `content_shell`-only flag broke their
small build, and vice versa.
