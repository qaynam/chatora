import { randomBytes } from 'node:crypto'

/** Generate a new 24-character lowercase hexadecimal id for an inserted line. */
export const createNewLineId = (): string => randomBytes(12).toString('hex')
