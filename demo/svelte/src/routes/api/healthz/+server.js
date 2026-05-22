import { json } from '@sveltejs/kit';

/** @type {import('./$types').RequestHandler} */
export async function GET() {
	return json({
		ok: true,
		service: 'chromium-rv32-demo',
		at: new Date().toISOString(),
		uptime_s: Math.round(process.uptime())
	});
}
