import type { Register } from 'claude-code'

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

export type Kind = 'file' | 'dir'
export type Env = { base: string; home: string }
export type Candidate = { path: string; line?: string; col?: string }
type Link = (c: Candidate) => string | null

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

export const register: Register = on => {
  let env: Env | null = null
  let checkedAt = -Infinity
  // What each absolute path is, null when missing, and when that was checked.
  // A missing path is checked again after 30 s, as Claude may be about to
  // write it. Cleared when it grows large.
  const kinds = new Map<string, { kind: Kind | null; at: number }>()

  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    if (e.surface !== 'terminal') return next(e)
    try {
      // Look for the tunnel once, and again each minute until one is found.
      const now = await $.clock.now()
      if (env === null && now - checkedAt > 60_000) {
        checkedAt = now
        const r = await $.process.run(
          ['sh', '-c', 'printf "%s\\n" "$HOME" "$SLURM_JOB_ID"; pgrep -a -u "$(id -u)" -x code'],
          { timeoutMs: 5_000 },
        )
        const [home = '', jobId = '', ...rest] = r.stdout.split('\n')
        const name = tunnelName(rest, jobId)
        env = name === null ? null : { base: `vscode://vscode-remote/tunnel+${name}`, home }
      }
      if (env === null) return next(e)
      const tunnel = env

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
}
