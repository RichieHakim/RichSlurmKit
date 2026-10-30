// node test.js: checks files.js, the part of claude-paste that runs without VS Code.

const assert = require('assert')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { fileName, stamp, save, prune, pasteText, withSkipShell } = require('./files')

assert.strictEqual(stamp(new Date(2026, 9, 3, 7, 5, 9)), '20261003-070509')

// A screenshot has no name; a copied file keeps its own, made safe to paste.
assert.strictEqual(fileName('', 'image/png', 'S', 1), 'S-1-clipboard.png')
assert.strictEqual(fileName('image.png', 'image/png', 'S', 1), 'S-1-image.png')
assert.strictEqual(fileName('My Fig (2).jpeg', 'image/jpeg', 'S', 2), 'S-2-My_Fig__2_.jpeg')
assert.strictEqual(fileName('notes', 'image/webp', 'S', 1), 'S-1-notes.webp')
assert.strictEqual(fileName('report.pdf', 'application/pdf', 'S', 1), 'S-1-report.pdf')
assert.strictEqual(fileName('../../.bashrc', '', 'S', 1), 'S-1-_.._.bashrc')
assert.strictEqual(fileName('', '', 'S', 1), 'S-1-clipboard')

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-paste-test-'))
const sub = path.join(dir, 'pastes')
const paths = save(sub, [
  { name: '', type: 'image/png', data: Buffer.from('png') },
  { name: 'a b.txt', type: 'text/plain', data: Buffer.from('text') },
], new Date(2026, 0, 2, 3, 4, 5))
assert.deepStrictEqual(paths, [path.join(sub, '20260102-030405-1-clipboard.png'), path.join(sub, '20260102-030405-2-a_b.txt')])
assert.strictEqual(fs.readFileSync(paths[1], 'utf8'), 'text')
assert.strictEqual(fs.statSync(sub).mode & 0o777, 0o700)
assert.strictEqual(fs.statSync(paths[0]).mode & 0o777, 0o600)

// Old pastes go; new ones and the log stay.
fs.writeFileSync(path.join(sub, 'log.txt'), '')
const old = Date.now() / 1000 - 8 * 24 * 3600
fs.utimesSync(paths[0], old, old)
fs.utimesSync(path.join(sub, 'log.txt'), old, old)
prune(sub)
assert.deepStrictEqual(fs.readdirSync(sub).sort(), ['20260102-030405-2-a_b.txt', 'log.txt'])
prune(path.join(dir, 'missing'))
fs.rmSync(dir, { recursive: true })

assert.strictEqual(pasteText(['/a.png', '/b.png']), '\x1b[200~/a.png /b.png\x1b[201~')

// The command joins the list in effect without losing the file's other settings.
const key = 'terminal.integrated.commandsToSkipShell'
const before = '{\n    "python.terminal.activateEnvironment": false\n}\n'
const after = JSON.parse(withSkipShell(before, ['mine'], 'claudePaste.paste'))
assert.deepStrictEqual(after, { 'python.terminal.activateEnvironment': false, [key]: ['mine', 'claudePaste.paste'] })
assert.deepStrictEqual(JSON.parse(withSkipShell('', [], 'c')), { [key]: ['c'] })
assert.deepStrictEqual(JSON.parse(withSkipShell(`{"${key}": ["x"]}`, ['x', 'y'], 'c'))[key], ['x', 'y', 'c'])
assert.strictEqual(withSkipShell('{\n  // a comment\n  "a": 1\n}', [], 'c'), null)
assert.strictEqual(withSkipShell('[]', [], 'c'), null)

console.log('claude-paste: all tests passed')
