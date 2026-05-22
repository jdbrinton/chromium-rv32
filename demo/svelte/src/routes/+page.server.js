import { serverNonce, serverStartedAt } from '$lib/state.js';

/** @type {import('./$types').PageServerLoad} */
export const load = ({ request, getClientAddress }) => {
	// This data is rendered into the SSR HTML and then re-used by the client
	// after hydration. Seeing identical SSR + hydration output proves the
	// runtime ran Svelte's hydrate() correctly.
	return {
		ssrAt: new Date().toISOString(),
		serverNonce: serverNonce(),
		serverStartedAt: serverStartedAt(),
		userAgent: request.headers.get('user-agent') ?? 'unknown',
		clientAddress: getClientAddress()
	};
};
