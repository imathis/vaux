// Bundles the plugin into one file Stream Deck runs with its own Node.
import { build } from "esbuild";

await build({
	entryPoints: ["src/plugin.ts"],
	bundle: true,
	platform: "node",
	format: "esm",
	target: "node24",
	outfile: "dev.imathis.vaux.sdPlugin/bin/plugin.mjs",
	// CommonJS packages bundled in (ws) still require Node's own modules.
	banner: { js: 'import { createRequire } from "node:module"; const require = createRequire(import.meta.url);' },
	logLevel: "info",
});
