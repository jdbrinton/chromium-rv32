# Interactive GUI under qemu-system-riscv32

The "render the page **and** let me click on it" path. Implemented as a
host-side bridge from the Chrome DevTools Protocol to RFB v3.8 — no
changes to the guest kernel, no Xorg/Weston inside the rv32 box.

## Why a host-side bridge rather than guest-side X

Three options were on the table:

1. **virtio-gpu + DRM + Xorg + content_shell --use-gl=…**
   Requires `CONFIG_DRM_VIRTIO_GPU`, an X server, an input stack, font
   packages, Mesa, and content_shell's Ozone X11 (not headless)
   backend. Five new moving parts each of which can fail
   independently.

2. **Linux framebuffer + content_shell with the directfb Ozone backend**
   directfb's Chromium support is dead; the framebuffer path inside
   content_shell has bit-rotted; and we'd still need a way to inject
   pointer/key input.

3. **Host-side bridge** — the one we shipped.
   content_shell already exposes CDP because we use that for
   screenshot capture. The bridge piggy-backs on
   `Page.startScreencast` (JPEG frames at 15 fps) for output and
   `Input.dispatch{Mouse,Key,Touch}Event` for input. Zero new kernel
   modules, zero new packages in the rootfs, ~30 KB of host-side
   Python.

The trade-off: the rendered frame travels JPEG → host → RGBA → RFB,
which adds 80–300 ms of latency. For demo / debug use it's fine; for
hard-real-time interaction you'd want a path-2-style solution.

## Architecture

```
content_shell (guest, port 9222)
    │
    │  Page.startScreencast → JPEG (640x480 by default)
    │  Input.dispatchMouseEvent / KeyEvent (host -> guest)
    │
    ▼
tools/cdp-vnc-bridge.py
    │  decode JPEG via Pillow, repack as RFB raw rect
    │  buffer one full frame; refuse to advance until pixels are stable
    │
    ▼
RFB v3.8 server on rfb-host:rfb-port (default 127.0.0.1:5901)
    │
    │  VNC viewer (any RFB v3.8 client)
    ▼
human
```

## Launching

```bash
scripts/run-guest.sh --svelte-host http://10.0.2.2:3000/ --gui
```

The script:

1. Boots the guest with `m6-svelte-timeout=3600` and
   `m6-no-poweroff` on the kernel command line, so the in-guest
   `content_shell` runs for an hour and the guest does **not** power
   off when the M6 acceptance prints its banner.
2. Bumps the host-side `boot_timeout` to 3700 s.
3. Spawns `tools/cdp-vnc-bridge.py` on `rfb-host:rfb-port`.
4. Tails the boot log to the screen and waits for ^C.

Connect any VNC v3.8 client (TigerVNC, RealVNC, Remmina, VNC Viewer,
…) to the printed address.

## VNC client compatibility

The bridge advertises RFB security type `None` (no auth) and offers
pixel format BGRX 32-bit little-endian. Encodings: only `raw`. Tested
clients:

| Client | Works | Notes |
|---|---|---|
| TigerVNC `vncviewer` | yes | Reference target. |
| RealVNC Viewer (Windows) | yes | Forces "Authentication: None" once at connect. |
| Remmina (Linux) | yes | — |
| VS Code Remote VNC | yes | — |
| TightVNC (Windows) | yes | — |

## WSL2 networking

If your VNC client lives on Windows and the rest is in WSL2, the
default `--rfb-host 127.0.0.1` is *not* reachable from Windows. Pick
one of:

* **Recommended:** `scripts/run-guest.sh --gui --rfb-host 0.0.0.0` and
  connect to `<WSL-eth0-IP>:5901` from Windows. The script prints
  that IP when you start with `--rfb-host 0.0.0.0`.
* `netsh interface portproxy add v4tov4 listenport=5901
  listenaddress=0.0.0.0 connectport=5901 connectaddress=<wsl-ip>` from
  a Windows PowerShell, then connect to `127.0.0.1:5901` on Windows.
* Run the VNC client from WSL2 itself (e.g. Remmina under WSLg).

WSL2's loopback forwarding is unreliable across distro restarts; the
`--rfb-host 0.0.0.0` path is the simplest.

**Security note:** RFB security type None means the bridge trusts
whoever can connect. With `--rfb-host 0.0.0.0` that includes the LAN.
Firewall accordingly.

## Input flow

Each RFB event from the client is translated by the bridge:

| RFB event | CDP call |
|---|---|
| `PointerEvent` (button=0) | `Input.dispatchMouseEvent type=mouseMoved x y` |
| `PointerEvent` (button bit transition 0→1) | `Input.dispatchMouseEvent type=mousePressed x y button=…` |
| `PointerEvent` (button bit transition 1→0) | `Input.dispatchMouseEvent type=mouseReleased x y button=…` |
| `KeyEvent` (down=1) | `Input.dispatchKeyEvent type=keyDown key text code modifiers` |
| `KeyEvent` (down=0) | `Input.dispatchKeyEvent type=keyUp key text code modifiers` |

X11 keysyms are translated to DOM `key`/`code` strings via a small
lookup table in `tools/cdp-vnc-bridge.py`. ASCII printable characters
get their `text` field set so JavaScript's `input` event sees them.

## Capture mode (acceptance harness)

```bash
scripts/run-guest.sh --svelte-host http://10.0.2.2:3000/ \
                     --gui-capture artifacts/runs/ \
                     --gui-click 320 240
```

This spawns the bridge **and** `tools/rfb-capture.py`. The harness:

1. Waits for the bridge to bind its socket AND for the `m6:all-green`
   sentinel to appear in the boot log.
2. Sleeps 8 s for paint stability.
3. Connects to the bridge as an RFB client, requests one update,
   writes the frame to `m7-interactive-<ts>.png`.
4. (If `--gui-click X Y` was supplied) sends a `PointerEvent`
   button-press + release at the given coordinates, waits 3 s, grabs
   another frame, writes it to `m7-interactive-<ts>-after-click.png`.

The two PNGs together are the M7 regression artefact: pre-click +
post-click pixels prove that input round-trips through the bridge.

## Known limitations

* Frame rate is capped by `Page.startScreencast`'s `everyNthFrame=4`
  (effectively ~15 fps). Increasing it past 30 fps quickly saturates
  the guest's CDP serialisation.
* No clipboard, no audio, no file transfer (RFB v3.8 standard
  optional extensions).
* The bridge buffers one *full* frame; a partially-received update
  from CDP will not be served. This is correct but means the very
  first frame after a CDP disconnect-reconnect cycle is the **last
  pre-disconnect** frame, slightly stale.
* Single VNC client at a time. If a second client connects, the first
  one's update stream gets multiplexed but pointer/key events from
  multiple clients can race.
