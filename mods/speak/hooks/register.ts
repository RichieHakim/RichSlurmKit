import type { Register, SessionMessage } from 'claude-code'

// /speak reads Claude's last reply aloud. RichSlurmKit's bin/speak turns the
// reply into an audio file with Kokoro, and the command prints the file's
// path, which the path-links mod draws as a link that opens the file in VS
// Code. Claude runs on the cluster, where there's no sound card; VS Code plays
// the file on the laptop. No turn of Claude's is spent: the model only reads
// the path, as the command's output, at its next turn.
//
// `/speak some text` reads that text instead.

// The text of Claude's last reply: its last message with any text.
export function lastReply(messages: readonly Pick<SessionMessage, 'role' | 'text'>[]): string | null {
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i]!
    if (m.role === 'assistant' && m.text.trim() !== '') return m.text
  }
  return null
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'speak',
      description: "Read Claude's last reply aloud into an audio file to open in VS Code (or /speak <text>)",
    })
    return next(e)
  })

  on('command.run', { command: 'speak' }, async ($, e) => {
    const text = e.args.trim() || lastReply(await $.session.messages())
    if (!text) return { text: 'Nothing to read yet.' }
    // Shown as "speak: making audio".
    $.ui.status('making audio')
    try {
      // Kokoro takes a few seconds per paragraph on a CPU.
      const r = await $.process.run(['speak'], { stdin: text, timeoutMs: 600_000 })
      if (r.exitCode !== 0) return { text: r.stderr.trim() || `speak failed (exit ${r.exitCode})` }
      return { text: `Audio: ${r.stdout.trim()}` }
    } catch (err) {
      return { text: `Could not run speak, which comes with RichSlurmKit (bin/speak): ${String(err)}` }
    } finally {
      $.ui.status(undefined)
    }
  })
}
