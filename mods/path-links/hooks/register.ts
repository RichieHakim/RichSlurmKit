import type { EngineInterface, Register } from 'claude-code'

// Draws the file and directory paths in Claude's replies as links to this
// node's VS Code tunnel. Only the drawing changes: the model is told nothing
// and the saved conversation keeps the plain paths.
//
// Why links: Claude's fullscreen renderer breaks a long path across rows, and
// VS Code only makes a plain path clickable when it sits on one row. A
// markdown link is drawn as a hyperlink on every row it spans. file:// links
// don't work (VS Code looks for the file on the laptop), while
// vscode://vscode-remote/tunnel+NAME/<path> opens it on the cluster. A file
// opens at its line in the current window. A directory gets ?windowId=_blank,
// since a folder link otherwise replaces the current window's folder.
//
// Files Claude sends with SendUserFile or SendUserMessage (on while Remote
// Control is) are listed under the caption as `› [image] path (size)`, each
// path a file:// link Claude builds itself. Those lines are drawn again here
// with tunnel links.

export type Kind = 'file' | 'dir'
export type Env = { base: string; home: string }
export type Candidate = { path: string; line?: string; col?: string }
type Link = (c: Candidate) => string | null
export type Attachment = { path: string; size: number; isImage: boolean }
const SENDS = new Set(['SendUserFile', 'SendUserMessage'])

// Characters a path may hold here. No spaces, quotes or brackets, so prose
// around a path never joins it. A path is absolute, ~/ or ./, relative with a
// slash (`lib/`, `bin/m`), or a bare file name with an extension (`fig.png`);
// only one that exists gets a link.
const C = '[A-Za-z0-9._~+@%=,\\-]'
const PATH =
  `(?<![A-Za-z0-9._~+@%=,\\-/:\\\\])` +
  `((?:~|\\.{1,2})?(?:/${C}+)+/?|${C}+(?:(?:/${C}+)+/?|/)|[A-Za-z0-9_][A-Za-z0-9._+@=\\-]*\\.[A-Za-z][A-Za-z0-9]{0,9})` +
  `(?::(\\d+)(?::(\\d+))?)?`
const IN_TEXT = new RegExp(PATH, 'g')
const WHOLE = new RegExp(`^${PATH}$`)

