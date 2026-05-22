/**
 * Tiny in-memory server state shared across requests / SSE connections.
 * Pure JS, no external deps. Process-local.
 *
 * Purpose: give the demo something genuinely server-originated to push to
 * the client so we can see streamed data actually arriving in the
 * chromium-rv32 runtime.
 */

const startedAt = new Date().toISOString();
const nonce = Math.random().toString(36).slice(2, 10);

let tick = 0;
const subscribers = new Set();

/** @returns {{ tick:number, at:string, nonce:string }} */
export function snapshot() {
	return { tick, at: new Date().toISOString(), nonce };
}

export function serverStartedAt() {
	return startedAt;
}

export function serverNonce() {
	return nonce;
}

/**
 * @param {(event: { tick:number, at:string, nonce:string }) => void} fn
 * @returns {() => void}
 */
export function subscribe(fn) {
	subscribers.add(fn);
	return () => subscribers.delete(fn);
}

setInterval(() => {
	tick += 1;
	const ev = snapshot();
	for (const fn of subscribers) {
		try {
			fn(ev);
		} catch {
			// drop dead subscribers; their close handler will clean up
		}
	}
}, 1000);
