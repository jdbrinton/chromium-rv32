#!/usr/bin/env python3
"""chromium-rv32 M7 CDP -> RFB (VNC) bridge.

Bridges the rv32 ``content_shell`` running inside the qemu-system-riscv32 guest
to a host-side VNC client (e.g. TigerVNC / RealVNC / a Windows VNC viewer that
connects through WSL2 to ``localhost:<rfb-port>``).

Architecture:

    rv32 content_shell  -- CDP screencast (JPEG over WebSocket) -->  this bridge
    rv32 content_shell  <-- CDP Input.dispatch*                  --  this bridge
                                                                          ^
                                              RFB v3.8 (TCP)              |
              user's VNC client     <-- pixels & cursor & input  -->  this bridge

Pixels in the VNC window are **rasterised by the rv32 content_shell process**
running on the guest; the bridge does no rendering, only transcoding (JPEG ->
BGRX framebuffer) and protocol translation. User input arrives on the RFB
socket and is forwarded to content_shell over CDP.

The bridge needs the CDP port forwarded from the guest:

    qemu-system-riscv32 ... -netdev user,id=net0,hostfwd=tcp:127.0.0.1:9222-:9222

which the M7 ``--gui`` mode of ``scripts/70-boot-chromium-guest.sh`` adds, on
top of the existing M6 port forward.

Usage:
    cdp-vnc-bridge.py [--cdp-host 127.0.0.1] [--cdp-port 9222]
                      [--rfb-host 127.0.0.1] [--rfb-port 5901]
                      [--connect-timeout 240] [--quality 70]
                      [--fps-cap 15]

Limitations (documented in milestones/m7-interactive-gui/STATUS.md):
  * raw encoding only -- single full-frame upload per refresh; CPU-bound on
    rv32 because content_shell still does the rasterise on the guest;
  * one concurrent VNC client (subsequent connections wait or are dropped);
  * keyboard mapping is X11-keysym -> DOM ``key`` for ASCII + a handful of
    named keys (arrows, enter, backspace, tab, esc, modifiers);
  * cursor compositing happens client-side; bridge does not push a cursor
    pseudo-encoding.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import io
import json
import struct
import sys
import time
import urllib.error
import urllib.request

import websockets
from PIL import Image


# ----- CDP plumbing (shared shape with milestones/m6-svelte-in-browser
#       /probe/capture-screenshot.py) -----------------------------------------


def fetch_targets(host: str, port: int, timeout: float = 2.0) -> list[dict]:
    url = f"http://{host}:{port}/json"
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


async def find_page_target(host: str, port: int, connect_timeout: float) -> dict:
    deadline = time.time() + connect_timeout
    last_err = ""
    while time.time() < deadline:
        try:
            for t in fetch_targets(host, port):
                if t.get("type") == "page" and t.get("webSocketDebuggerUrl"):
                    return t
            last_err = "no page-type target yet"
        except (urllib.error.URLError, ConnectionError, OSError) as e:
            last_err = f"{type(e).__name__}: {e}"
        await asyncio.sleep(1.5)
    raise SystemExit(
        f"timed out after {connect_timeout:.0f}s waiting for {host}:{port}/json "
        f"to expose a page target; last: {last_err}"
    )


class CDPSession:
    """Minimal CDP client. Demultiplexes method responses (matched by ``id``)
    from event notifications (matched by ``method``)."""

    def __init__(self, ws):
        self.ws = ws
        self._next_id = 0
        self._pending: dict[int, asyncio.Future] = {}
        self.event_handlers: dict[str, list] = {}
        self._reader_task = asyncio.create_task(self._reader())

    def on(self, method: str, handler) -> None:
        self.event_handlers.setdefault(method, []).append(handler)

    async def _reader(self) -> None:
        try:
            async for raw in self.ws:
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                if "id" in msg:
                    fut = self._pending.pop(msg["id"], None)
                    if fut is not None and not fut.done():
                        if "error" in msg:
                            fut.set_exception(
                                RuntimeError(f"CDP error: {msg['error']}")
                            )
                        else:
                            fut.set_result(msg.get("result", {}))
                else:
                    handlers = self.event_handlers.get(msg.get("method", ""), [])
                    for h in handlers:
                        try:
                            res = h(msg.get("params", {}))
                            if asyncio.iscoroutine(res):
                                asyncio.create_task(res)
                        except Exception as e:                      # noqa: BLE001
                            print(f"  [bridge] event handler error: {e!r}",
                                  file=sys.stderr)
        except websockets.exceptions.ConnectionClosed:
            pass
        finally:
            for fut in self._pending.values():
                if not fut.done():
                    fut.set_exception(RuntimeError("CDP connection closed"))
            self._pending.clear()

    async def send(self, method: str, params: dict | None = None) -> dict:
        self._next_id += 1
        mid = self._next_id
        fut: asyncio.Future = asyncio.get_event_loop().create_future()
        self._pending[mid] = fut
        await self.ws.send(
            json.dumps({"id": mid, "method": method, "params": params or {}})
        )
        return await fut

    async def send_nowait(self, method: str, params: dict | None = None) -> None:
        """Fire-and-forget: skip response demux. Used for hot-path Input.* events
        where we don't need the (empty) ack and don't want to inflate the pending
        table on every mouse-move."""
        self._next_id += 1
        await self.ws.send(
            json.dumps(
                {"id": self._next_id, "method": method, "params": params or {}}
            )
        )

    async def aclose(self) -> None:
        self._reader_task.cancel()
        try:
            await self._reader_task
        except (asyncio.CancelledError, Exception):  # noqa: BLE001
            pass


# ----- Framebuffer state -----------------------------------------------------


class Framebuffer:
    """Shared BGRX framebuffer + dirty-rect tracker. CDP screencast writes here;
    RFB server reads. Width/height learned from the first screencast frame.

    ``stale`` is flipped on by the bridge when the upstream CDP connection
    drops. Writers that were blocked waiting for a fresh frame wake up and
    emit the *last* frame they have so connected RFB clients see a static
    final-frame snapshot instead of hanging.
    """

    def __init__(self) -> None:
        self.width: int = 0
        self.height: int = 0
        self.bgrx: bytearray = bytearray()
        self.generation: int = 0          # incremented on every new frame
        self.cond = asyncio.Condition()   # notified on every new frame
        self.ready_event = asyncio.Event()  # set once width/height are known
        self.stale: bool = False

    async def write_from_jpeg(self, jpeg_bytes: bytes) -> None:
        img = Image.open(io.BytesIO(jpeg_bytes)).convert("RGB")
        w, h = img.size
        # PIL RGB -> BGRX. tobytes("raw", "BGRX") emits little-endian BGRX,
        # which matches the RFB pixel format we advertise in ServerInit.
        bgrx = img.tobytes("raw", "BGRX")
        async with self.cond:
            self.width = w
            self.height = h
            self.bgrx = bytearray(bgrx)
            self.generation += 1
            self.ready_event.set()
            self.cond.notify_all()

    async def mark_stale(self) -> None:
        """Called when the CDP feed stops. Bumps generation once more so any
        writer blocked on ``cond.wait_for`` exits, then leaves the buffer
        contents untouched. Subsequent FB-update-requests still return the
        last good frame."""
        async with self.cond:
            if self.stale:
                return
            self.stale = True
            self.generation += 1
            self.cond.notify_all()


# ----- RFB v3.8 server -------------------------------------------------------


RFB_VERSION = b"RFB 003.008\n"

# Client -> Server message types
CMSG_SET_PIXEL_FORMAT = 0
CMSG_SET_ENCODINGS = 2
CMSG_FB_UPDATE_REQUEST = 3
CMSG_KEY_EVENT = 4
CMSG_POINTER_EVENT = 5
CMSG_CLIENT_CUT_TEXT = 6

# Server -> Client message types
SMSG_FB_UPDATE = 0

# Encodings
ENC_RAW = 0

# We hand the client a single fixed BGRX little-endian PIXEL_FORMAT. Modern
# VNC clients (TigerVNC, RealVNC, vncviewer) accept it; if a client tries to
# SetPixelFormat to something else we politely accept the request and keep
# sending BGRX -- in practice no client does that without first negotiating
# encodings.
PIXEL_FORMAT_BGRX = struct.pack(
    "!BBBBHHHBBB3x",
    32,      # bits-per-pixel
    24,      # depth
    0,       # big-endian-flag (0 = LE)
    1,       # true-color-flag
    255,     # red-max
    255,     # green-max
    255,     # blue-max
    16,      # red-shift
    8,       # green-shift
    0,       # blue-shift
)


async def read_exactly(reader: asyncio.StreamReader, n: int) -> bytes:
    """Block until ``n`` bytes have been read, or raise ``ConnectionError`` on
    short read (peer closed)."""
    buf = await reader.readexactly(n)
    return buf


async def rfb_handshake(reader, writer) -> None:
    writer.write(RFB_VERSION)
    await writer.drain()

    client_version = await read_exactly(reader, 12)
    if not client_version.startswith(b"RFB 003."):
        raise ConnectionError(f"unsupported RFB version from client: "
                              f"{client_version!r}")

    # Security: offer only "None" (type 1), the standard choice for trusted
    # localhost links.
    writer.write(struct.pack("!BB", 1, 1))
    await writer.drain()

    sec_type = (await read_exactly(reader, 1))[0]
    if sec_type != 1:
        raise ConnectionError(f"client picked unsupported security type {sec_type}")

    # SecurityResult = 0 (OK). v3.8 sends this even for "None".
    writer.write(struct.pack("!I", 0))
    await writer.drain()

    # ClientInit (shared-flag).
    _ = await read_exactly(reader, 1)


async def send_server_init(writer, fb: Framebuffer, name: bytes) -> None:
    payload = struct.pack("!HH", fb.width, fb.height)
    payload += PIXEL_FORMAT_BGRX
    payload += struct.pack("!I", len(name)) + name
    writer.write(payload)
    await writer.drain()


def encode_raw_rect(x: int, y: int, w: int, h: int, fb_bytes: bytes,
                    fb_w: int) -> bytes:
    """Encode one raw RFB rectangle. We crop ``fb_bytes`` (full BGRX
    framebuffer of width ``fb_w``) to the requested rect.
    """
    header = struct.pack("!HHHHi", x, y, w, h, ENC_RAW)
    if x == 0 and w == fb_w:
        # Whole-row slices: one contiguous slice from the BGRX buffer.
        start = y * fb_w * 4
        end = (y + h) * fb_w * 4
        return header + bytes(fb_bytes[start:end])
    # Per-row slice (handles partial-width rects).
    out = bytearray(header)
    row_stride = fb_w * 4
    base = y * row_stride + x * 4
    width_bytes = w * 4
    for _i in range(h):
        out.extend(fb_bytes[base:base + width_bytes])
        base += row_stride
    return bytes(out)


async def send_full_frame(writer, fb: Framebuffer) -> int:
    """Send one whole-screen FramebufferUpdate. Returns the generation number
    that was sent so the caller can update its watermark."""
    async with fb.cond:
        gen = fb.generation
        w, h = fb.width, fb.height
        snapshot = bytes(fb.bgrx)
    header = struct.pack("!BxH", SMSG_FB_UPDATE, 1)        # 1 rect
    rect = encode_raw_rect(0, 0, w, h, snapshot, w)
    writer.write(header + rect)
    await writer.drain()
    return gen


# ----- RFB input -> CDP Input.dispatch* --------------------------------------


# X11 keysym -> (CDP key, CDP code, optional text). Only common, non-modifier
# keys are mapped here; printable ASCII is handled inline below.
KEYSYM_TO_DOM: dict[int, tuple[str, str, str | None]] = {
    0xff08: ("Backspace",     "Backspace",   None),
    0xff09: ("Tab",           "Tab",         "\t"),
    0xff0d: ("Enter",         "Enter",       "\r"),
    0xff1b: ("Escape",        "Escape",      None),
    0xff50: ("Home",          "Home",        None),
    0xff51: ("ArrowLeft",     "ArrowLeft",   None),
    0xff52: ("ArrowUp",       "ArrowUp",     None),
    0xff53: ("ArrowRight",    "ArrowRight",  None),
    0xff54: ("ArrowDown",     "ArrowDown",   None),
    0xff55: ("PageUp",        "PageUp",      None),
    0xff56: ("PageDown",      "PageDown",    None),
    0xff57: ("End",           "End",         None),
    0xff63: ("Insert",        "Insert",      None),
    0xff7f: ("NumLock",       "NumLock",     None),
    0xffe1: ("Shift",         "ShiftLeft",   None),
    0xffe2: ("Shift",         "ShiftRight",  None),
    0xffe3: ("Control",       "ControlLeft", None),
    0xffe4: ("Control",       "ControlRight", None),
    0xffe9: ("Alt",           "AltLeft",     None),
    0xffea: ("Alt",           "AltRight",    None),
    0xffeb: ("Meta",          "MetaLeft",    None),
    0xffec: ("Meta",          "MetaRight",   None),
    0xffff: ("Delete",        "Delete",      None),
}


def keysym_to_cdp(keysym: int) -> tuple[str, str, str | None] | None:
    if keysym in KEYSYM_TO_DOM:
        return KEYSYM_TO_DOM[keysym]
    # X11 keysyms in [0x20..0x7e] are direct ASCII for printable characters
    # ("Latin-1" subrange). Map to DOM ``key`` = the character itself and
    # ``code`` = best-effort:
    if 0x20 <= keysym <= 0x7e:
        ch = chr(keysym)
        upper = ch.upper()
        if "A" <= upper <= "Z":
            code = f"Key{upper}"
        elif "0" <= ch <= "9":
            code = f"Digit{ch}"
        else:
            # Punctuation: not all DOM ``code`` names are stable across layouts.
            # An empty ``code`` is acceptable to CDP and downstream JS rarely
            # cares; the ``key`` and ``text`` fields are what reach
            # ``KeyboardEvent.key`` on the page.
            code = ""
        return (ch, code, ch)
    return None


# RFB button-mask bits -> (CDP button name, scroll delta y). Bits 3 and 4 are
# wheel events emitted as discrete press+release pairs by VNC clients.
RFB_BUTTON_BITS = [
    ("left",    0),
    ("middle",  0),
    ("right",   0),
    ("none",   -1),   # wheel up
    ("none",    1),   # wheel down
    ("back",    0),
    ("forward", 0),
]


class InputForwarder:
    """Translates RFB pointer/key events to CDP Input.dispatch* calls. Keeps a
    small amount of per-connection state (last button-mask, last position) so
    we can detect press vs release transitions and emit ``mouseMoved`` only
    when coordinates actually change."""

    def __init__(self, cdp: CDPSession) -> None:
        self.cdp = cdp
        self.prev_mask = 0
        self.prev_x = -1
        self.prev_y = -1
        # Track which key codes are currently down so the page sees a clean
        # press/release pair even if a misbehaving VNC client never sends a
        # KeyUp for some keysyms (rare, but happens with sticky modifiers).
        self.down_codes: set[str] = set()

    async def handle_pointer(self, mask: int, x: int, y: int) -> None:
        # 1. Position update first (CDP mouseMoved before press/release matches
        #    how real input subsystems sequence events).
        if x != self.prev_x or y != self.prev_y:
            await self.cdp.send_nowait("Input.dispatchMouseEvent", {
                "type": "mouseMoved",
                "x": x, "y": y,
                "button": "none",
                "buttons": self._cdp_buttons_mask(mask),
            })
            self.prev_x, self.prev_y = x, y

        # 2. Button-mask transitions -> press/release pairs (and wheel ticks).
        changed = mask ^ self.prev_mask
        for bit, (name, wheel) in enumerate(RFB_BUTTON_BITS):
            if not (changed & (1 << bit)):
                continue
            now_down = bool(mask & (1 << bit))
            if wheel != 0:
                if now_down:
                    # Wheel "press" -> one CDP wheel tick. RFB clients emit
                    # the matching "release" immediately; we ignore it.
                    await self.cdp.send_nowait("Input.dispatchMouseEvent", {
                        "type": "mouseWheel",
                        "x": x, "y": y,
                        "button": "none",
                        "deltaX": 0,
                        "deltaY": wheel * 120,    # CSS pixel-equivalent
                    })
                continue
            await self.cdp.send_nowait("Input.dispatchMouseEvent", {
                "type": "mousePressed" if now_down else "mouseReleased",
                "x": x, "y": y,
                "button": name,
                "buttons": self._cdp_buttons_mask(mask if now_down
                                                 else self.prev_mask),
                "clickCount": 1,
            })
        self.prev_mask = mask

    @staticmethod
    def _cdp_buttons_mask(rfb_mask: int) -> int:
        # CDP `buttons` is a DOM-style bitfield: 1=left, 2=right, 4=middle.
        out = 0
        if rfb_mask & 0x01:
            out |= 1
        if rfb_mask & 0x02:
            out |= 4
        if rfb_mask & 0x04:
            out |= 2
        return out

    async def handle_key(self, down: bool, keysym: int) -> None:
        mapped = keysym_to_cdp(keysym)
        if mapped is None:
            return
        key, code, text = mapped
        if down:
            params = {
                "type": "keyDown",
                "key": key,
                "code": code,
            }
            if text is not None:
                params["text"] = text
            await self.cdp.send_nowait("Input.dispatchKeyEvent", params)
            self.down_codes.add(code)
            # For printable characters, CDP wants a separate ``char`` event
            # so that text-input widgets receive an ``input`` event.
            if text is not None and text not in ("\r", "\t"):
                await self.cdp.send_nowait("Input.dispatchKeyEvent", {
                    "type": "char",
                    "text": text,
                    "key": key,
                    "code": code,
                })
        else:
            await self.cdp.send_nowait("Input.dispatchKeyEvent", {
                "type": "keyUp",
                "key": key,
                "code": code,
            })
            self.down_codes.discard(code)


# ----- RFB client connection handler -----------------------------------------


async def serve_rfb_client(reader, writer, fb: Framebuffer, cdp: CDPSession,
                           single_client_slot: asyncio.Semaphore) -> None:
    peer = writer.get_extra_info("peername")
    print(f"[{time.strftime('%H:%M:%S')}] RFB client connecting: {peer}")

    # Single-client serialisation: subsequent connections block until the
    # current one disconnects.
    async with single_client_slot:
        try:
            await rfb_handshake(reader, writer)
            await fb.ready_event.wait()
            await send_server_init(writer, fb,
                                   b"chromium-rv32 M7 (rv32 content_shell)")
            print(f"[{time.strftime('%H:%M:%S')}] RFB handshake OK; framebuffer "
                  f"{fb.width}x{fb.height}, client {peer}")

            input_fwd = InputForwarder(cdp)
            sent_generation = -1
            # We push a fresh full frame whenever:
            #   * a new CDP screencast frame has arrived (fb.generation
            #     advanced past sent_generation), AND
            #   * the client has asked for an update (incremental or full).
            pending_update_request = asyncio.Event()
            stop_signal = asyncio.Event()

            async def reader_loop() -> None:
                try:
                    while not stop_signal.is_set():
                        msg_type_b = await read_exactly(reader, 1)
                        msg_type = msg_type_b[0]
                        if msg_type == CMSG_SET_PIXEL_FORMAT:
                            await read_exactly(reader, 3 + 16)
                        elif msg_type == CMSG_SET_ENCODINGS:
                            _pad = await read_exactly(reader, 1)
                            n = struct.unpack("!H",
                                              await read_exactly(reader, 2))[0]
                            await read_exactly(reader, 4 * n)
                        elif msg_type == CMSG_FB_UPDATE_REQUEST:
                            _ = await read_exactly(reader, 9)
                            pending_update_request.set()
                        elif msg_type == CMSG_KEY_EVENT:
                            data = await read_exactly(reader, 7)
                            down = data[0] != 0
                            keysym = struct.unpack("!I", data[3:7])[0]
                            await input_fwd.handle_key(down, keysym)
                        elif msg_type == CMSG_POINTER_EVENT:
                            data = await read_exactly(reader, 5)
                            mask = data[0]
                            x, y = struct.unpack("!HH", data[1:5])
                            await input_fwd.handle_pointer(mask, x, y)
                        elif msg_type == CMSG_CLIENT_CUT_TEXT:
                            _pad = await read_exactly(reader, 3)
                            n = struct.unpack("!I",
                                              await read_exactly(reader, 4))[0]
                            await read_exactly(reader, n)
                        else:
                            print(f"  [bridge] unknown RFB client msg type "
                                  f"{msg_type}; dropping client")
                            stop_signal.set()
                            break
                except (asyncio.IncompleteReadError, ConnectionError):
                    pass
                finally:
                    stop_signal.set()
                    pending_update_request.set()  # wake writer for shutdown

            async def writer_loop() -> None:
                nonlocal sent_generation
                try:
                    while not stop_signal.is_set():
                        await pending_update_request.wait()
                        if stop_signal.is_set():
                            return
                        # Wait until there's a new frame to send (avoid
                        # busy-looping if the client asks for an update with
                        # no new pixels yet).
                        if fb.generation == sent_generation:
                            async with fb.cond:
                                await fb.cond.wait_for(
                                    lambda: fb.generation != sent_generation
                                            or stop_signal.is_set()
                                )
                            if stop_signal.is_set():
                                return
                        pending_update_request.clear()
                        sent_generation = await send_full_frame(writer, fb)
                except (ConnectionError, BrokenPipeError):
                    pass
                finally:
                    stop_signal.set()

            await asyncio.gather(reader_loop(), writer_loop(),
                                 return_exceptions=True)
        except (asyncio.IncompleteReadError, ConnectionError) as e:
            print(f"  [bridge] RFB client {peer} disconnected during "
                  f"handshake: {e!r}")
        finally:
            try:
                writer.close()
                await writer.wait_closed()
            except Exception:                                # noqa: BLE001
                pass
            print(f"[{time.strftime('%H:%M:%S')}] RFB client gone: {peer}")


# ----- top-level -------------------------------------------------------------


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--cdp-host", default="127.0.0.1")
    p.add_argument("--cdp-port", default=9222, type=int)
    p.add_argument("--rfb-host", default="127.0.0.1")
    p.add_argument("--rfb-port", default=5901, type=int)
    p.add_argument("--connect-timeout", default=240.0, type=float)
    p.add_argument(
        "--quality", default=70, type=int,
        help="JPEG quality (1..100) for the CDP screencast",
    )
    p.add_argument(
        "--fps-cap", default=15, type=int,
        help="cap CDP screencast frame rate by setting everyNthFrame "
             "(content_shell will emit ~60/N fps). Set to 1 for max.",
    )
    p.add_argument(
        "--max-width", default=1280, type=int,
        help="screencast max_width passed to Page.startScreencast",
    )
    p.add_argument(
        "--max-height", default=800, type=int,
        help="screencast max_height passed to Page.startScreencast",
    )
    return p.parse_args()


async def amain() -> int:
    args = parse_args()

    print(f"[{time.strftime('%H:%M:%S')}] finding rv32 content_shell DevTools "
          f"at {args.cdp_host}:{args.cdp_port} (timeout "
          f"{args.connect_timeout:.0f}s)")
    target = await find_page_target(args.cdp_host, args.cdp_port,
                                    args.connect_timeout)
    ws_url = target["webSocketDebuggerUrl"]
    print(f"[{time.strftime('%H:%M:%S')}] target: {target.get('url')}")
    print(f"[{time.strftime('%H:%M:%S')}] ws:     {ws_url}")

    fb = Framebuffer()
    single_client_slot = asyncio.Semaphore(1)

    async with websockets.connect(ws_url, max_size=64 * 1024 * 1024) as ws:
        cdp = CDPSession(ws)
        try:
            await cdp.send("Runtime.enable")
            await cdp.send("Page.enable")

            async def on_screencast(params: dict) -> None:
                # 1. consume the frame
                try:
                    raw = base64.b64decode(params["data"])
                    await fb.write_from_jpeg(raw)
                except Exception as e:                       # noqa: BLE001
                    print(f"  [bridge] screencast decode error: {e!r}",
                          file=sys.stderr)
                # 2. ack so content_shell will send the next one
                sid = params.get("sessionId")
                if sid is not None:
                    await cdp.send_nowait("Page.screencastFrameAck",
                                          {"sessionId": sid})

            cdp.on("Page.screencastFrame", on_screencast)

            # Background watcher: when the CDP reader task finishes (i.e. the
            # WebSocket dropped because content_shell exited), wake any
            # blocked RFB writers so they emit the last frame instead of
            # hanging waiting for a new one that will never arrive.
            async def cdp_close_watchdog() -> None:
                try:
                    await cdp._reader_task                   # noqa: SLF001
                except Exception:                            # noqa: BLE001
                    pass
                print(f"[{time.strftime('%H:%M:%S')}] CDP feed closed; "
                      f"freezing framebuffer at last frame "
                      f"(generation={fb.generation})")
                await fb.mark_stale()

            asyncio.create_task(cdp_close_watchdog())

            # Start streaming.
            every_nth = max(1, int(args.fps_cap and 60 / max(args.fps_cap, 1)))
            await cdp.send("Page.startScreencast", {
                "format": "jpeg",
                "quality": int(args.quality),
                "maxWidth": int(args.max_width),
                "maxHeight": int(args.max_height),
                "everyNthFrame": every_nth,
            })
            print(f"[{time.strftime('%H:%M:%S')}] CDP screencast started "
                  f"(quality={args.quality}, everyNthFrame={every_nth}, "
                  f"max={args.max_width}x{args.max_height})")

            server = await asyncio.start_server(
                lambda r, w: serve_rfb_client(r, w, fb, cdp,
                                              single_client_slot),
                host=args.rfb_host, port=args.rfb_port,
            )
            addr = server.sockets[0].getsockname()
            print(f"[{time.strftime('%H:%M:%S')}] RFB server listening on "
                  f"{addr[0]}:{addr[1]} -- connect any VNC client there")
            print("[bridge] ready. Ctrl-C to stop.")
            async with server:
                await server.serve_forever()
        finally:
            try:
                await cdp.send("Page.stopScreencast")
            except Exception:                                # noqa: BLE001
                pass
            await cdp.aclose()
    return 0


def main() -> int:
    try:
        return asyncio.run(amain())
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
