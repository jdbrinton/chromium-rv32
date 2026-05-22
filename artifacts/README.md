# artifacts/

Most of this directory is **gitignored**. The only things committed
are two small curated PNGs that show what a successful run looks like.

| File | What |
|---|---|
| `example-m6-all-green.png` (67 KB) | CDP `Page.captureScreenshot` of `content_shell` running the Svelte demo inside the rv32 guest, taken immediately after the page printed `m6:all-green`. All four indicator dots are green and the timestamp banner is populated. |
| `example-m7-click-proof.png` (287 KB) | Frame served by `tools/cdp-vnc-bridge.py` to a VNC client, captured *after* the bridge has injected a synthetic mouse click on the "bump counter" button. The counter has incremented, proving an end-to-end input round-trip from host RFB → bridge → CDP `Input.dispatchMouseEvent` → content_shell → Svelte reactive update → screencast → bridge → RFB. |

## Where runtime artefacts go

The scripts deposit fresh runs under `artifacts/runs/`:

* `artifacts/runs/m6-<timestamp>.png` — CDP screenshot from
  `scripts/run-guest.sh --screenshot`.
* `artifacts/runs/m7-interactive-<timestamp>.png` and
  `artifacts/runs/m7-interactive-<timestamp>-after-click.png` — RFB
  capture from `scripts/run-guest.sh --gui-capture`.

`artifacts/runs/` is gitignored entirely. If you want to publish a
specific captured frame, copy it up to `artifacts/` with a clear name
and negate it in `.gitignore`.

## Large artefacts (toolchain bundles, git bundles, ext4 images)

Not committed. These are all reproducible from the scripts. If you
want a way to share one — e.g. an x86_64-host pre-built
`chromium-rootfs.ext4` — host it externally and record the SHA-256 +
the download URL in `docs/build.md`. The current pipeline does not
include such an artefact registry.
