// What the mod sends to Neovim for what a session does:
//   claude plugin test ~/.config/nvim/claude-code
// Nothing sits beneath the mod here: the hooks of `world` stand for the engine and for Neovim, which is the
// `process.run` hook: it keeps each call and answers what `at.answers` holds next ("ok" when nothing does).
// The other half, what Neovim makes of a batch (and the code of `SEND`, which hands it over), is
// tests/claude_code.lua of the configuration.
import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

type Batch = { v: number; token: string; session: string; cwd: string; ops: Record<string, unknown>[] }
type Call = { argv: readonly string[]; init: { cwd?: string; env?: Record<string, string>; stdin?: string; timeoutMs?: number } }

const ENV = {
  NVIM: '/run/user/1000/nvim.4242.0',
  NVIM_CLAUDE_TOKEN: '0123456789abcdef',
  NVIM_CLAUDE_NVIM: '/usr/bin/nvim',
}
const START = { cwd: '/work/proj', surface: 'terminal', isInteractive: true } as const
const MODEL = { kind: 'model', model: 'claude-opus-5-5' } as const
const PERSON = { kind: 'composer' } as const
const WHEN = 'when it was typed'

function world(on: On, env: Readonly<Record<string, string>> = ENV) {
  const at = {
    clock: mock.clock(on, { now: 1_795_000_000_000 }),
    id: 's1',
    cwd: '/work/proj',
    rows: [] as unknown[],
    /** What Neovim answers to the next calls: an answer, or `!` and what nvim wrote when it failed. */
    answers: [] as string[],
    calls: [] as Call[],
    logs: [] as string[],
    /** While true a call to Neovim does not answer: it waits in `held` until `release`. */
    isHeld: false,
    held: [] as (() => void)[],
    /** How often the conversation was read back; `isUnread`: reading it fails. */
    reads: 0,
    isUnread: false,
    /** How often asking for the directory fails next. */
    lost: 0,
  }
  mock.env(on, env)
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.end', (_, e) => ({ sessionId: e.sessionId }))
  on('session.id', () => ({ value: at.id }))
  on('session.cwd', () => {
    if (at.lost > 0) {
      at.lost -= 1
      throw new Error('no directory just now')
    }
    return { value: at.cwd }
  })
  on('session.messages', () => {
    at.reads += 1
    if (at.isUnread) throw new Error('not to be read just now')
    return { value: at.rows as never }
  })
  on('ui.log', (_, e) => {
    at.logs.push(`${e.to}: ${e.text}`)
    return { value: undefined }
  })
  on('process.run', async (_, e) => {
    at.calls.push({ argv: e.argv, init: e.init ?? {} })
    const answer = at.answers.shift() ?? 'ok'
    if (at.isHeld) await new Promise<void>(resolve => at.held.push(resolve))
    const failed = answer.startsWith('!')
    return {
      value: {
        exitCode: failed ? 1 : 0,
        stdout: failed ? '' : answer,
        stderr: failed ? `${answer.slice(1)}\n` : '',
        isStdoutTruncated: false,
        isStderrTruncated: false,
      },
    }
  })
  return at
}

/** Lets what does not wait for a timer or for Neovim run on. */
async function settle(): Promise<void> {
  for (let turn = 0; turn < 400; turn += 1) await Promise.resolve()
}

/** Neovim answers the calls that waited, and from now on at once. */
async function release(at: ReturnType<typeof world>): Promise<void> {
  at.isHeld = false
  for (const answer of at.held.splice(0)) answer()
  await settle()
}

const said = (uuid: string, words: string) => ({
  door: 'response' as const,
  origin: MODEL,
  uuid,
  message: { type: 'assistant' as const, role: 'assistant' as const, content: text(words) },
})

/** The batches the calls so far handed over: each on the standard input of its call. */
const batches = (calls: readonly Call[]) => calls.map(call => JSON.parse(call.init.stdin ?? '') as Batch)

