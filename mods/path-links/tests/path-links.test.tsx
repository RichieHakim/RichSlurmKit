import { describe, expect, test } from 'claude-code/testing'

import { absolute, candidates, linkify, shown, size, tunnelName, url } from '../hooks/register'
import type { Env } from '../hooks/register'

const ENV: Env = { base: 'vscode://vscode-remote/tunnel+tunnel-9', home: '/home/u' }
const CWD = '/home/u/repo'
const KINDS: Record<string, 'file' | 'dir'> = {
  '/home/u/repo/bin/m': 'file',
  '/home/u/repo/lib': 'dir',
  '/home/u/fig.png': 'file',
  '/dev': 'dir',
}
const F = 'vscode://vscode-remote/tunnel+tunnel-9/home/u/repo/bin/m'

const run = (markdown: string) =>
  linkify(markdown, c => {
    const abs = absolute(c.path, CWD, ENV.home)
    const kind = KINDS[abs]
    return kind ? url(ENV, abs, kind, c) : null
  })

describe('linkify', () => {
  test('an absolute path, without the full stop that ends the sentence', () => {
    expect(run('See /home/u/repo/bin/m.')).toBe(`See [/home/u/repo/bin/m](${F}:1).`)
  })

  test('a line and column carry into the link', () => {
    expect(run('at /home/u/repo/bin/m:12:3, then')).toBe(`at [/home/u/repo/bin/m:12:3](${F}:12:3), then`)
  })

  test('home and relative paths resolve; a directory opens in a new window', () => {
    expect(run('~/fig.png and lib/')).toBe(
      '[~/fig.png](vscode://vscode-remote/tunnel+tunnel-9/home/u/fig.png:1) and ' +
        '[lib/](vscode://vscode-remote/tunnel+tunnel-9/home/u/repo/lib?windowId=_blank)',
    )
    expect(run('(./bin/../bin/m)')).toBe(`([./bin/../bin/m](${F}:1))`)
  })

  test('a bare file name links when it exists in the working directory', () => {
    const kinds: Record<string, 'file'> = { '/home/u/repo/fig.png': 'file' }
    const md = 'Saved fig.png, not e.g. v2.1.309 or claude.ai.'
    const out = linkify(md, c => {
      const abs = absolute(c.path, CWD, ENV.home)
      return kinds[abs] ? url(ENV, abs, kinds[abs]!, c) : null
    })
    expect(out).toBe('Saved [fig.png](vscode://vscode-remote/tunnel+tunnel-9/home/u/repo/fig.png:1), not e.g. v2.1.309 or claude.ai.')
  })

  test('inline code holding just a path becomes a link; a command stays code', () => {
    expect(run('Run `bin/m` now')).toBe(`Run [\`bin/m\`](${F}:1) now`)
    expect(run('Run `bin/m --help` now')).toBe('Run `bin/m --help` now')
  })

  test('fenced code, links and URLs are left alone', () => {
    const fenced = '```\n/home/u/repo/bin/m\n```\n~~~bash\nls lib/\n~~~'
    expect(run(fenced)).toBe(fenced)
    expect(run('[m](/home/u/repo/bin/m) and https://x.org/home/u/repo/bin/m')).toBe(
      '[m](/home/u/repo/bin/m) and https://x.org/home/u/repo/bin/m',
    )
    expect(run('after a fence\n```\nx\n```\nbin/m')).toBe(`after a fence\n\`\`\`\nx\n\`\`\`\n[bin/m](${F}:1)`)
  })

  test('a fence in a nested list holds until a bare closing fence', () => {
    const nested = '- a\n  - b\n\n    ```bash\n    ls lib/\n    ```python\n    cat bin/m\n    ```\n  - lib/'
    expect(run(nested)).toBe(nested.replace(/lib\/$/, '[lib/](vscode://vscode-remote/tunnel+tunnel-9/home/u/repo/lib?windowId=_blank)'))
    expect(run('```bin/m```\nlib/')).toBe(
      `[\`\`\`bin/m\`\`\`](${F}:1)\n[lib/](vscode://vscode-remote/tunnel+tunnel-9/home/u/repo/lib?windowId=_blank)`,
    )
  })

  test('missing paths, slash commands and words with a slash stay text', () => {
    expect(run('/nope/here and /dev and and/or')).toBe('/nope/here and /dev and and/or')
  })

  test('candidates lists what would be checked', () => {
    expect(candidates('bin/m:4 and `~/fig.png`').map(c => [c.path, c.line])).toEqual([
      ['bin/m', '4'],
      ['~/fig.png', undefined],
    ])
  })
})

describe('helpers', () => {
  test('url percent-encodes the path', () => {
    expect(url(ENV, '/a/b+c (1)', 'file', { path: '' })).toBe('vscode://vscode-remote/tunnel+tunnel-9/a/b%2Bc%20%281%29:1')
  })

  test("tunnelName prefers Claude's own job's tunnel, else the last listed", () => {
    const lines = [
      '11 /scratch/code --cli-data-dir /x tunnel --accept-server-license-terms --name tunnel-1',
      '12 /scratch/code --cli-data-dir /x agent host',
      '13 code --wait notes.txt',
      '14 /scratch/code tunnel --name=tunnel-2',
    ]
    expect(tunnelName(lines, '1')).toBe('tunnel-1')
    expect(tunnelName(lines, '7')).toBe('tunnel-2')
    expect(tunnelName(lines, '')).toBe('tunnel-2')
    expect(tunnelName(['12 /scratch/code agent host'], '1')).toBe(null)
  })

  test('shown and size match how Claude lists a sent file', () => {
    expect(shown('/home/u/repo/fig.png', CWD, ENV.home)).toBe('fig.png')
    expect(shown('/home/u/fig.png', CWD, ENV.home)).toBe('~/fig.png')
    expect(shown('/lab/fig.png', CWD, ENV.home)).toBe('/lab/fig.png')
    expect([97, 1024, 214937, 3 * 1024 ** 2, 1.5 * 1024 ** 3].map(size)).toEqual(['97 bytes', '1KB', '209.9KB', '3MB', '1.5GB'])
  })
})

