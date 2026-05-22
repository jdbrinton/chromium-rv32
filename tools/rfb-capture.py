#!/usr/bin/env python3
"""chromium-rv32 M7 RFB capture / acceptance harness.

Connects to a running ``cdp-vnc-bridge.py`` (RFB v3.8 server) and:

  1. completes the RFB handshake (PixelFormat is whatever the server sends;
     we accept BGRX little-endian),
  2. requests a non-incremental FramebufferUpdate covering the whole screen,
  3. waits for that update and decodes the raw rect into a PNG,
  4. optionally injects a click at ``--click X Y`` and waits ``--settle`` for
     the page to react before capturing a second frame,
  5. writes one or two PNGs (``--output``, ``--output-after``).

This script is dual-use:
  * smoke test of the bridge (handshake parses cleanly, raw rect arrives),
  * M7 acceptance screenshot capture (single command produces the artefact
    used in milestones/m7-interactive-gui/STATUS.md).

It is **not** a general-purpose VNC client; it only understands raw-encoded
rectangles and BGRX pixels because that is what cdp-vnc-bridge.py emits.
A real VNC client (TigerVNC, RealVNC, Windows-side VNC viewer over WSL2)
is what the human user connects with day-to-day.
"""

from __future__ import annotations

import argparse
import asyncio
import struct
import sys
import time

from PIL import Image


RFB_VERSION = b"RFB 003.008\n"


class RFBClient:
    def __init__(self, host: str, port: int) -> None:
        self.host = host
        self.port = port
        self.reader: asyncio.StreamReader | None = None
        self.writer: asyncio.StreamWriter | None = None
        self.width = 0
        self.height = 0
        self.pixel_format: bytes = b""

    async def connect(self, timeout: float) -> None:
        deadline = time.time() + timeout
        last_err = None
        while time.time() < deadline:
            try:
                self.reader, self.writer = await asyncio.open_connection(
                    self.host, self.port,
                )
                return
            except (ConnectionRefusedError, OSError) as e:
                last_err = e
                await asyncio.sleep(0.5)
        raise SystemExit(
            f"could not connect to RFB server {self.host}:{self.port} "
            f"within {timeout:.0f}s: {last_err!r}"
        )

    async def handshake(self) -> None:
        assert self.reader is not None and self.writer is not None
        # ProtocolVersion
        server_ver = await self.reader.readexactly(12)
        if not server_ver.startswith(b"RFB 003."):
            raise RuntimeError(f"unsupported server RFB version {server_ver!r}")
        self.writer.write(RFB_VERSION)
        await self.writer.drain()

        # Security
        n_types = (await self.reader.readexactly(1))[0]
        if n_types == 0:
            reason_len = struct.unpack("!I", await self.reader.readexactly(4))[0]
            reason = await self.reader.readexactly(reason_len)
            raise RuntimeError(f"server refused: {reason!r}")
        types = await self.reader.readexactly(n_types)
        if 1 not in types:
            raise RuntimeError(f"server does not offer 'None' auth (got {types!r})")
        self.writer.write(b"\x01")
        await self.writer.drain()

        # SecurityResult (v3.8 sends this even for None)
        result = struct.unpack("!I", await self.reader.readexactly(4))[0]
        if result != 0:
            raise RuntimeError(f"security handshake failed (code {result})")

        # ClientInit: share the desktop
        self.writer.write(b"\x01")
        await self.writer.drain()

        # ServerInit
        init_head = await self.reader.readexactly(24)
        w, h = struct.unpack("!HH", init_head[:4])
        self.pixel_format = init_head[4:20]
        name_len = struct.unpack("!I", init_head[20:24])[0]
        name = await self.reader.readexactly(name_len)
        self.width, self.height = w, h
        print(f"  RFB server: {name.decode(errors='replace')!r} "
              f"-- {w}x{h}, pixel-format {self.pixel_format.hex()}")

        # SetEncodings: only Raw. cdp-vnc-bridge.py only sends Raw anyway, but
        # being explicit avoids any server-side surprises.
        encodings = [0]
        self.writer.write(struct.pack("!BBH", 2, 0, len(encodings)))
        self.writer.write(struct.pack(f"!{len(encodings)}i", *encodings))
        await self.writer.drain()

    async def request_full(self, incremental: bool = False) -> None:
        assert self.writer is not None
        self.writer.write(struct.pack("!BBHHHH", 3, 1 if incremental else 0,
                                      0, 0, self.width, self.height))
        await self.writer.drain()

    async def read_one_update(self) -> Image.Image:
        """Read exactly one FramebufferUpdate message (which may have multiple
        rects) and return a fresh full-screen PIL image. We composite each rect
        into a single in-memory canvas."""
        assert self.reader is not None
        canvas = Image.new("RGB", (self.width, self.height), (0, 0, 0))
        while True:
            head = await self.reader.readexactly(1)
            msg = head[0]
            if msg == 0:                                           # FB update
                _pad = await self.reader.readexactly(1)
                n_rects = struct.unpack("!H",
                                        await self.reader.readexactly(2))[0]
                for _ in range(n_rects):
                    x, y, w, h, enc = struct.unpack(
                        "!HHHHi", await self.reader.readexactly(12),
                    )
                    if enc != 0:
                        raise RuntimeError(
                            f"unexpected encoding {enc} (expected raw=0)"
                        )
                    raw = await self.reader.readexactly(w * h * 4)
                    # BGRX little-endian -> Pillow RGB.
                    rect = Image.frombytes("RGB", (w, h), bytes(raw),
                                           "raw", "BGRX")
                    canvas.paste(rect, (x, y))
                return canvas
            elif msg == 2:                                          # Bell
                continue
            elif msg == 3:                                          # ServerCutText
                _pad = await self.reader.readexactly(3)
                n = struct.unpack("!I",
                                  await self.reader.readexactly(4))[0]
                await self.reader.readexactly(n)
                continue
            else:
                raise RuntimeError(f"unknown server msg type {msg}")

    async def send_pointer(self, mask: int, x: int, y: int) -> None:
        assert self.writer is not None
        self.writer.write(struct.pack("!BBHH", 5, mask, x, y))
        await self.writer.drain()

    async def send_key(self, down: bool, keysym: int) -> None:
        assert self.writer is not None
        self.writer.write(struct.pack("!BBHI", 4, 1 if down else 0, 0, keysym))
        await self.writer.drain()

    async def close(self) -> None:
        if self.writer is None:
            return
        try:
            self.writer.close()
            await self.writer.wait_closed()
        except Exception:                                          # noqa: BLE001
            pass


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", default=5901, type=int)
    p.add_argument("--output", required=True,
                   help="PNG path for the initial frame")
    p.add_argument("--output-after",
                   help="PNG path for a second frame, taken after --click")
    p.add_argument("--click", nargs=2, type=int, metavar=("X", "Y"),
                   help="inject a left-button click at (X, Y) after the first capture")
    p.add_argument("--settle", default=1.0, type=float,
                   help="seconds to wait after click before second capture")
    p.add_argument("--connect-timeout", default=120.0, type=float)
    return p.parse_args()


