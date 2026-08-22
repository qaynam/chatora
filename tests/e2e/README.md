# chatora e2e harness

Run from the repo root: `bun tests/e2e/run.ts`
Validates Neovim plugin -> `@chatora/server` (LSP/node) -> HTTP against a fake, in-process Cosense server — no real credentials, no network.
See `run.ts`, `fake-cosense.ts`, `init.lua`, `scenario.lua` in this directory for details.