const REPLY = {
  plugin: 'path-links',
  component: 'AssistantMessage',
  requestId: 'msg-1',
  props: { text: 'Wrote /home/u/repo/bin/m', isFirstOfReply: true },
} as const

const PGREP = '/home/u\n9\n11 /scratch/code --cli-data-dir /x tunnel --accept-server-license-terms --name tunnel-9\n'

test('the hook draws tunnel links on the terminal only', async ($, on) => {
  on('clock.now', () => ({ value: 0 }))
  on('process.run', () => ({ value: { exitCode: 0, stdout: PGREP, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  on('session.cwd', () => ({ value: CWD }))
  on('fs.stat', (_, e) => {
    const kind = KINDS[e.path]
    return kind ? { value: { kind, size: 0, mtimeMs: 0, isLink: false } } : { deny: 'ENOENT' }
  })
  // Stands for the engine: records the text it was asked to draw.
  const drawn: string[] = []
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => {
    drawn.push(e.props.text)
    const { Text } = $.ui.resolve(e)
    return <Text>{e.props.text}</Text>
  })

  const ui = await $.ui.mount({ ...REPLY, surface: 'terminal' })
  await ui.unmount()
  const other = await $.ui.mount({ ...REPLY, surface: 'desktop' })
  await other.unmount()

  expect(drawn).toEqual([`Wrote [/home/u/repo/bin/m](${F}:1)`, 'Wrote /home/u/repo/bin/m'])
})

test('without a tunnel the reply is drawn as written', async ($, on) => {
  on('clock.now', () => ({ value: 0 }))
  on('process.run', () => ({ value: { exitCode: 1, stdout: '/home/u\n9\n', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  const drawn: string[] = []
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => {
    drawn.push(e.props.text)
    const { Text } = $.ui.resolve(e)
    return <Text>{e.props.text}</Text>
  })

  const ui = await $.ui.mount({ ...REPLY, surface: 'terminal' })
  await ui.unmount()

  expect(drawn).toEqual(['Wrote /home/u/repo/bin/m'])
})

test('files Claude sends are listed again with tunnel links', async ($, on) => {
  on('clock.now', () => ({ value: 0 }))
  on('process.run', () => ({ value: { exitCode: 0, stdout: PGREP, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  on('session.cwd', () => ({ value: CWD }))
  on('fs.stat', (_, e) => {
    const kind = KINDS[e.path]
    return kind ? { value: { kind, size: 0, mtimeMs: 0, isLink: false } } : { deny: 'ENOENT' }
  })
  // Stands for the engine: records the files it was asked to list.
  const listed: unknown[] = []
  on('ui.render', { component: 'ToolResult' }, ($, e) => {
    listed.push((e.props.output as { attachments: unknown[] }).attachments.length)
    const { Text } = $.ui.resolve(e)
    return <Text>caption</Text>
  })

  const output = {
    caption: 'caption',
    attachments: [
      { path: '/home/u/fig.png', size: 214937, isImage: true, pathValidated: true },
      { path: '/gone/report.pdf', size: 97, isImage: false, pathValidated: true },
    ],
  }
  const ui = await $.ui.mount({
    plugin: 'path-links',
    component: 'ToolResult',
    requestId: 'toolu-1',
    surface: 'terminal',
    props: { tool_use_id: 'toolu-1', tool: 'SendUserFile', output, isErrored: false },
  })
  const links = await ui.findAll({ type: 'Link' })
  const text = (await ui.findAll({ type: 'Text' })).map(t => t.text)
  await ui.unmount()

  const fig = 'vscode://vscode-remote/tunnel+tunnel-9/home/u/fig.png:1'
  expect(listed).toEqual([0])
  expect(links.map(l => [l.props.href, ...l.children])).toEqual([[fig, '~/fig.png']])
  // A Link's text here is its address, then what it shows.
  expect(text).toContain(`› [image] ${fig}~/fig.png (209.9KB)`)
  expect(text).toContain('› [file] /gone/report.pdf (97 bytes)')
})

test('rows drawn while the tunnel lookup runs wait for it', async ($, on) => {
  on('clock.now', () => ({ value: 0 }))
  let lookups = 0
  on('process.run', async () => {
    lookups += 1
    await Promise.resolve()
    return { value: { exitCode: 0, stdout: PGREP, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('session.cwd', () => ({ value: CWD }))
  on('fs.stat', (_, e) => {
    const kind = KINDS[e.path]
    return kind ? { value: { kind, size: 0, mtimeMs: 0, isLink: false } } : { deny: 'ENOENT' }
  })
  const drawn: string[] = []
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => {
    drawn.push(e.props.text)
    const { Text } = $.ui.resolve(e)
    return <Text>{e.props.text}</Text>
  })

  const uis = await Promise.all([
    $.ui.mount({ ...REPLY, surface: 'terminal' }),
    $.ui.mount({ ...REPLY, requestId: 'msg-2', surface: 'terminal' }),
  ])
  await Promise.all(uis.map(ui => ui.unmount()))

  expect(lookups).toBe(1)
  expect(drawn).toEqual([`Wrote [/home/u/repo/bin/m](${F}:1)`, `Wrote [/home/u/repo/bin/m](${F}:1)`])
})
