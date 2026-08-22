import { defineConfig } from 'tsdown'

export default defineConfig({
  entry: { main: 'src/main.ts' },
  format: ['esm'],
  platform: 'node',
  target: 'node20',
  outDir: 'dist',
  dts: false,
  sourcemap: false,
  clean: true,
  treeshake: true,
  // platform:'node' defaults fixedExtension to true (always .mjs/.cjs); nvim/lua/chatora/config.lua
  // spawns dist/main.js literally, so force the plain .js extension instead.
  fixedExtension: false,
  // Bundle everything (including vscode-languageserver) so `node dist/main.js --stdio`
  // runs with zero node_modules at runtime — the nvim client spawns it standalone.
  deps: { alwaysBundle: [/.*/] },
})
