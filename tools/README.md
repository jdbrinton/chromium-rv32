# Tools

Host-side helpers. Each is a standalone Python 3 script (Python ≥ 3.10).

| Tool | Purpose | Dependencies |
|---|---|---|
| `capture-screenshot.py` | Connects to `content_shell`'s CDP endpoint inside the guest, waits for the Svelte demo's `m6:all-green` sentinel, then calls `Page.captureScreenshot` and writes a PNG. M6 acceptance artefact. | `websockets`, `Pillow` |
| `cdp-vnc-bridge.py` | Subscribes to `content_shell`'s CDP screencast (JPEG frames) and re-publishes them over RFB v3.8 to any VNC viewer. Translates VNC pointer/key events back into CDP `Input.dispatchMouseEvent` / `Input.dispatchKeyEvent`. Provides M7's interactive GUI. | `websockets`, `Pillow` |
| `rfb-capture.py` | Minimal RFB v3.8 client. Connects to the bridge, captures one or two frames as PNG, optionally injects a click between them. M7 acceptance harness. | `Pillow` |

## Install dependencies

```bash
python3 -m pip install --user websockets pillow
```

(There is no `requirements.txt`; the dependency set is tiny and these
tools are designed to be run ad-hoc from the host.)

## Usage examples

Capture a screenshot once the M6 demo converges:

```bash
python3 tools/capture-screenshot.py \
    --output artifacts/m6.png
```

Run an interactive VNC session (started for you by
`scripts/run-guest.sh --gui`):

```bash
python3 tools/cdp-vnc-bridge.py \
    --cdp-host 127.0.0.1 --cdp-port 9222 \
    --rfb-host 127.0.0.1 --rfb-port 5901
# In another terminal:
vncviewer 127.0.0.1:5901
```

Capture two frames around a click (M7 input proof):

```bash
python3 tools/rfb-capture.py \
    --rfb-host 127.0.0.1 --rfb-port 5901 \
    --output artifacts/before-click.png \
    --click 320 240 \
    --output-after artifacts/after-click.png
```
