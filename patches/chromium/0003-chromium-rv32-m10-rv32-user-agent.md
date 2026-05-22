# patches/chromium/0003-chromium-rv32-m10-rv32-user-agent.patch

**Milestone:** M10 (deferred V8 cleanup + RV32 user agent).

**Target:** `components/embedder_support/user_agent_utils.cc` inside the
Chromium checkout that `scripts/fetch-chromium.sh` brings down.

## What this patch does

Adds two small `ARCH_CPU_RISCV32`/`ARCH_CPU_RISCV64` branches to
Chromium's User-Agent construction:

1. **`GetUnifiedPlatform()`** — on Linux, return `"X11; Linux riscv32"`
   (or `"X11; Linux riscv64"`) instead of the hard-coded
   `"X11; Linux x86_64"` default. This is the platform token that
   `navigator.userAgent` and the `Sec-CH-UA-Platform` header expose to
   sites.
2. **`GetCpuArchitecture()`** — accept `cpu_info` strings that start
   with `"riscv"` and return `"riscv"`. Without this, the function
   falls off the end of the architecture chain and Chromium emits a
   `Unrecognized CPU Architecture: <riscv32>` `DLOG` at every
   content_shell startup and reports an empty string in
   `navigator.userAgentData.architecture` / `Sec-CH-UA-Arch`.

## Why it's needed

In M9 we observed the rv32 `content_shell` reporting `Linux x86_64` in
its user agent — the rv32 guest was masquerading as a 64-bit Intel
host. This was confusing in our screenshots and also potentially
incorrect for any site that branches on `Sec-CH-UA-Platform` /
`Sec-CH-UA-Arch` (very few sites do, but the protocol surface is
mis-stated). The Svelte demo also surfaces the values directly so the
RV32 identity is visible end-to-end.

## Verification

* `milestones/m10-deferred-v8-cleanup/logs/m6-acceptance-*.log`: console
  sentinels `m10:client-ua:Mozilla/5.0 (X11; Linux riscv32) …` and
  `m10:client-ua-ch:arch=riscv:bitness=32:platform=Linux`.
* `milestones/m10-deferred-v8-cleanup/artifacts/m6-screenshot-m10-*.png`:
  the Svelte demo's "1b · browser identity (client-side)" card shows
  the rv32 user-agent and UA Client Hints values.

## Scope

* Single file; ~14 lines of new code.
* Only takes effect when Chromium is compiled with `ARCH_CPU_RISCV32`
  or `ARCH_CPU_RISCV64`; on x86_64 / arm64 / etc. the upstream code
  paths are unchanged.
* No new dependencies, no new GN args, no new build inputs.
