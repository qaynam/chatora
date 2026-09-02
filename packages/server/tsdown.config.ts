import { execFileSync } from 'node:child_process'
import { defineConfig } from 'tsdown'

/**
 * What this build calls itself, taken from git rather than from a file somebody has to
 * remember to edit: `v0.1.2` on a release, `v0.1.2-3-gabc1234` three commits past one,
 * `-dirty` with uncommitted changes, a bare sha with no tags at all. The server reports it
 * on initialize, which is how a bug report can name the build it came from.
 *
 * CI must fetch tags (`fetch-tags: true`); a checkout without them describes as a sha.
 */
const version = (() => {
  try {
    return execFileSync('git', ['describe', '--tags', '--always', '--dirty'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim()
  } catch {
    return 'dev'
  }
})()

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
  define: { __CHATORA_VERSION__: JSON.stringify(version) },
  // Nobody reads this file: the client spawns it, and what chatora reports is its own
  // messages rather than stack traces into a bundler's output.
  minify: true,
  // platform:'node' defaults fixedExtension to true (always .mjs/.cjs); nvim/lua/chatora/config.lua
  // spawns dist/main.js literally, so force the plain .js extension instead.
  fixedExtension: false,
  // Bundle everything (including vscode-languageserver) so `node dist/main.js --stdio`
  // runs with zero node_modules at runtime — the nvim client spawns it standalone.
  deps: { alwaysBundle: [/.*/] },
})
