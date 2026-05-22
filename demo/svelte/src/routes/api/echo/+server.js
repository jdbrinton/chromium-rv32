import { json, error } from '@sveltejs/kit';

/** @type {import('./$types').RequestHandler} */
export async function POST({ request }) {
	let body;
	try {
		body = await request.json();
	} catch {
		throw error(400, 'expected a JSON body');
	}
	return json({
		ok: true,
		you: body,
		at: new Date().toISOString()
	});
}
