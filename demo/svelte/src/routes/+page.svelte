<script>
	import { onMount } from 'svelte';

	/** @type {{ data: import('./$types').PageData }} */
	let { data } = $props();

	// === Subsystem status ===
	// Each of these flips true the first time the corresponding subsystem
	// produces a successful result in the browser. They light up as the
	// runtime proves each capability.
	let status = $state({
		hydrated: false, // onMount fired → hydration worked
		domUpdate: false, // counter button has been clicked at least once
		fetched: false, // /api/echo returned a 200
		streamed: false // at least one SSE event arrived
	});

	let counter = $state(0);

	let echo = $state(/** @type {null | { ok:boolean, you:any, at:string }} */ (null));
	let echoError = $state(/** @type {null | string} */ (null));
	let echoInFlight = $state(false);

	let stream = $state(
		/** @type {null | { tick:number, at:string, nonce:string }} */ (null)
	);
	let streamError = $state(/** @type {null | string} */ (null));
	let streamEvents = $state(0);

	const allGreen = $derived(
		status.hydrated && status.domUpdate && status.fetched && status.streamed
	);

	function bump() {
		counter += 1;
		if (!status.domUpdate) {
			// chromium-rv32 M6 sentinel: first DOM update after click.
			console.log('m6:dom-update:counter=' + counter);
		}
		status.domUpdate = true;
	}

	async function callEcho() {
		echoInFlight = true;
		echoError = null;
		try {
			const res = await fetch('/api/echo', {
				method: 'POST',
				headers: { 'content-type': 'application/json' },
				body: JSON.stringify({
					hello: 'from chromium-rv32',
					counter,
					sentAt: new Date().toISOString()
				})
			});
			if (!res.ok) throw new Error(`HTTP ${res.status}`);
			echo = await res.json();
			if (!status.fetched) {
				// chromium-rv32 M6 sentinel: first successful fetch round-trip.
				console.log('m6:fetch-ok:at=' + (echo?.at ?? 'n/a'));
			}
			status.fetched = true;
		} catch (/** @type {any} */ e) {
			echoError = e?.message ?? String(e);
			console.log('m6:fetch-error:' + echoError);
		} finally {
			echoInFlight = false;
		}
	}

	onMount(() => {
		status.hydrated = true;
		// chromium-rv32 M6 sentinel: Svelte 5 hydration completed and onMount
		// fired. Parsed out of content_shell stderr by m6-acceptance.sh.
		console.log('m6:hydrated:' + new Date().toISOString());

		// Auto-trigger the fetch and DOM-update probes after a short delay so
		// the M6 boot acceptance can detect all four lights without needing a
		// human to click anything. The delays are tiny but non-zero so each
		// sentinel is printed on its own task tick.
		setTimeout(() => {
			bump();
			callEcho();
		}, 250);

		const es = new EventSource('/sse');
		es.addEventListener('tick', (ev) => {
			try {
				stream = JSON.parse(/** @type {MessageEvent} */ (ev).data);
				streamEvents += 1;
				if (!status.streamed) {
					// chromium-rv32 M6 sentinel: first SSE tick decoded.
					console.log('m6:sse-tick:n=' + stream.tick + ':at=' + stream.at);
				}
				status.streamed = true;
			} catch (/** @type {any} */ e) {
				streamError = e?.message ?? String(e);
				console.log('m6:sse-parse-error:' + streamError);
			}
		});
		es.onerror = () => {
			streamError = 'EventSource error (will auto-reconnect)';
			console.log('m6:sse-error');
		};
		return () => es.close();
	});

	$effect(() => {
		// chromium-rv32 M6 sentinel: all 4 lights green simultaneously. Fires
		// inside a $effect so we only print it once Svelte's reactive graph has
		// converged to the all-green state.
		if (allGreen) {
			console.log('m6:all-green');
		}
	});
</script>

