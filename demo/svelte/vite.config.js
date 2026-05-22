import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

export default defineConfig({
	plugins: [sveltekit()],
	// Keep the client bundle on a baseline that V8 has supported for years.
	// chromium-rv32's V8 is at the same commit as main, but disabling JIT can
	// expose subtle issues with very new ES syntax; staying on es2020 avoids
	// surprises while still being plenty modern.
	build: {
		target: 'es2020'
	},
	server: {
		port: 4173
	}
});
