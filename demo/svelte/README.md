# `demo/svelte/` — Svelte 5 demo + Node server

A single SvelteKit app that exercises every runtime feature our minimal
RV32 browser must support: SSR + hydration, reactive DOM updates,
`fetch` POST round-trips, and an SSE stream.

The host runs the Node server. The browser (real browser, or the
chromium-rv32 build of `content_shell` inside the QEMU RV32 guest) loads
the page over HTTP. The `m6:*` console sentinels emitted by the
dashboard are how `tools/capture-screenshot.py` and the in-guest
acceptance script know the demo has converged.

## What it validates

When the page is loaded, four "lights" on the dashboard flip green as each
subsystem proves itself in sequence:

| Light | What proves it |
|---|---|
| `hydration` | `onMount()` fires after the client takes over the SSR DOM. |
| `DOM update` | Clicking the **bump counter** button reactively updates the DOM. |
| `fetch` | The **POST /api/echo** button completes a JSON round-trip. |
| `SSE stream` | The `/sse` endpoint pushes a `tick` event the client decodes. |

When all four are green the dashboard shows a banner: this is the M5
acceptance signal.

## Server endpoints

| Path | Verb | What |
|---|---|---|
| `/` | GET | Server-side renders the page. `+page.server.js` returns the SSR payload (timestamps, nonce, UA, client IP). |
| `/api/echo` | POST | Reads the JSON body, returns `{ ok: true, you: <body>, at: <iso> }`. |
| `/sse` | GET | `text/event-stream`. Emits a synthetic comment to flush headers, then one named `tick` event per second carrying `{ tick, at, nonce }`. Cleans up when the client closes the connection. |

The SSE stream is built on a plain `ReadableStream`. SvelteKit's
`adapter-node` hands it to the underlying Node response unmodified, so it
flushes incrementally and keeps the connection alive.

## Commands

From this directory:

```bash
# Install dependencies (one-off; the npm registry is on the host).
npm install

# Dev mode — fast feedback while iterating on the demo itself.
npm run dev          # serves http://localhost:4173

# Production build — what we actually point the RV32 browser at.
npm run build
npm run start        # serves http://localhost:3000 (adapter-node default)
```

The dev server binds to `0.0.0.0`, so the QEMU guest can reach it over the
host network with the host's IP (find with `ip route get 1`).

## Network plumbing for the QEMU guest

When the chromium-rv32 browser runs inside `qemu-system-riscv32` with the
default user-mode network, the host is reachable at `10.0.2.2`. Point the
browser at:

```
http://10.0.2.2:3000/
```

If running with bridged networking (e.g. virt-bridge on the FPGA target),
use the host's LAN address instead.

## Why SvelteKit, not raw Vite + manual SSR?

The user requirement was a "modern Svelte 5 demo, fully hydrated". SvelteKit
gives us SSR + hydration + routing + endpoints + an adapter-node build that
emits a small standalone Node server. That keeps the demo small while still
being a realistic stand-in for a "real" Svelte 5 app the user might want to
run on a kiosk-style RV32 device.

The build target is `es2020` to stay on a JS feature baseline V8 has had
solidly for years; we don't need ES2022 features for this app.

## Why SSE, not WebSocket?

* Acceptance bar called out "SSE, WebSocket, or fetch/ReadableStream"; SSE
  is the simplest of the three.
* SSE only requires HTTP/1.1 keepalive — no protocol upgrade — so it is
  more likely to work on an in-progress minimal Chromium without proxy
  shenanigans.
* The endpoint is implemented as a `Response(ReadableStream, …)`, which
  doubles as an exercise of the `ReadableStream` + `Response` web APIs on
  the server side too.

Should the chromium-rv32 build turn out to support WebSocket but not SSE
(or vice versa), the failure mode is obvious from which light fails to go
green, and switching is a 30-line change in `+page.svelte` and the
endpoint.

## File map

```
demo/svelte/
├── README.md               (this file)
├── package.json            (sveltekit + adapter-node, runes-mode svelte 5)
├── svelte.config.js
├── vite.config.js
├── jsconfig.json
└── src/
    ├── app.html            (HTML shell + sveltekit head/body placeholders)
    ├── lib/
    │   └── state.js        (in-memory tick + subscriber set; SSE source)
    └── routes/
        ├── +layout.svelte  (global page chrome + dark theme)
        ├── +page.svelte    (the dashboard; runes; the 4 lights)
        ├── +page.server.js (SSR data: timestamps, nonce, UA, client IP)
        ├── api/echo/+server.js     (POST → JSON echo)
        ├── api/healthz/+server.js  (GET → liveness sentinel)
        └── sse/+server.js          (GET → text/event-stream)
```
