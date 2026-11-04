import { describe, expect, test } from 'claude-code/testing'

import { lastReply } from '../hooks/register'

// /speak as the person types it, at the prompt.
const speak = (args: string) =>
  ({ command: 'speak', args, origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 120 } }) as const

const ok = (stdout: string) => ({
  value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
})

describe('lastReply', () => {
  test("Claude's last message with text, skipping tool-only messages", () => {
    const messages = [
      { role: 'user', text: 'hi' },
      { role: 'assistant', text: 'First reply.' },
      { role: 'user', text: 'more' },
      { role: 'assistant', text: 'Second reply.' },
      { role: 'assistant', text: '' },
      { role: 'user', text: '' },
    ] as const
    expect(lastReply(messages)).toBe('Second reply.')
    expect(lastReply([{ role: 'user', text: 'hi' }])).toBe(null)
  })
})

test("/speak reads the last reply to bin/speak and prints the file's path", async ($, on) => {
  // Each hook here stands for the engine.
  const status: (string | undefined)[] = []
  on('ui.status', (_, e) => {
    status.push(e.text)
    return { value: undefined }
  })
  on('session.messages', () => ({ value: [{ role: 'assistant', text: 'Hello there.', toolUses: [] }] }))
  const runs: { argv: readonly string[]; stdin?: string }[] = []
  on('process.run', (_, e) => {
    runs.push({ argv: e.argv, stdin: e.init?.stdin })
    return ok('/home/u/.cache/rsk-speak/x.mp3\n')
  })

  const result = await $.command.run(speak(''))

  expect(runs).toEqual([{ argv: ['speak'], stdin: 'Hello there.' }])
  expect(result.text).toBe('Audio: /home/u/.cache/rsk-speak/x.mp3')
  expect(status).toEqual(['making audio', undefined])
})

test('/speak with text reads that text instead', async ($, on) => {
  on('ui.status', () => ({ value: undefined }))
  on('session.messages', () => ({ value: [{ role: 'assistant', text: 'Hello there.', toolUses: [] }] }))
  const stdins: (string | undefined)[] = []
  on('process.run', (_, e) => {
    stdins.push(e.init?.stdin)
    return ok('/tmp/y.mp3\n')
  })

  await $.command.run(speak('  Read this.  '))

  expect(stdins).toEqual(['Read this.'])
})

test("bin/speak's error is shown when it fails, such as with no Kokoro", async ($, on) => {
  on('ui.status', () => ({ value: undefined }))
  on('session.messages', () => ({ value: [{ role: 'assistant', text: 'Hi.', toolUses: [] }] }))
  on('process.run', () => ({
    value: {
      exitCode: 1,
      stdout: '',
      stderr: 'speak: Kokoro is not installed. Install it with: lib/kokoro_install.sh\n',
      isStdoutTruncated: false,
      isStderrTruncated: false,
    },
  }))

  const result = await $.command.run(speak(''))

  expect(result.text).toBe('speak: Kokoro is not installed. Install it with: lib/kokoro_install.sh')
})

test('nothing to read before Claude has replied', async ($, on) => {
  on('session.messages', () => ({ value: [] }))
  let ran = false
  on('process.run', () => {
    ran = true
    return ok('')
  })

  const result = await $.command.run(speak(''))

  expect(ran).toBe(false)
  expect(result.text).toBe('Nothing to read yet.')
})
