#!/usr/bin/env python3
"""chromium-rv32 M6 screenshot capture.

Connects to the content_shell DevTools endpoint exposed by the rv32 guest
via the qemu user-net `hostfwd=tcp:127.0.0.1:9222-:9222` rule. Subscribes
to `Runtime.consoleAPICalled`, waits for the SvelteKit demo's
`m6:all-green` sentinel (printed by the page's $effect once hydration +
DOM update + fetch + SSE have all converged true), then calls
`Page.captureScreenshot` and writes the rendered PNG to `--output`.

This is the "rendered-frame" artifact for M6 acceptance criterion (5).
The page itself is rendered inside the rv32 V8 isolate running in
content_shell on the rv32 guest; the PNG comes back via CDP so we do not
need a graphical display attached to the guest.

Usage:
  capture-screenshot.py --output PATH.png
                        [--cdp-host 127.0.0.1] [--cdp-port 9222]
                        [--connect-timeout 240] [--allgreen-timeout 240]
                        [--no-wait-allgreen]
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
import sys
import time
import urllib.error
import urllib.request

import websockets


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--output", required=True, help="PNG destination path")
    p.add_argument("--cdp-host", default="127.0.0.1")
    p.add_argument("--cdp-port", default=9222, type=int)
    p.add_argument(
        "--connect-timeout",
        default=240.0,
        type=float,
        help="seconds to wait for the DevTools /json endpoint to come up",
    )
    p.add_argument(
        "--allgreen-timeout",
        default=240.0,
        type=float,
        help="seconds to wait for the `m6:all-green` console sentinel",
    )
    p.add_argument(
        "--no-wait-allgreen",
        action="store_true",
        help="skip waiting for `m6:all-green`; capture as soon as Page.enable returns",
    )
    return p.parse_args()


def fetch_targets(host: str, port: int, timeout: float = 2.0) -> list[dict]:
    url = f"http://{host}:{port}/json"
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


async def find_page_target(host: str, port: int, connect_timeout: float) -> dict:
    deadline = time.time() + connect_timeout
    last_err: str = ""
    while time.time() < deadline:
        try:
            targets = fetch_targets(host, port)
            for t in targets:
                if t.get("type") == "page" and t.get("webSocketDebuggerUrl"):
                    return t
            last_err = f"no page-type target yet (got {len(targets)} target(s))"
        except (urllib.error.URLError, ConnectionError, OSError) as e:
            last_err = f"{type(e).__name__}: {e}"
        await asyncio.sleep(1.5)
    raise SystemExit(
        f"timed out after {connect_timeout:.0f}s waiting for "
        f"{host}:{port}/json to expose a page target; last: {last_err}"
    )


class CDPSession:
    """Minimal CDP client over an aiowebsocket connection. Demultiplexes
    request responses (matched by `id`) from event notifications (matched
    by `method`). Console messages are surfaced via `console_queue`."""

    def __init__(self, ws):
        self.ws = ws
        self._next_id = 0
        self._pending: dict[int, asyncio.Future] = {}
        self.console_queue: asyncio.Queue = asyncio.Queue()
        self._reader_task = asyncio.create_task(self._reader())

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
                    if msg.get("method") == "Runtime.consoleAPICalled":
                        await self.console_queue.put(msg.get("params", {}))
        except websockets.exceptions.ConnectionClosed:
            pass
        finally:
            # Fail any still-pending requests so callers don't hang.
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

    async def aclose(self) -> None:
        self._reader_task.cancel()
        try:
            await self._reader_task
        except (asyncio.CancelledError, Exception):
            pass


def console_text(params: dict) -> str:
    parts = []
    for a in params.get("args", []):
        if isinstance(a, dict):
            v = a.get("value")
            if v is None:
                v = a.get("description") or a.get("unserializableValue") or ""
            parts.append(str(v))
    return " ".join(parts)


async def wait_for_sentinel(
    session: CDPSession, needle: str, timeout: float
) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        remaining = deadline - time.time()
        try:
            params = await asyncio.wait_for(
                session.console_queue.get(), timeout=min(remaining, 5.0)
            )
        except asyncio.TimeoutError:
            continue
        text = console_text(params)
        if text.startswith("m6:") or "m6:" in text:
            print(f"  console: {text}")
        if needle in text:
            return
    raise SystemExit(f"timed out after {timeout:.0f}s waiting for sentinel {needle!r}")


async def amain() -> int:
    args = parse_args()

    print(f"[{time.strftime('%H:%M:%S')}] finding DevTools page target at "
          f"{args.cdp_host}:{args.cdp_port} (timeout {args.connect_timeout:.0f}s)")
    target = await find_page_target(args.cdp_host, args.cdp_port, args.connect_timeout)
    ws_url = target["webSocketDebuggerUrl"]
    page_url = target.get("url", "(unknown)")
    print(f"[{time.strftime('%H:%M:%S')}] target: {page_url}")
    print(f"[{time.strftime('%H:%M:%S')}] ws:     {ws_url}")

    # The default max_size is 1 MiB which may be too small for a full-page PNG.
    async with websockets.connect(ws_url, max_size=64 * 1024 * 1024) as ws:
        session = CDPSession(ws)
        try:
            await session.send("Runtime.enable")
            await session.send("Page.enable")
            if not args.no_wait_allgreen:
                print(f"[{time.strftime('%H:%M:%S')}] waiting for "
                      f"console.log('m6:all-green') (timeout "
                      f"{args.allgreen_timeout:.0f}s)")
                await wait_for_sentinel(
                    session, "m6:all-green", args.allgreen_timeout
                )
                print(f"[{time.strftime('%H:%M:%S')}] all-green seen; settling...")
                # Allow Svelte's reactive graph + paint to settle.
                await asyncio.sleep(2.0)

            print(f"[{time.strftime('%H:%M:%S')}] calling Page.captureScreenshot")
            result = await session.send(
                "Page.captureScreenshot",
                {
                    "format": "png",
                    "fromSurface": True,
                    "captureBeyondViewport": False,
                },
            )
            data = base64.b64decode(result["data"])
            with open(args.output, "wb") as f:
                f.write(data)
            print(f"[{time.strftime('%H:%M:%S')}] wrote {args.output} "
                  f"({len(data)} bytes)")
        finally:
            await session.aclose()
    return 0


def main() -> int:
    try:
        return asyncio.run(amain())
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
