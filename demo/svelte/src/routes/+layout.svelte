<script>
	let { children } = $props();
</script>

<svelte:head>
	<title>chromium-rv32 · Svelte 5 hydration demo</title>
</svelte:head>

{@render children()}

<style>
	:global(:root) {
		color-scheme: dark;
	}
	:global(html, body) {
		margin: 0;
		padding: 0;
	}
	:global(body) {
		background: #0b1020;
		color: #e6e9f2;
		font-family:
			-apple-system,
			BlinkMacSystemFont,
			'Segoe UI',
			sans-serif;
	}
</style>