// Spans left as written: inline code (checked whole, below), markdown links
// and images, autolinks, and bare URLs.
const SPANS = new RegExp(
  [
    '(`+)((?:(?!\\1)[^\\n])+?)\\1',
    '!?\\[[^\\]\\n]*\\]\\([^)\\n]*\\)',
    '<[A-Za-z][A-Za-z0-9+.-]*:[^\\s>]*>',
    '\\b[A-Za-z][A-Za-z0-9+.-]*://[^\\s<>()]+',
  ].join('|'),
  'g',
)
// A code fence, also inside a list item or a quote. Only a bare fence closes.
const FENCE = /^[\s>]*(`{3,}|~{3,})(.*)$/

// The tunnel a `v` job on this node runs (`code tunnel --name NAME`), from the
// output of `pgrep -a -x code`. With several, the one `v` named for Claude's
// own job (tunnel-JOBID), else the last one listed.
export function tunnelName(lines: readonly string[], jobId: string): string | null {
  const names = lines.flatMap(line => / tunnel .*--name[= ](\S+)/.exec(line)?.[1] ?? [])
  return names.find(n => jobId !== '' && n === `tunnel-${jobId}`) ?? names.at(-1) ?? null
}

// A matched path, minus the dots and commas that end a sentence. `text` is
// the part of the match the link covers.
function candidate(m: RegExpMatchArray): { text: string; c: Candidate } | null {
  const path = m[2] === undefined ? m[1]!.replace(/[.,]+$/, '') : m[1]!
  // `/x` alone is more often a slash command than a path.
  if (path.startsWith('/') && path.split('/').filter(Boolean).length < 2) return null
  if (!/[A-Za-z0-9]/.test(path)) return null
  return { text: m[2] === undefined ? path : m[0], c: { path, line: m[2], col: m[3] } }
}

// Rewrites each path `link` returns a URL for; everything else is kept as is.
// Fenced code blocks, links, URLs and inline code that isn't a single path are
// left alone.
export function linkify(markdown: string, link: Link): string {
  let fence: string | null = null
  return markdown
    .split('\n')
    .map(line => {
      const f = FENCE.exec(line)
      if (fence !== null) {
        if (f && f[1]![0] === fence[0] && f[1]!.length >= fence.length && f[2]!.trim() === '') fence = null
        return line
      }
      // A run of backticks with another on the line is inline code, not a fence.
      if (f && !(f[1]![0] === '`' && f[2]!.includes('`'))) {
        fence = f[1]!
        return line
      }
      return linkLine(line, link)
    })
    .join('\n')
}

function linkLine(line: string, link: Link): string {
  let out = ''
  let at = 0
  for (const m of line.matchAll(SPANS)) {
    out += linkText(line.slice(at, m.index), link)
    const code = m[2]
    const whole = code === undefined ? null : WHOLE.exec(code)
    const found = whole ? candidate(whole) : null
    const url = found && found.text === code ? link(found.c) : null
    out += url ? `[${m[0]}](${url})` : m[0]
    at = m.index! + m[0].length
  }
  return out + linkText(line.slice(at), link)
}

function linkText(text: string, link: Link): string {
  let out = ''
  let at = 0
  for (const m of text.matchAll(IN_TEXT)) {
    const found = candidate(m)
    const url = found ? link(found.c) : null
    if (!found || !url) continue
    out += `${text.slice(at, m.index)}[${found.text}](${url})`
    at = m.index! + found.text.length
  }
  return out + text.slice(at)
}

// Every path in `markdown` that linkify would consider.
export function candidates(markdown: string): Candidate[] {
  const all: Candidate[] = []
  linkify(markdown, c => {
    all.push(c)
    return null
  })
  return all
}

export function absolute(path: string, cwd: string, home: string): string {
  const full = path.startsWith('/') ? path : path.startsWith('~/') ? home + path.slice(1) : `${cwd}/${path}`
  const parts: string[] = []
  for (const part of full.split('/')) {
    if (part === '' || part === '.') continue
    if (part === '..') parts.pop()
    else parts.push(part)
  }
  return '/' + parts.join('/')
}

// A file link needs a line: without one VS Code opens the path as a folder.
export function url(env: Env, abs: string, kind: Kind, c: Candidate): string {
  const path = abs
    .split('/')
    .map(s => encodeURIComponent(s).replace(/[!'()*]/g, ch => '%' + ch.charCodeAt(0).toString(16).toUpperCase()))
    .join('/')
  if (kind === 'dir') return `${env.base}${path}?windowId=_blank`
  return `${env.base}${path}:${c.line ?? '1'}${c.col ? ':' + c.col : ''}`
}

// A sent file's path as Claude shows it: relative inside the working
// directory, else from ~ when under home.
export function shown(abs: string, cwd: string, home: string): string {
  if (abs.startsWith(cwd + '/')) return abs.slice(cwd.length + 1)
  if (home !== '' && abs.startsWith(home + '/')) return '~' + abs.slice(home.length)
  return abs
}

// A file size as Claude shows it: 97 bytes, 209.9KB, 3MB.
export function size(bytes: number): string {
  let n = bytes / 1024
  if (n < 1) return `${bytes} bytes`
  for (const unit of ['KB', 'MB']) {
    if (n < 1024) return `${n.toFixed(1).replace(/\.0$/, '')}${unit}`
    n /= 1024
  }
  return `${n.toFixed(1).replace(/\.0$/, '')}GB`
}

// The tunnel, looked for once and again each minute until one is found. Rows
// drawn while a lookup runs wait for it: after /reload-plugins every row is
// drawn at once, and one that went ahead would keep its plain drawing.
type Tunnel = { env: Env | null; checkedAt: number; lookup?: Promise<Env | null> }
async function findTunnel($: EngineInterface, t: Tunnel, now: number): Promise<Env | null> {
  if (t.env === null && t.lookup === undefined && now - t.checkedAt > 60_000) {
    t.checkedAt = now
    t.lookup = lookTunnel($).finally(() => (t.lookup = undefined))
  }
  if (t.lookup !== undefined) t.env = await t.lookup
  return t.env
}

async function lookTunnel($: EngineInterface): Promise<Env | null> {
  const r = await $.process.run(
    ['sh', '-c', 'printf "%s\\n" "$HOME" "$SLURM_JOB_ID"; pgrep -a -u "$(id -u)" -x code'],
    { timeoutMs: 5_000 },
  )
  const [home = '', jobId = '', ...rest] = r.stdout.split('\n')
  const name = tunnelName(rest, jobId)
  return name === null ? null : { base: `vscode://vscode-remote/tunnel+${name}`, home }
}

