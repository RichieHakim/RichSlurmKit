// The parts of claude-paste that don't need VS Code, kept here so test.js can
// run them with plain node.

const fs = require('fs')
const path = require('path')

const EXTENSIONS = { 'image/png': '.png', 'image/jpeg': '.jpg', 'image/gif': '.gif', 'image/webp': '.webp' }
const WEEK_MS = 7 * 24 * 3600 * 1000

// A pasted file's name here: a timestamp and its place in the paste, so pastes
// never collide, then its own name with anything but letters, digits, dot,
// dash and underscore made `_` (Claude splits pasted paths at spaces). Claude
// only attaches an image whose path ends in an image extension, so an unnamed
// image (a screenshot) gets one from its type.
function fileName(name, type, stamp, i) {
  let base = (name || '').replace(/[^A-Za-z0-9._-]/g, '_').replace(/^\.+/, '')
  if (base === '') base = 'clipboard' + (EXTENSIONS[type] || '')
  else if (path.extname(base) === '' && EXTENSIONS[type]) base += EXTENSIONS[type]
  return `${stamp}-${i}-${base}`
}

function stamp(date) {
  const p = n => String(n).padStart(2, '0')
  return `${date.getFullYear()}${p(date.getMonth() + 1)}${p(date.getDate())}-` +
    `${p(date.getHours())}${p(date.getMinutes())}${p(date.getSeconds())}`
}

// Writes each { name, type, data: Buffer } to `dir`, readable only by you,
// and returns the paths.
function save(dir, files, now = new Date()) {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 })
  const s = stamp(now)
  return files.map((f, i) => {
    const p = path.join(dir, fileName(f.name, f.type, s, i + 1))
    fs.writeFileSync(p, f.data, { mode: 0o600 })
    return p
  })
}

// Deletes pastes older than a week. A paste is only needed until Claude has
// read it, and the conversation keeps its own copy of an image.
function prune(dir, now = Date.now()) {
  let names
  try {
    names = fs.readdirSync(dir)
  } catch {
    return
  }
  for (const name of names) {
    if (name === 'log.txt') continue
    const p = path.join(dir, name)
    try {
      if (now - fs.statSync(p).mtimeMs > WEEK_MS) fs.unlinkSync(p)
    } catch {}
  }
}

// What the terminal receives: the paths inside bracketed-paste marks, so
// Claude reads them as pasted rather than typed.
function pasteText(paths) {
  return `\x1b[200~${paths.join(' ')}\x1b[201~`
}

// The settings file text with `command` added to commandsToSkipShell, keeping
// `current` (the list in effect, the user's own entries included). Null when
// the file isn't plain JSON (it may hold comments), so it is never rewritten
// with parts lost.
function withSkipShell(text, current, command) {
  let settings
  try {
    settings = text.trim() === '' ? {} : JSON.parse(text)
  } catch {
    return null
  }
  if (settings === null || typeof settings !== 'object' || Array.isArray(settings)) return null
  const key = 'terminal.integrated.commandsToSkipShell'
  settings[key] = [...new Set([...(settings[key] || []), ...current, command])]
  return JSON.stringify(settings, null, 4) + '\n'
}

module.exports = { fileName, stamp, save, prune, pasteText, withSkipShell }
