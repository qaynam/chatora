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

  test('`open <url>` is the URL form spelled like :Chatora open', () => {
    const url = 'https://scrapbox.io/proj/Page'
    expect(launch('open', url).argv).toEqual([`+Chatora open ${url}`])
    expect(launch('-p', 'other', 'open', url).argv).toEqual([`+Chatora open ${url}`])
  })

  test('`open` with no URL after it is refused', () => {
    for (const args of [['open'], ['open', 'notes.md']]) {
      const run = launch(...args)
      expect(run.status).toBe(2)
      expect(run.stderr).toContain('URL')
      expect(run.argv).toEqual([])
    }
  })

  test('a word that is neither a URL nor a file is refused, not handed to nvim as a file', () => {
    for (const word of ['toggle', 'search', 'project']) {
      const run = launch(word)
      expect(run.status).toBe(2)
      expect(run.stderr).toContain(word)
      expect(run.argv).toEqual([])
    }
    // A path is nvim's, whether or not it exists yet.
    expect(launch('notes.md').argv).toEqual(['+Chatora', 'notes.md'])
    expect(launch('./notes').argv).toEqual(['+Chatora', './notes'])
    expect(launch('+10', 'notes.md').argv).toEqual(['+Chatora', '+10', 'notes.md'])
  })

  test('a URL anywhere but first is refused, since nvim would open it as a file', () => {
    const url = 'https://scrapbox.io/proj/Page'
    for (const args of [
      ['-o', url],
      ['notes.md', url],
    ]) {
      const run = launch(...args)
      expect(run.status).toBe(2)
      expect(run.stderr).toContain(url)
      expect(run.argv).toEqual([])
    }
  })

  test('--help prints the usage and starts nothing', () => {
    const run = Bun.spawnSync([LAUNCHER, '--help'], {
      env: { ...process.env, PATH: `${stubDir}:${process.env.PATH ?? ''}` },
    })
    expect(run.exitCode).toBe(0)
    expect(run.stdout.toString()).toContain('使い方')
  })
})