export const register: Register = on => {
  const t: Tunnel = { env: null, checkedAt: -Infinity }
  // What each absolute path is, null when missing, and when that was checked.
  // A missing path is checked again after 30 s, as Claude may be about to
  // write it. Cleared when it grows large.
  const kinds = new Map<string, { kind: Kind | null; at: number }>()

  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    if (e.surface !== 'terminal') return next(e)
    try {
      const now = await $.clock.now()
      const tunnel = await findTunnel($, t, now)
      if (tunnel === null) return next(e)

      const cwd = await $.session.cwd()
      const paths = [...new Set(candidates(e.props.text).map(c => absolute(c.path, cwd, tunnel.home)))]
      if (kinds.size > 5_000) kinds.clear()
      await Promise.all(
        paths
          .filter(p => {
            const known = kinds.get(p)
            return known === undefined || (known.kind === null && now - known.at > 30_000)
          })
          .slice(0, 200)
          .map(async p => {
            const stat = await $.fs.stat(p).catch(() => null)
            kinds.set(p, { kind: stat?.kind === 'file' || stat?.kind === 'dir' ? stat.kind : null, at: now })
          }),
      )

      const text = linkify(e.props.text, c => {
        const abs = absolute(c.path, cwd, tunnel.home)
        const kind = kinds.get(abs)?.kind
        return kind ? url(tunnel, abs, kind, c) : null
      })
      return text === e.props.text ? next(e) : next({ ...e, props: { ...e.props, text } })
    } catch {
      return next(e)
    }
  })

  // Claude draws the caption with no files; the files follow as Claude would
  // list them, each existing one a tunnel link.
  on('ui.render', { component: 'ToolResult' }, async ($, e, next) => {
    const output = e.props.output as { attachments?: Attachment[] } | undefined
    const files = output?.attachments
    if (e.surface !== 'terminal' || !SENDS.has(e.props.tool) || e.props.isErrored || !files?.length) return next(e)
    try {
      const tunnel = await findTunnel($, t, await $.clock.now())
      if (tunnel === null) return next(e)
      const cwd = await $.session.cwd()
      const exists = await Promise.all(
        files.map(f => (f.path.startsWith('/') ? $.fs.stat(f.path).then(s => s.kind === 'file', () => false) : false)),
      )

      const { Box, Text, Link } = $.ui.resolve(e)
      const rows = files.map((f, i) => {
        const label = shown(f.path, cwd, tunnel.home)
        return Text({
          children: [
            Text({ dimColor: true, children: `› ${f.isImage ? '[image]' : '[file]'} ` }),
            exists[i] ? Link({ href: url(tunnel, f.path, 'file', { path: f.path }), children: label }) : label,
            Text({ dimColor: true, children: ` (${size(f.size)})` }),
          ],
        })
      })
      const caption = await next({ ...e, props: { ...e.props, output: { ...output, attachments: [] } } })
      return Box({
        flexDirection: 'column',
        children: [caption, Box({ flexDirection: 'column', marginTop: 1, paddingLeft: 2, children: rows })],
      })
    } catch {
      return next(e)
    }
  })
}
