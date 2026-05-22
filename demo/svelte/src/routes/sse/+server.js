import { subscribe } from '$lib/state.js';

/**
 * Server-Sent Events endpoint. Streams a `tick` event once per second.
 * The body is a never-ending ReadableStream; SvelteKit (adapter-node) hands
 * it directly to the underlying Node response, so the connection stays open
 * as long as the client keeps reading.
 *
 * The EventSource API on the browser side parses these `event:` / `data:`
 * blocks and re-fires them as named DOM events.
 *
 * @type {import('./$types').RequestHandler}
 */
export const GET = ({ request }) => {
	const stream = new ReadableStream({
		start(controller) {
			const encoder = new TextEncoder();
			const send = (/** @type {{tick:number,at:string,nonce:string}} */ ev) => {
				const body =
					`event: tick\n` +
					`data: ${JSON.stringify(ev)}\n\n`;
				try {
					controller.enqueue(encoder.encode(body));
				} catch {
					// stream was closed
				}
			};
			// Send a synthetic comment to flush response headers immediately.
			controller.enqueue(encoder.encode(`: hello\n\n`));

			const unsub = subscribe(send);
			request.signal.addEventListener('abort', () => {
				unsub();
				try {
					controller.close();
				} catch {
					// already closed
				}
			});
		}
	});

	return new Response(stream, {
		headers: {
			'content-type': 'text/event-stream; charset=utf-8',
			'cache-control': 'no-cache, no-transform',
			connection: 'keep-alive',
			'x-accel-buffering': 'no'
		}
	});
};