async def amain() -> int:
    args = parse_args()
    c = RFBClient(args.host, args.port)
    print(f"[{time.strftime('%H:%M:%S')}] connecting to RFB {args.host}:{args.port} "
          f"(timeout {args.connect_timeout:.0f}s)")
    await c.connect(args.connect_timeout)
    print(f"[{time.strftime('%H:%M:%S')}] handshaking")
    await c.handshake()

    print(f"[{time.strftime('%H:%M:%S')}] requesting full framebuffer")
    await c.request_full(incremental=False)
    img = await c.read_one_update()
    img.save(args.output)
    print(f"[{time.strftime('%H:%M:%S')}] wrote {args.output} "
          f"({img.size[0]}x{img.size[1]})")

    if args.click and args.output_after:
        x, y = args.click
        print(f"[{time.strftime('%H:%M:%S')}] injecting click at ({x}, {y})")
        # mousemove -> press -> release, single left button (RFB bit 0).
        await c.send_pointer(0, x, y)
        await c.send_pointer(1, x, y)
        await c.send_pointer(0, x, y)
        await asyncio.sleep(args.settle)
        # The bridge pushes a fresh frame as soon as one arrives via CDP;
        # request another non-incremental update so we are guaranteed to
        # observe post-click pixels.
        await c.request_full(incremental=False)
        img2 = await c.read_one_update()
        img2.save(args.output_after)
        print(f"[{time.strftime('%H:%M:%S')}] wrote {args.output_after} "
              f"({img2.size[0]}x{img2.size[1]})")

    await c.close()
    return 0


def main() -> int:
    try:
        return asyncio.run(amain())
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
