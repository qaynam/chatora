// bin/chatora is the shell entry point users alias to `chatora`. It is a handful of lines,
// but they are the ones that decide what Neovim is told to do, so they are tested against a
// stub `nvim` that prints its argv instead of starting an editor.
import { describe, expect, test } from 'bun:test'
import { chmodSync, mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const LAUNCHER = join(import.meta.dir, '..', 'bin', 'chatora')

const stubDir = mkdtempSync(join(tmpdir(), 'chatora-launcher-'))
writeFileSync(join(stubDir, 'nvim'), '#!/bin/sh\nfor a in "$@"; do printf "%s\\n" "$a"; done\n')
chmodSync(join(stubDir, 'nvim'), 0o755)

const launch = (...args: string[]): { argv: string[]; status: number; stderr: string } => {
  const run = Bun.spawnSync([LAUNCHER, ...args], {
    env: { ...process.env, PATH: `${stubDir}:${process.env.PATH ?? ''}` },
  })
  return {
    argv: run.stdout.toString().split('\n').filter(Boolean),
    status: run.exitCode,
    stderr: run.stderr.toString(),
  }
}

describe('bin/chatora', () => {
  test('bare launch opens the sidebar on the configured project', () => {
    expect(launch().argv).toEqual(['+Chatora'])
  })

  test.each([
    ['-p', 'proj'],
    ['--project', 'proj'],
  ])('%s %s names the project to open', (flag, name) => {
    expect(launch(flag, name).argv).toEqual([`+Chatora project ${name}`])
  })

  test.each(['-pproj', '--project=proj'])('%s is the same flag, written joined', (arg) => {
    expect(launch(arg).argv).toEqual(['+Chatora project proj'])
  })

  test('a page URL opens that page, and needs no project of its own', () => {
    const url = 'https://scrapbox.io/proj/Page'
    expect(launch('-p', 'other', url).argv).toEqual([`+Chatora open ${url}`]) // URL wins
    expect(launch(url).argv).toEqual([`+Chatora open ${url}`])
  })

  test('anything left over is Neovim’s to interpret', () => {
    expect(launch('-p', 'proj', 'notes.md').argv).toEqual(['+Chatora project proj', 'notes.md'])
  })

  test('a project flag with nothing after it fails instead of opening a nameless project', () => {
    const run = launch('-p')
    expect(run.status).toBe(2)
    expect(run.stderr).toContain('needs a project name')
    expect(run.argv).toEqual([])
  })
})
