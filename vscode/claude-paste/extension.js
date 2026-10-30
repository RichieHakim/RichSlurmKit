// Ctrl+V (Alt+V off the Mac) in a terminal pastes the laptop's clipboard
// image, or the files copied in Finder or Explorer, into Claude Code running on
// this machine.
//
// Claude reads images from the clipboard of the machine it runs on, and over a
// VS Code tunnel that machine has none: the clipboard is on the laptop. This
// extension runs here, next to Claude, but a webview it opens runs on the
// laptop, and VS Code lets webviews read the clipboard. So the webview reads
// it, the files are saved here under ~/.cache/claude-paste, and their paths are
// pasted into the terminal. Claude turns a pasted image path into [Image #N].
// With no image or file on the clipboard, the key reaches the terminal as it
// would have.

const vscode = require('vscode')
const crypto = require('crypto')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { save, prune, pasteText, withSkipShell } = require('./files')

const COMMAND = 'claudePaste.paste'
const DIR = path.join(os.homedir(), '.cache', 'claude-paste')
const LOG = path.join(DIR, 'log.txt')

function activate(context) {
  context.subscriptions.push(vscode.commands.registerCommand(COMMAND, args => paste(context, args)))
  try {
    skipShell(context)
  } catch (e) {
    log(`could not update commandsToSkipShell: ${e.message}`)
  }
}

// A focused terminal gets every key whose command isn't listed in
// terminal.integrated.commandsToSkipShell, so the keybinding does nothing until
// this command is listed. It is added to this machine's settings ("Remote" in
// VS Code's settings editor), together with the list already in effect, since a
// value there replaces the laptop's for windows on this machine.
function skipShell(context) {
  const current = vscode.workspace.getConfiguration('terminal.integrated').get('commandsToSkipShell') || []
  if (current.includes(COMMAND)) return
  // globalStorage is <server data>/User/globalStorage/<extension>.
  const data = path.dirname(path.dirname(path.dirname(context.globalStorageUri.fsPath)))
  const file = path.join(data, 'Machine', 'settings.json')
  let text = ''
  try {
    text = fs.readFileSync(file, 'utf8')
  } catch {}
  const updated = withSkipShell(text, current, COMMAND)
  if (updated === null) {
    vscode.window.showWarningMessage(
      `Claude paste: add "${COMMAND}" to terminal.integrated.commandsToSkipShell in ${file}; ` +
        'Ctrl+V in terminals does nothing new until then.',
    )
    return
  }
  fs.mkdirSync(path.dirname(file), { recursive: true })
  if (text !== '' && !fs.existsSync(file + '.bak-claude-paste')) fs.writeFileSync(file + '.bak-claude-paste', text)
  fs.writeFileSync(file, updated)
  log(`added ${COMMAND} to commandsToSkipShell in ${file}`)
}

async function paste(context, args) {
  const terminal = vscode.window.activeTerminal
  if (terminal === undefined) return
  const key = (args && args.key) || '\x16'
  let got
  try {
    got = await readClipboard(context)
  } catch (e) {
    got = { files: [], note: `webview failed: ${e.message}` }
  }
  let paths = []
  if (got.files.length > 0) {
    try {
      prune(DIR)
      paths = save(DIR, got.files.map(f => ({ name: f.name, type: f.type, data: Buffer.from(f.data, 'base64') })))
    } catch (e) {
      got.note += `; saving failed: ${e.message}`
    }
  }
  log(`${paths.length} file(s) ${paths.join(' ')} | ${got.note}`)
  terminal.show(false)
  terminal.sendText(paths.length > 0 ? pasteText(paths) : key, false)
}

// Opens the webview that reads the clipboard on the laptop, and resolves to
// what it found: { files: [{ name, type, data (base64) }], note }.
function readClipboard(context) {
  return new Promise(resolve => {
    const panel = vscode.window.createWebviewPanel(
      'claudePaste',
      'Clipboard',
      { viewColumn: vscode.ViewColumn.Active, preserveFocus: false },
      { enableScripts: true },
    )
    let done = false
    const finish = result => {
      if (done) return
      done = true
      clearTimeout(timer)
      resolve(result)
      panel.dispose()
    }
    const timer = setTimeout(() => finish({ files: [], note: 'no answer from the webview in 5 s' }), 5000)
    panel.onDidDispose(() => finish({ files: [], note: 'webview closed' }))
    panel.webview.onDidReceiveMessage(m => finish({ files: m.files || [], note: m.note || '' }))
    const nonce = crypto.randomBytes(16).toString('base64')
    const html = fs.readFileSync(path.join(context.extensionPath, 'clipboard.html'), 'utf8')
    panel.webview.html = html.replaceAll('NONCE', nonce)
  })
}

// One line per paste, for finding out why one failed. Restarted past 100 KB.
function log(line) {
  try {
    fs.mkdirSync(DIR, { recursive: true, mode: 0o700 })
    const big = fs.existsSync(LOG) && fs.statSync(LOG).size > 100_000
    fs[big ? 'writeFileSync' : 'appendFileSync'](LOG, `${new Date().toISOString()} ${line}\n`, { mode: 0o600 })
  } catch {}
}

module.exports = { activate }
