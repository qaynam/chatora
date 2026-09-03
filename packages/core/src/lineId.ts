import { randomBytes } from 'node:crypto'

/**
 * New line ids for page-edit-for-ai `_insert` ops. Verified against cosense-cli
 * src/commands/previewEdit.ts:110 — `const newLineId = (): string => randomBytes(12).toString('hex')`,
 * i.e. 24 lowercase hex chars, plain random, with no userId or timestamp embedded.
 */
export const createNewLineId = (): string => randomBytes(12).toString('hex')