<main>
	<h1>chromium-rv32 · Svelte 5 hydration demo</h1>

	<p class="caption">
		If every dot below is green the chromium-rv32 runtime has successfully
		executed JavaScript, attached the SSR'd DOM via Svelte 5
		<code>hydrate()</code>, handled an event, completed a <code>fetch</code>,
		and consumed a server-streamed
		<code>EventSource</code>.
	</p>

	<section class="board" class:allgreen={allGreen}>
		{@render light('hydration', status.hydrated)}
		{@render light('DOM update', status.domUpdate)}
		{@render light('fetch', status.fetched)}
		{@render light('SSE stream', status.streamed)}
	</section>

	<section class="grid">
		<div class="card">
			<h2>1 · SSR payload</h2>
			<p class="muted">Rendered once on the host server. Verifying it shows up identically
				after hydration is the simplest hydration check.</p>
			<dl>
				<dt>ssrAt</dt><dd><code>{data.ssrAt}</code></dd>
				<dt>serverNonce</dt><dd><code>{data.serverNonce}</code></dd>
				<dt>serverStartedAt</dt><dd><code>{data.serverStartedAt}</code></dd>
				<dt>User-Agent</dt><dd><code class="ua">{data.userAgent}</code></dd>
				<dt>Client address</dt><dd><code>{data.clientAddress}</code></dd>
			</dl>
		</div>

		<div class="card">
			<h2>2 · DOM + events</h2>
			<p class="muted">Click the button. The counter mutates client-side state which
				Svelte 5's runes reactively patch back into the DOM.</p>
			<button onclick={bump}>bump counter</button>
			<p class="counter">counter = <strong>{counter}</strong></p>
		</div>

		<div class="card">
			<h2>3 · fetch</h2>
			<p class="muted">POST a JSON body to <code>/api/echo</code>; the server returns it
				back. Validates <code>fetch</code>, JSON, and round-tripping.</p>
			<button onclick={callEcho} disabled={echoInFlight}>
				{echoInFlight ? 'POSTing…' : 'POST /api/echo'}
			</button>
			{#if echoError}
				<p class="err">error: {echoError}</p>
			{/if}
			{#if echo}
				<pre>{JSON.stringify(echo, null, 2)}</pre>
			{/if}
		</div>

		<div class="card">
			<h2>4 · streamed (SSE)</h2>
			<p class="muted">An <code>EventSource</code> subscribes to <code>/sse</code>.
				The server pushes a <code>tick</code> event once per second. The dot below
				will start blinking as data arrives.</p>
			{#if streamError}
				<p class="warn">{streamError}</p>
			{/if}
			{#if stream}
				<dl>
					<dt>events received</dt><dd><strong>{streamEvents}</strong></dd>
					<dt>last tick</dt><dd><code>{stream.tick}</code></dd>
					<dt>last at</dt><dd><code>{stream.at}</code></dd>
					<dt>server nonce</dt><dd><code>{stream.nonce}</code></dd>
				</dl>
			{:else}
				<p class="muted"><em>(waiting for first event…)</em></p>
			{/if}
		</div>
	</section>

	{#if allGreen}
		<p class="green-banner">
			✓ all four subsystems confirmed working
		</p>
	{/if}

	<footer>
		<p>
			Source: <code>chromium-rv32/server/</code>. Validates the M5 acceptance
			criteria: hydration, DOM update, JS execution, event handling,
			<code>fetch</code>, and streamed server-originated data.
		</p>
	</footer>
</main>

{#snippet light(label, on)}
	<div class="light" class:on>
		<span class="dot"></span>
		<span class="label">{label}</span>
	</div>
{/snippet}

<style>
	main {
		max-width: 940px;
		margin: 1.25rem auto;
		padding: 1rem 1.25rem;
	}
	h1 {
		margin: 0 0 0.25rem;
		color: #93c5fd;
		font-size: 1.55rem;
	}
	h2 {
		margin: 0 0 0.4rem;
		color: #93c5fd;
		font-size: 1rem;
	}
	.caption {
		color: #cbd5f5;
		margin: 0 0 1rem;
		font-size: 0.95rem;
	}
	.board {
		display: grid;
		grid-template-columns: repeat(4, 1fr);
		gap: 0.5rem;
		padding: 0.75rem;
		border-radius: 8px;
		background: #11173a;
		border: 1px solid #1e2a4d;
		margin-bottom: 1rem;
	}
	.board.allgreen {
		border-color: #34d399;
		box-shadow: 0 0 0 1px rgba(52, 211, 153, 0.4) inset;
	}
	.light {
		display: flex;
		align-items: center;
		gap: 0.45rem;
		font-size: 0.9rem;
		color: #cbd5f5;
	}
	.dot {
		display: inline-block;
		width: 0.8rem;
		height: 0.8rem;
		background: #475569;
		border-radius: 50%;
		transition: background 120ms ease;
	}
	.light.on .dot {
		background: #34d399;
		box-shadow: 0 0 6px #34d399;
	}
	.grid {
		display: grid;
		grid-template-columns: 1fr 1fr;
		gap: 0.75rem;
	}
	.card {
		background: #11173a;
		padding: 0.75rem 1rem;
		border-radius: 8px;
		border: 1px solid #1e2a4d;
	}
	.muted {
		color: #94a3b8;
		font-size: 0.85rem;
		margin: 0 0 0.5rem;
	}
	.err {
		color: #f87171;
		font-size: 0.9rem;
	}
	.warn {
		color: #fbbf24;
		font-size: 0.85rem;
	}
	dl {
		margin: 0;
	}
	dt {
		color: #94a3b8;
		font-size: 0.78rem;
		margin-top: 0.35rem;
	}
	dd {
		margin: 0;
	}
	code {
		background: #1e2a4d;
		padding: 0.05rem 0.35rem;
		border-radius: 3px;
		font-size: 0.85rem;
	}
	code.ua {
		font-size: 0.7rem;
		word-break: break-all;
	}
	pre {
		background: #0b1020;
		padding: 0.5rem;
		border-radius: 4px;
		border: 1px solid #1e2a4d;
		font-size: 0.8rem;
		overflow-x: auto;
	}
	button {
		background: #3b82f6;
		color: #e6e9f2;
		border: 0;
		padding: 0.45rem 0.9rem;
		border-radius: 4px;
		font-weight: bold;
		cursor: pointer;
	}
	button:disabled {
		opacity: 0.6;
		cursor: not-allowed;
	}
	.counter {
		margin-top: 0.4rem;
	}
	.counter strong {
		color: #fbbf24;
	}
	.green-banner {
		margin-top: 1rem;
		padding: 0.5rem 0.8rem;
		background: rgba(52, 211, 153, 0.12);
		color: #34d399;
		border: 1px solid rgba(52, 211, 153, 0.5);
		border-radius: 6px;
		font-weight: bold;
	}
	footer {
		margin-top: 1.5rem;
		color: #94a3b8;
		font-size: 0.8rem;
	}
</style>
