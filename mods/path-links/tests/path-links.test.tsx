import { describe, expect, test } from 'claude-code/testing'

import { absolute, candidates, linkify, tunnelName, url } from '../hooks/register'
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
