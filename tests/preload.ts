import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

// Anything reached through `stateFilePath` — the read marks, the cached title index —
// writes to a real directory under the user's home unless told otherwise. A test run must
// not read what a previous session left there, nor leave anything behind for the next one.
process.env.CHATORA_STATE_DIR = mkdtempSync(join(tmpdir(), 'chatora-test-'))