/** The ops the calls so far carried; the time of a prompt, which is the real clock's, as `WHEN`. */
const ops = (calls: readonly Call[]) =>
  batches(calls)
    .flatMap(batch => batch.ops)
    .map(op => (typeof op.at === 'number' ? { ...op, at: WHEN } : op))
const text = (value: string) => [{ type: 'text', text: value }]

test('a turn reaches Neovim as the lines of the history', async ($, on) => {
  const at = world(on)
  await $.session.start(START)
  await at.clock.advance(250)

  // the first word: this session, with nothing in it yet
  expect(at.calls.length).toBe(1)
  const first = at.calls[0] as Call
  expect(first.argv.slice(0, 7)).toEqual(['/usr/bin/nvim', '-u', 'NONE', '-i', 'NONE', '--headless', '-c'])
  // (code of the mod's own, in one line: no file of the mod's folder is run)
  expect(first.argv[7]?.startsWith('lua local uv = vim.uv ')).toBe(true)
  expect(/[\n\\`]/.test(first.argv[7] ?? '')).toBe(false)
  expect(first.argv.slice(8)).toEqual(['-c', 'cquit 1'])
  expect({ ...first.init, stdin: undefined }).toEqual({
    cwd: '/',
    env: { NVIM_LOG_FILE: '/dev/null', NVIM: '/run/user/1000/nvim.4242.0' },
    stdin: undefined,
    timeoutMs: 10_000,
  })
  expect(batches(at.calls)).toEqual([{ v: 1, token: ENV.NVIM_CLAUDE_TOKEN, session: 's1', cwd: '/work/proj', ops: [] }])

  await $.session.append({
    door: 'prompt',
    origin: PERSON,
    uuid: 'u1',
    message: { type: 'user', role: 'user', content: text('fix the parser') },
  })
  await $.session.append({
    door: 'response',
    origin: MODEL,
    uuid: 'a1',
    message: { type: 'assistant', role: 'assistant', content: [{ type: 'thinking', thinking: 'hm' }] },
  })
  await $.session.append({
    door: 'response',
    origin: MODEL,
    uuid: 'a2',
    message: { type: 'assistant', role: 'assistant', content: text('Looking at `src/parse.rs`.') },
  })
  await $.session.append({
    door: 'response',
    origin: MODEL,
    uuid: 'a3',
    message: {
      type: 'assistant',
      role: 'assistant',
      content: [
        {
          type: 'tool_use',
          id: 't1',
          name: 'Read',
          input: { file_path: '/work/proj/src/parse.rs', limit: 40, secret: 'not a field the history shows' },
        },
      ],
    },
  })
  await $.session.append({
    door: 'tool-result',
    origin: { kind: 'tool', tool: 'Read' },
    uuid: 'r1',
    message: {
      type: 'user',
      role: 'user',
      content: [{ type: 'tool_result', tool_use_id: 't1', content: 'fn parse() {}\n'.repeat(500) }],
    },
  })
  await $.session.append({
    door: 'response',
    origin: MODEL,
    uuid: 'a4',
    message: {
      type: 'assistant',
      role: 'assistant',
      content: [{ type: 'tool_use', id: 't2', name: 'Bash', input: { command: 'cargo test' } }],
    },
  })
  await $.session.append({
    door: 'tool-result',
    origin: { kind: 'tool', tool: 'Bash' },
    uuid: 'r2',
    message: {
      type: 'user',
      role: 'user',
      content: [
        {
          type: 'tool_result',
          tool_use_id: 't2',
          is_error: true,
          content: [{ type: 'text', text: 'error[E0433]: failed to resolve\nand much more' }],
        },
      ],
    },
  })
  await at.clock.advance(250)

  expect(ops(at.calls)).toEqual([
    { op: 'user', id: 'u1', text: 'fix the parser', at: WHEN },
    { op: 'assistant', id: 'a2:t', text: 'Looking at `src/parse.rs`.' },
    { op: 'tool', id: 'tool:t1', tool_id: 't1', name: 'Read', input: { file_path: '/work/proj/src/parse.rs' } },
    { op: 'result', tool_id: 't1' },
    { op: 'tool', id: 'tool:t2', tool_id: 't2', name: 'Bash', input: { command: 'cargo test' } },
    { op: 'result', tool_id: 't2', error: 'error[E0433]: failed to resolve' },
  ])
  expect(at.logs).toEqual([])
  // nothing of the conversation is among a program's arguments
  expect(at.calls.every(call => !call.argv.join(' ').includes('parser'))).toBe(true)
})

test('only the conversation itself is shown', async ($, on) => {
  const at = world(on)
  await $.session.start(START)
  await at.clock.advance(250)

  // a subagent's rows, a reminder, the queue's own record, a notification that joins the turn
  await $.session.append({
    door: 'response',
    origin: MODEL,
    uuid: 'x1',
    agentId: 'agent-1',
    message: { type: 'assistant', role: 'assistant', content: text('from a subagent') },
  })
  await $.session.append({
    door: 'prompt',
    origin: PERSON,
    uuid: 'x2',
    message: { type: 'user', role: 'user', isMeta: true, content: text('<system-reminder>a nudge</system-reminder>') },
  })
  await $.session.append({
    door: 'queue',
    origin: PERSON,
    uuid: 'x3',
    message: { type: 'user', content: text('typed while it worked') },
  })
  await $.session.append({
    door: 'delivery',
    origin: { kind: 'task-notification' },
    uuid: 'x4',
    message: { type: 'user', role: 'user', isMeta: true, content: text('a background task finished') },
  })
  // what is shown: a prompt that joined the running turn, a slash command, a compaction
  await $.session.append({
    door: 'delivery',
    origin: PERSON,
    uuid: 'd1',
    message: {
      type: 'user',
      role: 'user',
      isMeta: true,
      content: text(
        '<system-reminder>\nThe user sent a new message while you were working:\ntyped while it worked\nsecond line\n\nIMPORTANT: address it after the current task.\n</system-reminder>',
      ),
    },
  })
  await $.session.append({
    door: 'command',
    origin: PERSON,
    uuid: 'c1',
    message: {
      type: 'user',
      role: 'user',
      content: text('<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args>opus</command-args>'),
    },
  })
  await $.session.append({
    door: 'compaction',
    origin: { kind: 'engine' },
    uuid: 'n1',
    message: { type: 'system', name: 'compact_boundary', content: text('Conversation compacted') },
  })
  await at.clock.advance(250)

  expect(ops(at.calls)).toEqual([
    { op: 'user', id: 'd1', text: 'typed while it worked\nsecond line', at: WHEN, folded: true },
    { op: 'notice', id: 'c1', text: '/model opus' },
    { op: 'notice', id: 'n1', text: 'Conversation compacted' },
  ])
})

test('with the debug switch every row is also sent as it came in', async ($, on) => {
  const at = world(on, { ...ENV, NVIM_CLAUDE_DEBUG: '1' })
  await $.session.start(START)
  await $.session.append({
    door: 'attachment',
    origin: { kind: 'engine' },
    uuid: 'q1',
    message: { type: 'attachment', name: 'queued_command', role: 'user', isMeta: true, content: text('secret words') },
  })
  await at.clock.advance(250)

  expect(ops(at.calls)).toEqual([
    { op: 'debug', text: 'row: door=attachment type=attachment name=queued_command meta origin=engine blocks=text' },
  ])
})

const ELSEWHERE: readonly (readonly [string, Readonly<Record<string, string>>])[] = [
  ['not in Neovim', {}],
  ['in a Neovim terminal that is not the chat', { NVIM: ENV.NVIM }],
  ['with a token that is not one', { ...ENV, NVIM_CLAUDE_TOKEN: "x'); lua os.exit() --" }],
  ['with a Neovim that is not on this machine', { ...ENV, NVIM: 'collector.example:6666' }],
]
for (const [where, env] of ELSEWHERE) {
  test(`outside the session Neovim starts the mod does nothing: ${where}`, async ($, on) => {
    const at = world(on, env)
    await $.session.start(START)
    await $.session.append({
      door: 'prompt',
      origin: PERSON,
      uuid: 'u1',
      message: { type: 'user', role: 'user', content: text('hello') },
    })
    await at.clock.advance(2_000)
    expect(at.calls).toEqual([])
  })
}

test('/clear goes on as another session, and what came before it stays with the first', async ($, on) => {
  const at = world(on)
  await $.session.start(START)
  await at.clock.advance(250)

  await $.session.append({
    door: 'prompt',
    origin: PERSON,
    uuid: 'u1',
    message: { type: 'user', role: 'user', content: text('before') },
  })
  await $.session.end({ reason: 'clear', sessionId: 's1', resume: { id: 's1' } })
  at.id = 's2'
  await $.session.append({
    door: 'prompt',
    origin: PERSON,
    uuid: 'u2',
    message: { type: 'user', role: 'user', content: text('after') },
  })
  await at.clock.advance(250)

  expect(batches(at.calls).map(batch => [batch.session, batch.ops.map(op => op.text)])).toEqual([
    ['s1', []],
    ['s1', ['before']],
    ['s2', []],
    ['s2', ['after']],
  ])
})

test('a conversation that is resumed is read back, with the ids its rows have when appended', async ($, on) => {
  const at = world(on)
  await $.session.start(START)
  await at.clock.advance(250)

  await $.session.end({ reason: 'resume', sessionId: 's1', resume: { id: 's1' } })
  at.id = 's0'
  at.cwd = '/work/other'
  at.rows = [
    { role: 'user', text: 'This session is being continued from a previous conversation that ran out of context.', toolUses: [], uuid: 'k0' },
    { role: 'user', text: '<system-reminder>context</system-reminder>\nfix the parser', toolUses: [], uuid: 'u1' },
    { role: 'assistant', text: 'Looking.', toolUses: [], uuid: 'a2' },
    {
      role: 'assistant',
      text: '',
      toolUses: [
        { tool_use_id: 't1', tool: 'Read', input: { file_path: '/work/other/a.rs' }, text: 'fn a() {}' },
        { tool_use_id: 't2', tool: 'Bash', input: { command: 'make' }, text: 'make: *** no rule\nmore', isError: true },
        { tool_use_id: 't3', tool: 'Grep', input: { pattern: 'x' } },
      ],
      uuid: 'a3',
    },
    { role: 'user', text: '', toolUses: [], toolResults: [{ tool_use_id: 't1', text: 'fn a() {}', isError: false }], uuid: 'r1' },
    { role: 'user', text: '<command-name>/compact</command-name><command-args></command-args>', toolUses: [], uuid: 'c1' },
    { role: 'user', text: '<system-reminder>only a reminder</system-reminder>', toolUses: [], uuid: 'm1' },
  ]
  await at.clock.advance(250)

  let sent = batches(at.calls)
  expect(sent.length).toBe(2)
  expect(sent[1]).toEqual({
    v: 1,
    token: ENV.NVIM_CLAUDE_TOKEN,
    session: 's0',
    cwd: '/work/other',
    ops: [
      { op: 'notice', id: 'k0', text: 'Conversation compacted' },
      { op: 'user', id: 'u1', text: 'fix the parser' },
      { op: 'assistant', id: 'a2:t', text: 'Looking.' },
      { op: 'tool', id: 'tool:t1', tool_id: 't1', name: 'Read', input: { file_path: '/work/other/a.rs' } },
      { op: 'result', tool_id: 't1' },
      { op: 'tool', id: 'tool:t2', tool_id: 't2', name: 'Bash', input: { command: 'make' } },
      { op: 'result', tool_id: 't2', error: 'make: *** no rule' },
      { op: 'tool', id: 'tool:t3', tool_id: 't3', name: 'Grep', input: { pattern: 'x' } },
      { op: 'result', tool_id: 't1' },
      { op: 'notice', id: 'c1', text: '/compact' },
    ],
  })

  // and once more a little later, for what was still being loaded (Neovim draws an id once)
  at.rows = [...at.rows, { role: 'assistant', text: 'loaded late', toolUses: [], uuid: 'a9' }]
  await at.clock.advance(3_000)
  sent = batches(at.calls)
  expect(sent.length).toBe(3)
  expect(sent[2]?.ops.at(-1)).toEqual({ op: 'assistant', id: 'a9:t', text: 'loaded late' })
  await at.clock.advance(10_000)
  expect(at.calls.length).toBe(3)
})

test('a long message goes whole, on standard input', async ($, on) => {
  const at = world(on)
  await $.session.start(START)
  await at.clock.advance(250)

  const long = `${'é日本 '.repeat(60_000)}\ud83d the end`
  await $.session.append({
    door: 'response',
    origin: MODEL,
    uuid: 'a1',
    message: { type: 'assistant', role: 'assistant', content: text(long) },
  })
  await $.session.append({
    door: 'response',
    origin: MODEL,
    uuid: 'a2',
    message: { type: 'assistant', role: 'assistant', content: text('and a short one') },
  })
  await at.clock.advance(250)

  // (half a surrogate pair is not sent as it is: Neovim could not read the batch)
  expect(ops(at.calls)).toEqual([
    { op: 'assistant', id: 'a1:t', text: `${'é日本 '.repeat(60_000)}\ufffd the end` },
    { op: 'assistant', id: 'a2:t', text: 'and a short one' },
  ])
  // and the arguments are the same whatever is sent
  expect(new Set(at.calls.map(call => call.argv.join('\u0000'))).size).toBe(1)
})

test('what Neovim did not take is sent again, and nothing twice', async ($, on) => {
  const at = world(on)
  at.answers = ['!E247: no such server', '!E247: no such server', '!E247: no such server']
  await $.session.start(START)
  await $.session.append({
    door: 'prompt',
    origin: PERSON,
    uuid: 'u1',
    message: { type: 'user', role: 'user', content: text('hello') },
  })
  await at.clock.advance(60_000)

  expect(at.calls.length).toBe(5)
  expect(batches(at.calls.slice(3)).map(batch => batch.ops.map(op => op.text))).toEqual([[], ['hello']])
  expect(at.logs.filter(line => line.startsWith('transcript: '))).toEqual([
    'transcript: nvim-history: the chat history in Neovim is not being filled (E247: no such server). Claude Code itself is not affected.',
  ])
})

test('a batch Neovim cannot read is left out after a second try, and the next one arrives', async ($, on) => {
  const at = world(on)
  await $.session.start(START)
  await at.clock.advance(250)
  at.answers = ['bad', 'bad']
  await $.session.append({
    door: 'prompt',
    origin: PERSON,
    uuid: 'u1',
    message: { type: 'user', role: 'user', content: text('unreadable') },
  })
  await at.clock.advance(250)
  await $.session.append({
    door: 'prompt',
    origin: PERSON,
    uuid: 'u2',
    message: { type: 'user', role: 'user', content: text('readable') },
  })
  await at.clock.advance(60_000)

  expect(batches(at.calls).map(batch => batch.ops.map(op => op.text))).toEqual([[], ['unreadable'], ['unreadable'], ['readable']])
})

test('a Neovim that has closed the session is left alone', async ($, on) => {
  const at = world(on)
  at.answers = ['stale']
  await $.session.start(START)
  await at.clock.advance(250)
  await $.session.append({
    door: 'prompt',
    origin: PERSON,
    uuid: 'u1',
    message: { type: 'user', role: 'user', content: text('hello') },
  })
  await at.clock.advance(60_000)

  expect(at.calls.length).toBe(1)
})

test('what waits for Neovim stays small: past that, the conversation is read back instead', async ($, on) => {
  const at = world(on)
  await $.session.start(START)
  await at.clock.advance(250)

  // nothing is sent between these (the timer does not run): more lines than the mod holds
  for (let row = 0; row < 9; row += 1) {
    await $.session.append({
      door: 'response',
      origin: MODEL,
      uuid: `a${row}`,
      message: {
        type: 'assistant',
        role: 'assistant',
        content: Array.from({ length: 600 }, (_, i) => ({ type: 'tool_use', id: `t${row}-${i}`, name: 'Read', input: {} })),
      },
    })
  }
  await $.session.append({
    door: 'prompt',
    origin: PERSON,
    uuid: 'u9',
    message: { type: 'user', role: 'user', content: text('after') },
  })
  at.rows = [{ role: 'user', text: 'read back', toolUses: [], uuid: 'u0' }]
  await at.clock.advance(250)

  expect(ops(at.calls)).toEqual([
    { op: 'user', id: 'u0', text: 'read back' },
    { op: 'user', id: 'u9', text: 'after', at: WHEN },
  ])
})

test('a session that goes on under another id with no word of it is its own section', async ($, on) => {
  const at = world(on)
  await $.session.start(START)
  await at.clock.advance(250)

  at.id = 's2'
  at.rows = [{ role: 'user', text: 'held by the new one', toolUses: [], uuid: 'k1' }]
  await $.session.append({
    door: 'prompt',
    origin: PERSON,
    uuid: 'u1',
    message: { type: 'user', role: 'user', content: text('typed into it') },
  })
  await at.clock.advance(250)

  expect(batches(at.calls).map(batch => [batch.session, batch.ops.map(op => op.text)])).toEqual([
    ['s1', []],
    ['s2', ['held by the new one']],
    ['s2', ['typed into it']],
  ])
})

test('a compaction is one line, however often the conversation is read back', async ($, on) => {
  const at = world(on)
  await $.session.start(START)
  await at.clock.advance(250)

  await $.session.append({
    door: 'compaction',
    origin: { kind: 'engine' },
    uuid: 'n1',
    message: { type: 'system', name: 'compact_boundary', content: text('Conversation compacted') },
  })
  await at.clock.advance(250)
  // more lines than the mod holds: the conversation is read back, its summary a row of another id
  for (let row = 0; row < 9; row += 1) {
    await $.session.append({
      door: 'response',
      origin: MODEL,
      uuid: `a${row}`,
      message: {
        type: 'assistant',
        role: 'assistant',
        content: Array.from({ length: 600 }, (_, i) => ({ type: 'tool_use', id: `t${row}-${i}`, name: 'Read', input: {} })),
      },
    })
  }
  at.rows = [
    { role: 'user', text: 'This session is being continued from a previous conversation.', toolUses: [], uuid: 'k0' },
  ]
  await at.clock.advance(250)

  expect(ops(at.calls)).toEqual([
    { op: 'notice', id: 'n1', text: 'Conversation compacted' },
    { op: 'notice', id: 'n1', text: 'Conversation compacted' },
  ])
})

test('what the timer has not sent goes out as Claude Code is left', async ($, on) => {
  const at = world(on)
  await $.session.start(START)
  await at.clock.advance(250)

  await $.session.append({
    door: 'response',
    origin: MODEL,
    uuid: 'a1',
    message: { type: 'assistant', role: 'assistant', content: text('the last words') },
  })
  await $.session.end({ reason: 'prompt_input_exit', sessionId: 's1', resume: { id: 's1' } })

  expect(ops(at.calls)).toEqual([{ op: 'assistant', id: 'a1:t', text: 'the last words' }])
  expect(at.calls.at(-1)?.init.timeoutMs).toBe(1_000)
})

test('but not when a signal ends it: Neovim may be closing', async ($, on) => {
  const at = world(on)
  await $.session.start(START)
  await at.clock.advance(250)

  await $.session.append({
    door: 'response',
    origin: MODEL,
    uuid: 'a1',
    message: { type: 'assistant', role: 'assistant', content: text('the last words') },
  })
  await $.session.end({ reason: 'other', sessionId: 's1', resume: { id: 's1' } })

  expect(at.calls.length).toBe(1)
})

test('the last words go out also while a batch is on its way', async ($, on) => {
  const at = world(on)
  await $.session.start(START)
  await at.clock.advance(250)

  await $.session.append(said('a1', 'first'))
  at.isHeld = true
  await at.clock.advance(200)
  await settle()
  expect(at.held.length).toBe(1) // (the batch with a1, which Neovim has not answered)
  await $.session.append(said('a2', 'the last words'))
  at.isHeld = false
  await $.session.end({ reason: 'prompt_input_exit', sessionId: 's1', resume: { id: 's1' } })

  // what was on its way is sent again (Neovim draws it once), then the rest: by the time the session has ended
  expect(batches(at.calls).map(batch => batch.ops.map(op => op.text))).toEqual([[], ['first'], ['first'], ['the last words']])
  await release(at)
  await at.clock.advance(1_000)
  expect(at.calls.length).toBe(4)
})

test('a long conversation read back is not let go of for the rows that come meanwhile', async ($, on) => {
  const at = world(on)
  // more lines than the mod holds of its own
  at.rows = Array.from({ length: 9 }, (_, row) => ({
    role: 'assistant',
    text: '',
    toolUses: Array.from({ length: 600 }, (_, i) => ({ tool_use_id: `t${row}-${i}`, tool: 'Read', input: {} })),
    uuid: `k${row}`,
  }))
  at.isHeld = true
  await $.session.start(START)
  await at.clock.advance(250)
  await settle()
  expect(at.held.length).toBe(1) // (its first batch, on its way)

  await $.session.append(said('a1', 'said meanwhile'))
  await release(at)
  await at.clock.advance(250)
  await settle()

  const sent = ops(at.calls)
  expect(at.reads).toBe(1)
  expect(sent.filter(op => op.op === 'tool').length).toBe(5_400)
  expect(new Set(sent.map(op => op.id)).size).toBe(5_401)
  expect(sent.at(-1)).toEqual({ op: 'assistant', id: 'a1:t', text: 'said meanwhile' })
})

test('two sessions ended before Neovim answered: each one\'s rows are its own', async ($, on) => {
  const at = world(on)
  at.isHeld = true
  await $.session.start(START)
  await at.clock.advance(250)
  await settle()

  await $.session.append(said('a1', 'in s1'))
  await $.session.end({ reason: 'clear', sessionId: 's1', resume: { id: 's1' } })
  at.id = 's2'
  await $.session.append(said('a2', 'in s2'))
  await $.session.end({ reason: 'clear', sessionId: 's2', resume: { id: 's2' } })
  at.id = 's3'
  at.rows = [{ role: 'user', text: 'held by s3', toolUses: [], uuid: 'k3' }]
  await release(at)
  await at.clock.advance(250)
  await settle()

  expect(batches(at.calls).map(batch => [batch.session, batch.ops.map(op => op.text)])).toEqual([
    ['s1', []],
    ['s1', ['in s1']],
    ['s2', ['in s2']],
    ['s3', ['held by s3']],
  ])
})

test('a conversation that cannot be read back is tried again later, not at every tick', async ($, on) => {
  const at = world(on)
  at.isUnread = true
  await $.session.start(START)
  for (let tick = 0; tick < 10; tick += 1) {
    await at.clock.advance(200)
    await settle()
  }
  expect(at.calls.length).toBe(0)
  expect(at.reads).toBeGreaterThan(1)
  expect(at.reads).toBeLessThan(5)

  at.isUnread = false
  for (let tick = 0; tick < 50; tick += 1) {
    await at.clock.advance(200)
    await settle()
  }
  expect(batches(at.calls).map(batch => batch.session)).toEqual(['s1'])
})

test('a row is not lost when the directory cannot be asked for', async ($, on) => {
  const at = world(on)
  await $.session.start(START)
  await at.clock.advance(250)

  await $.session.append(said('a1', 'kept for the next try'))
  at.lost = 1
  await at.clock.advance(200)
  await settle()
  expect(at.calls.length).toBe(1)
  await at.clock.advance(200)
  await settle()

  expect(ops(at.calls)).toEqual([{ op: 'assistant', id: 'a1:t', text: 'kept for the next try' }])
})
