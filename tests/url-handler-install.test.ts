// What `chatora-url-handler install` builds has to satisfy macOS, and macOS is particular:
// claiming http and https registers the app and makes `open -a` reach it, but it is only
// offered as a browser once it also says it opens HTML documents. That is invisible until
// someone looks at System Settings, so it is asserted here.
import { describe, expect, test } from 'bun:test'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const INSTALLER = join(import.meta.dir, '..', 'bin', 'chatora-url-handler')
const darwin = process.platform === 'darwin'

const install = (...args: string[]) => {
  const root = mkdtempSync(join(tmpdir(), 'chatora-install-'))
  const run = Bun.spawnSync([INSTALLER, 'install', ...args], {
    env: {
      ...process.env,
      CHATORA_URL_HANDLER_DIR: join(root, 'data'),
      CHATORA_URL_HANDLER_APPS: join(root, 'apps'),
      // Registering from a test would put the app in the developer's own database.
      CHATORA_URL_HANDLER_SKIP_REGISTER: '1',
    },
  })
  const app = join(root, 'apps', 'Chatora Open.app')
  const plist = Bun.spawnSync([
    'plutil',
    '-convert',
    'json',
    '-o',
    '-',
    join(app, 'Contents', 'Info.plist'),
  ])
  return {
    root,
    status: run.exitCode,
    stdout: run.stdout.toString(),
    info: JSON.parse(plist.stdout.toString() || '{}'),
    dataFile: (name: string) => readFileSync(join(root, 'data', name), 'utf8').trim(),
    cleanup: () => rmSync(root, { recursive: true, force: true }),
  }
}

describe.skipIf(!darwin)('chatora-url-handler install', () => {
  test('builds an app macOS will offer as a browser', () => {
    const installed = install()
    try {
      expect(installed.status).toBe(0)

      const schemes = installed.info.CFBundleURLTypes?.[0]?.CFBundleURLSchemes
      expect(schemes).toEqual(['http', 'https'])

      // The part that is easy to leave out and impossible to notice.
      const types = installed.info.CFBundleDocumentTypes?.[0]?.LSItemContentTypes
      expect(types).toContain('public.html')

      expect(installed.info.CFBundleIdentifier).toBe('dev.qaynam.chatora.open')
      expect(installed.info.LSUIElement).toBe(true)
    } finally {
      installed.cleanup()
    }
  })

  test('records a browser to fall back to, and the handler to run', () => {
    const installed = install()
    try {
      // Whatever it read, it must never be empty: the handler would then open the URL with
      // the system default, which by then is the handler.
      expect(installed.dataFile('fallback')).not.toBe('')
      expect(installed.dataFile('origins')).toBe('scrapbox.io')
      expect(installed.dataFile('env')).toContain('NVIM=')
      expect(installed.dataFile('chatora-open')).toContain('chatora')
    } finally {
      installed.cleanup()
    }
  })

  test('--browser names the fallback, by name or by bundle id', () => {
    const installed = install('--browser', 'Safari')
    try {
      expect(installed.status).toBe(0)
      expect(installed.dataFile('fallback')).toBe('com.apple.Safari')
    } finally {
      installed.cleanup()
    }
  })

  test('an argument install does not know is refused', () => {
    const installed = install('--browsr', 'Safari')
    try {
      expect(installed.status).toBe(2)
    } finally {
      installed.cleanup()
    }
  })
})

/** An application bundle that claims https and HTML, which is what makes a browser. */
const fakeBrowser = (dir: string, name: string, id: string) => {
  const contents = join(dir, `${name}.app`, 'Contents')
  mkdirSync(contents, { recursive: true })
  writeFileSync(
    join(contents, 'Info.plist'),
    `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>${id}</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
  </dict></array>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>LSItemContentTypes</key><array><string>public.html</string></array>
  </dict></array>
</dict></plist>
`,
  )
}

const handler = (args: string[], opts: { stdin?: string; fallback?: string } = {}) => {
  const root = mkdtempSync(join(tmpdir(), 'chatora-handler-'))
  fakeBrowser(join(root, 'browsers'), 'Fake Browser', 'com.example.fakebrowser')
  if (opts.fallback !== undefined) {
    mkdirSync(join(root, 'data'), { recursive: true })
    writeFileSync(join(root, 'data', 'fallback'), `${opts.fallback}\n`)
  }
  const run = Bun.spawnSync([INSTALLER, ...args], {
    stdin: Buffer.from(opts.stdin ?? ''),
    env: {
      ...process.env,
      CHATORA_URL_HANDLER_DIR: join(root, 'data'),
      CHATORA_URL_HANDLER_APPS: join(root, 'apps'),
      CHATORA_URL_HANDLER_APP_DIRS: join(root, 'browsers'),
    },
  })
  const fallback = (() => {
    try {
      return readFileSync(join(root, 'data', 'fallback'), 'utf8').trim()
    } catch {
      return null
    }
  })()
  rmSync(root, { recursive: true, force: true })
  return {
    status: run.exitCode,
    stdout: run.stdout.toString(),
    stderr: run.stderr.toString(),
    fallback,
  }
}

describe.skipIf(!darwin)('chatora-url-handler browser', () => {
  test('lists the installed browsers, Safari first, and records the number picked', () => {
    const run = handler(['browser'], { stdin: '2\n' })
    expect(run.status).toBe(0)
    expect(run.stderr).toContain('1) Safari')
    expect(run.stderr).toContain('2) Fake Browser  (com.example.fakebrowser)')
    expect(run.fallback).toBe('com.example.fakebrowser')
  })

  test('a bare Enter keeps the browser recorded before, which the list marks', () => {
    const run = handler(['browser'], { stdin: '\n', fallback: 'com.example.fakebrowser' })
    expect(run.status).toBe(0)
    expect(run.stderr).toContain('*  2) Fake Browser')
    expect(run.fallback).toBe('com.example.fakebrowser')
  })

  test('an answer that is not a number on the list changes nothing', () => {
    for (const stdin of ['x\n', '9\n']) {
      const run = handler(['browser'], { stdin, fallback: 'com.apple.Safari' })
      expect(run.status).toBe(1)
      expect(run.fallback).toBe('com.apple.Safari')
    }
    // Nothing recorded and nothing chosen is a usage error, not a guess.
    const run = handler(['browser'], { stdin: '' })
    expect(run.status).toBe(2)
    expect(run.fallback).toBeNull()
  })

  test('records the browser the reader names, as a bundle id', () => {
    expect(handler(['browser', 'Safari']).fallback).toBe('com.apple.Safari')
    expect(handler(['browser', 'com.apple.Safari']).fallback).toBe('com.apple.Safari')
  })

  test('an application that is not there is refused, and nothing is recorded', () => {
    const run = handler(['browser', 'No Such Browser'])
    expect(run.status).toBe(1)
    expect(run.stderr).toContain('No Such Browser')
    expect(run.fallback).toBeNull()
  })

  test('the handler itself cannot be the fallback', () => {
    expect(handler(['browser', 'dev.qaynam.chatora.open']).status).toBe(1)
  })
})

describe.skipIf(!darwin)('chatora-url-handler arguments', () => {
  test.each([[[]], [['bogus']], [['status', 'extra']], [['browser', 'a', 'b']]])(
    '%j is a usage error',
    (args) => {
      const run = handler(args)
      expect(run.status).toBe(2)
      expect(run.stderr).toContain('使い方')
    },
  )

  test('--help prints the usage', () => {
    const run = handler(['--help'])
    expect(run.status).toBe(0)
    expect(run.stdout).toContain('browser [<app>]')
  })
})
