// The conversation of this session, sent to the Neovim that started it, where it is the chat history buffer
// beside the Claude Code terminal (lua/user/ai/claude_code.lua; lua/user/ai/claude_history.lua has the lines
// it becomes). Neovim starts `claude` with this folder as `--plugin-dir` and these variables:
//   NVIM                where that Neovim listens (it sets this for everything a terminal buffer runs)
//   NVIM_CLAUDE_TOKEN   names the launch: Neovim drops what comes from a session it has closed since
//   NVIM_CLAUDE_NVIM    the nvim to call it with
//   NVIM_CLAUDE_DEBUG   "1": every row is also sent as it came in (`:let g:claude_code_debug = 1`)
// Without the first two (any other session that loads this folder) the mod does nothing; nor when NVIM is
// not on this machine (a socket's path, or a port of 127.0.0.1).
//
// A row of the conversation (`session.append`) is turned into what the history shows of it and put on a
// list, with nothing awaited: the row goes on at once. A timer started at `session.start` sends the list:
//   nvim -u NONE -i NONE --headless -c 'lua …'      (the code is `SEND` below)
// with a batch on its standard input, the JSON of `{ v, token, session, cwd, ops }`. It prints what Neovim
// answered: "ok", "stale" (another launch: the mod stops) or "bad". The conversation is never among a
// program's arguments, which other accounts on the machine can read. Each op has an id made from its row's,
// and Neovim draws an id once: sending again is safe.
//
// What a session held before the mod saw it (a conversation that is resumed) is read back with
// `$.session.messages` and sent the same way; so is everything, again, when Neovim did not answer for long.
// After /clear or /resume the session has another id, which starts a new section in the history.
//
// Nothing a row holds is run or looked up here: text goes to Neovim as text. The one program started is the
// nvim that started Claude Code, with code that is a constant of this file: no file of this folder is run
// while a session lasts, so one that a command of Claude Code's rewrote has nothing to say until the next.
import type { EngineInterface, Register } from 'claude-code'

/** A line of the history, as lua/user/ai/claude_history.lua reads it. */
type Op =
  | { op: 'user'; id: string; text: string; at?: number; folded?: true }
  | { op: 'assistant'; id: string; text: string }
  | { op: 'tool'; id: string; tool_id: string; name: string; input: Record<string, string> }
  | { op: 'result'; tool_id: string; error?: string }
  | { op: 'notice'; id: string; text: string }
  | { op: 'debug'; text: string }

/** `isKept`: read back from the session, not rows the hooks left (which is what `held` counts). */
type Batch = { session: string; cwd: string; ops: Op[]; isKept?: true }

/** What the hooks leave for the timer, oldest first: a row's ops, or a /clear or /resume of that session. */
type Item = { ops: Op[] } | { ended: string }

type Link = { server: string; token: string; nvim: string; debug: boolean }

type Block = { type: string; [field: string]: unknown }

/** A row as `session.append` hands it: what is read of it here. */
type Row = {
  message: { type: string; name?: string; isMeta?: true; content: readonly Block[] }
  door: string
  origin: { kind: string }
  uuid: string
  agentId?: string
}

/** A row as `$.session.messages` hands it. */
type Kept = {
  role: string
  text: string
  toolUses: readonly { tool_use_id: string; tool: string; input: Record<string, unknown>; text?: string; isError?: true }[]
  toolResults?: readonly { tool_use_id: string; text: string; isError: boolean }[]
  uuid?: string
}

const TICK = 200 // milliseconds between two looks at the list
const BATCH = 250_000 // bytes of JSON a batch is cut at
const HELD = 5_000 // ops kept while Neovim does not answer; past that the conversation is read back instead
const MOST = 4096 // rows `$.session.messages` reads at most
const NEW_ID = 5_000 // milliseconds a /clear or /resume is given to show its session's id
const AGAIN = 2_000 // milliseconds after which a session that began is read back once more (it may still load)
const TOKEN = /^[0-9a-f]{8,64}$/
/** Where a Neovim of this machine listens: a socket's path, or a port of its own. */
const LOCAL = /^(\/|127\.0\.0\.1:\d+$|localhost:\d+$)/
/**
 * What the nvim that carries a batch runs, as `-c lua …`: one line once joined, so no comments in it; and no
 * backslashes or backticks, so that the text in this file is the text that runs. It reads the batch from its
 * standard input, asks the Neovim at $NVIM to `receive` it, and prints the answer.
 *
 * It talks to that Neovim over a plain socket and reads what comes back as an answer and nothing else. Over
 * a channel of Neovim's own (`sockconnect(…, { rpc = true })`, `--remote-expr`) the other end may ask for
 * things too, running code here included: whatever had taken the place of that Neovim could.
 *
 * tests/claude_code.lua of the configuration runs this text as it stands here, against a real Neovim.
 */
const SEND = `
local uv = vim.uv
local server = vim.env.NVIM or ''
local port = server:match('^127%.0%.0%.1:(%d+)$') or server:match('^localhost:(%d+)$')
local function fail(why) io.stderr:write(tostring(why) .. string.char(10)) os.exit(1) end
if server:sub(1, 1) ~= '/' and not port then fail('not where a Neovim of this machine listens') end
local batch = io.read('*a') or ''
local code = "return require('user.ai.claude_code').receive(...)"
local request = vim.mpack.encode({ 0, 1, 'nvim_exec_lua', { code, { batch } } })
local sock = port and uv.new_tcp() or uv.new_pipe(false)
local got, answer, failed = '', nil, nil
local function connected(err)
  if err then failed = err return end
  sock:read_start(function(read_err, chunk)
    if read_err or not chunk then failed = failed or read_err or 'Neovim closed the connection' return end
    got = got .. chunk
    if #got > 65536 then failed = 'too long an answer' return end
    local whole, reply = pcall(vim.mpack.decode, got)
    if whole then answer = reply end
  end)
  sock:write(request)
end
if port then sock:connect('127.0.0.1', tonumber(port), connected) else sock:connect(server, connected) end
vim.wait(8000, function() return answer ~= nil or failed ~= nil end, 5)
if answer == nil then fail(failed or 'no answer from Neovim') end
if type(answer) ~= 'table' or answer[1] ~= 1 or answer[2] ~= 1 then fail('not an answer to what was asked') end
if type(answer[3]) == 'table' then fail(answer[3][2] or 'Neovim refused it') end
if type(answer[4]) ~= 'string' then fail('not an answer to what was asked') end
io.stdout:write(answer[4])
os.exit(0)
`
  .trim()
  .split('\n')
  .map(line => line.trim())
  .join(' ')
/** The fields of a tool call the history's one line is made from. */
const SHOWN = ['file_path', 'notebook_path', 'path', 'command', 'pattern', 'url', 'query', 'description', 'skill']

let link: Link | undefined
let timer: { cancel: () => void } | undefined
let queue: Item[] = []
let out: Batch[] = []
let held = 0 // ops in `queue` and `out`
let session = ''
let cwd = ''
let reread = false // the conversation is to be read back and sent
let again: number | undefined // when to do that once more
let ended: { id: string; at: number } | undefined // a /clear or /resume whose new session is not known yet
let boundary: string | undefined // the id the last compaction of this session was sent under
let busy = false
let leaving = false // the session is ending: what is left is being sent by `last`, not by the timer
let failures = 0
let refused = 0 // times Neovim could not read the batch in front
let notBefore = 0
let told = false

// -------------------------------------------------------------------------------------------- rows to ops

const utf8 = new TextEncoder()

/** Half a surrogate pair is not text JSON can carry to Neovim. */
const LONE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g
const clean = (text: string): string => text.replace(LONE, '�')
const oneLine = (text: string, most: number): string => clean((text.split('\n', 1)[0] ?? '').slice(0, most))

/** Now, when this environment has a clock of its own (else the timer says when it took the row). */
function when(): number | undefined {
  const now = Date.now()
  return Number.isFinite(now) && now > 1e12 ? now : undefined
}

/** The text blocks of a row, or of a tool result's content. */
function textOf(content: unknown): string {
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return ''
  const texts: string[] = []
  for (const block of content as readonly Block[]) {
    if (block !== null && typeof block === 'object' && block.type === 'text' && typeof block.text === 'string') {
      texts.push(block.text)
    }
  }
  return texts.join('\n\n')
}

/** `/name args` of the record a slash command leaves. */
function commandLine(text: string): string | undefined {
  const name = /<command-name>\s*\/?([^<\s]+)\s*<\/command-name>/.exec(text)?.[1]
  if (name === undefined) return undefined
  const args = /<command-args>([\s\S]*?)<\/command-args>/.exec(text)?.[1]?.trim() ?? ''
  return oneLine(`/${name}${args === '' ? '' : ` ${args}`}`, 200)
}

/** The words of a prompt that joined a running turn, out of what the engine says around them. */
function folded(text: string): string {
  const inner = text.replace(/<\/?system-reminder>/g, '').trim()
  const framed = /^The user sent [^\n]*:\n([\s\S]*?)(?:\n\n[A-Z][^\n]*)?$/.exec(inner)
  return (framed?.[1] ?? inner).trim()
}

/** The person's words in a stored row, without what the engine put in the same row for the model. */
function typed(text: string): string {
  return text
    .replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, '')
    .replace(/<local-command-(stdout|stderr|caveat)>[\s\S]*?<\/local-command-\1>/g, '')
    .trim()
}

/** A prompt. `isFolded`: one typed while Claude worked, which can come in by two rows (Neovim shows it once). */
function user(ops: Op[], id: string, text: string, at: number | undefined, isFolded: boolean): void {
  if (text.trim() === '') return
  const op: Op = { op: 'user', id, text: clean(text) }
  if (at !== undefined) op.at = at
  if (isFolded) op.folded = true
  ops.push(op)
}

function tool(id: string, name: unknown, input: unknown): Op {
  const kept: Record<string, string> = {}
  if (input !== null && typeof input === 'object') {
    for (const key of SHOWN) {
      const value = (input as Record<string, unknown>)[key]
      if (typeof value === 'string' && value !== '') kept[key] = clean(value.slice(0, 400))
    }
  }
  return { op: 'tool', id: `tool:${id}`, tool_id: id, name: typeof name === 'string' ? oneLine(name, 120) : 'tool', input: kept }
}

function result(id: string, isError: boolean, text: string): Op {
  return isError ? { op: 'result', tool_id: id, error: oneLine(text.trim(), 300) } : { op: 'result', tool_id: id }
}

/** What the history shows of a row as it is appended. */
function rowOps(row: Row, debug: boolean): Op[] {
  const ops: Op[] = []
  const { message, door, uuid } = row
  if (debug) {
    const kinds = message.content.map(block => block.type).join(',')
    const more = `${message.name === undefined ? '' : ` name=${message.name}`}${message.isMeta === true ? ' meta' : ''}`
    const whose = row.agentId === undefined ? '' : ' (a subagent)'
    ops.push({ op: 'debug', text: clean(`row: door=${door} type=${message.type}${more} origin=${row.origin.kind} blocks=${kinds}${whose}`) })
  }
  if (row.agentId !== undefined) return ops // a subagent's own conversation
  const text = textOf(message.content)
  const isPerson = row.origin.kind === 'composer' || row.origin.kind === 'bridge'

  if (message.name === 'compact_boundary') {
    ops.push({ op: 'notice', id: uuid, text: 'Conversation compacted' })
  } else if (door === 'prompt') {
    if (message.isMeta !== true) user(ops, uuid, text, when(), false)
  } else if (door === 'delivery' || (door === 'attachment' && message.name === 'queued_command')) {
    // a prompt typed while Claude was working (a notification that joins a turn the same way is not shown)
    if (isPerson) user(ops, uuid, folded(text), when(), true)
  } else if (door === 'command') {
    const line = commandLine(text)
    if (line !== undefined) ops.push({ op: 'notice', id: uuid, text: line })
  } else if (door === 'response') {
    let isSaid = false
    for (const block of message.content) {
      if (block.type === 'text' && !isSaid) {
        isSaid = true
        if (text.trim() !== '') ops.push({ op: 'assistant', id: `${uuid}:t`, text: clean(text) })
      } else if (block.type === 'tool_use' && typeof block.id === 'string') {
        ops.push(tool(block.id, block.name, block.input))
      }
    }
  } else if (door === 'tool-result') {
    for (const block of message.content) {
      if (block.type === 'tool_result' && typeof block.tool_use_id === 'string') {
        ops.push(result(block.tool_use_id, block.is_error === true, textOf(block.content)))
      }
    }
  }
  return ops
}

/**
 * What the history shows of rows the session already held, with the same ids `rowOps` gives them.
 * `compacted`: the id a compaction of this session was sent under as it happened, which its summary here
 * (another row) is given too, so that it is one line in the history.
 */
function keptOps(rows: readonly Kept[], debug: boolean, compacted: string | undefined): Op[] {
  const ops: Op[] = []
  if (rows.length >= MOST) {
    ops.push({ op: 'notice', id: 'cut', text: `Only the newest ${MOST} messages since the last compaction are here` })
  }
  rows.forEach((row, index) => {
    const id = row.uuid ?? `kept:${index}`
    if (debug) {
      const counts = `text=${row.text.length} toolUses=${row.toolUses.length} toolResults=${row.toolResults?.length ?? 0}`
      ops.push({ op: 'debug', text: `kept row: role=${row.role} ${counts}` })
    }
    if (row.role === 'assistant') {
      if (row.text.trim() !== '') ops.push({ op: 'assistant', id: `${id}:t`, text: clean(row.text) })
      for (const use of row.toolUses) {
        ops.push(tool(use.tool_use_id, use.tool, use.input))
        if (use.text !== undefined) ops.push(result(use.tool_use_id, use.isError === true, use.text))
      }
      return
    }
    for (const answer of row.toolResults ?? []) ops.push(result(answer.tool_use_id, answer.isError, answer.text))
    const line = commandLine(row.text)
    if (line !== undefined) {
      ops.push({ op: 'notice', id, text: line })
    } else if (row.text.startsWith('This session is being continued from a previous conversation')) {
      ops.push({ op: 'notice', id: compacted ?? id, text: 'Conversation compacted' })
    } else if (/^\s*<system-reminder>\s*The user sent /.test(row.text)) {
      user(ops, id, folded(row.text), undefined, true)
    } else {
      user(ops, id, typed(row.text), undefined, false)
    }
  })
  return ops
}

// ---------------------------------------------------------------------------------------------- to Neovim

/** `ops` in pieces of a size that is sent in one go; `isEmptySent`: one piece even for no ops. */
function cut(ops: readonly Op[], isEmptySent: boolean): Op[][] {
  const pieces: Op[][] = []
  let now: Op[] = []
  let size = 0
  for (const op of ops) {
    const bytes = utf8.encode(JSON.stringify(op)).length + 1
    if (now.length > 0 && size + bytes > BATCH) {
      pieces.push(now)
      now = []
      size = 0
    }
    now.push(op)
    size += bytes
  }
  if (now.length > 0 || (isEmptySent && pieces.length === 0)) pieces.push(now)
  return pieces
}

/** Hands a batch to Neovim. Answers "ok", "stale" or "bad" as Neovim did, or why there is no such answer. */
async function send($: EngineInterface, to: Link, batch: Batch, timeoutMs: number): Promise<string> {
  const text = JSON.stringify({ v: 1, token: to.token, session: batch.session, cwd: batch.cwd, ops: batch.ops })
  try {
    // (`cquit`: where the code above did not end nvim itself, it failed)
    const ran = await $.process.run([to.nvim, '-u', 'NONE', '-i', 'NONE', '--headless', '-c', `lua ${SEND}`, '-c', 'cquit 1'], {
      cwd: '/',
      env: { NVIM_LOG_FILE: '/dev/null', NVIM: to.server },
      stdin: text,
      timeoutMs,
    })
    const said = ran.stdout.trim()
    if (ran.exitCode === 0 && (said === 'ok' || said === 'stale' || said === 'bad')) return said
    if (ran.exitCode === 0) return `it answered ${oneLine(said, 60) || 'nothing'}`
    return oneLine(ran.stderr.trim(), 160) || `nvim exited with ${ran.exitCode}`
  } catch (error) {
    return oneLine(String(error), 160)
  }
}

/** Counts a try that failed: the next one waits, longer each time. After three the person is told, once. */
async function failed($: EngineInterface, what: string, why: string): Promise<void> {
  failures += 1
  notBefore = (await $.clock.now()) + Math.min(30_000, 250 * 2 ** failures)
  $.ui.log(`${$.plugin.name}: ${what}: ${why}`, { to: 'debug' })
  if (failures === 3 && !told) {
    told = true
    $.ui.log(
      `${$.plugin.name}: the chat history in Neovim is not being filled (${why}). Claude Code itself is not affected.`,
      { to: 'transcript' },
    )
  }
}

/** Lets go of what is held: the conversation is read back when Neovim answers again. */
function shed(): void {
  for (const item of queue) {
    if ('ended' in item) ended = { id: item.ended, at: -1 }
  }
  queue = []
  out = []
  held = 0
  refused = 0
  reread = true
}

function stop(): void {
  timer?.cancel()
  timer = undefined
  link = undefined
  queue = []
  out = []
  held = 0
}

/** The next /clear or /resume the list holds. */
function nextEnded(): string | undefined {
  for (const item of queue) {
    if ('ended' in item) return item.ended
  }
  return undefined
}

/** Sends what there is, in order: what is cut already, a session that began, what the hooks left. */
async function drain($: EngineInterface, to: Link): Promise<void> {
  if (out.length === 0 && queue.length === 0 && !reread && ended === undefined && again === undefined) return
  const now = await $.clock.now()
  if (now < notBefore) return
  if (again !== undefined && now >= again) {
    again = undefined
    reread = true
  }

  for (;;) {
    while (out.length > 0) {
      const batch = out[0] as Batch
      const answer = await send($, to, batch, 10_000)
      if (leaving) return
      if (answer === 'stale') return stop()
      if (out[0] !== batch) continue // (let go of meanwhile)
      if (answer === 'ok' || (answer === 'bad' && refused >= 1)) {
        // (a batch Neovim cannot read twice is left out: what follows it still arrives)
        out.shift()
        if (batch.isKept !== true) held = Math.max(0, held - batch.ops.length)
        refused = 0
        if (answer === 'ok') failures = 0
        continue
      }
      if (answer === 'bad') refused += 1
      await failed($, 'Neovim did not take the chat history', answer)
      return
    }

    if (ended !== undefined) {
      if (ended.at < 0) ended.at = now
      const id = await $.session.id()
      if (id === ended.id && now - ended.at < NEW_ID) return
      session = id
      ended = undefined
      reread = true
      again = now + AGAIN
    }
    if (reread && nextEnded() !== undefined) {
      // ended again since: what would be read is a later session's, which is read when the list comes to
      // it (the rows the list has before that are filed under the session they were of)
      reread = false
      again = undefined
    }
    if (reread) {
      // (cleared first: what is let go of while this waits asks for another one)
      reread = false
      let rows
      try {
        cwd = await $.session.cwd()
        rows = await $.session.messages({ last: MOST })
      } catch (error) {
        reread = true
        await failed($, 'the conversation could not be read back', oneLine(String(error), 160))
        return
      }
      if (leaving) return
      if (!Array.isArray(rows)) $.ui.log(`${$.plugin.name}: the conversation may not be read back`, { to: 'debug' })
      const ops = Array.isArray(rows) ? keptOps(rows, to.debug, boundary) : []
      for (const piece of cut(ops, true)) out.push({ session, cwd, ops: piece, isKept: true })
      continue
    }

    if (queue.length === 0) return
    if (nextEnded() === undefined) {
      // a session that went on under another id with no word of it: what follows is its own section
      const id = await $.session.id()
      if (id !== session) {
        session = id
        boundary = undefined
        reread = true
        continue
      }
    }
    const dir = await $.session.cwd() // (before a row is taken off the list: failing here loses none)
    if (leaving) return
    const ops: Op[] = []
    let whose = session
    while (queue.length > 0) {
      const item = queue.shift() as Item
      if ('ended' in item) {
        whose = item.ended // (the rows before it are that session's)
        ended = { id: item.ended, at: now }
        break
      }
      for (const op of item.ops) ops.push(op.op === 'user' && op.at === undefined ? { ...op, at: now } : op)
    }
    cwd = dir
    for (const piece of cut(ops, false)) out.push({ session: whose, cwd, ops: piece })
  }
}

async function tick($: EngineInterface): Promise<void> {
  const to = link
  if (busy || leaving || to === undefined) return
  busy = true
  try {
    await drain($, to)
  } catch (error) {
    $.ui.log(`${$.plugin.name}: ${oneLine(String(error), 200)}`, { to: 'debug' })
  } finally {
    busy = false
  }
}

/**
 * What the timer has not sent, as the session ends: one try, and a short one. A batch that is on its way
 * just then is sent again with the rest (Neovim draws an id once): waiting for it could outlast the session.
 */
async function last($: EngineInterface, to: Link): Promise<void> {
  leaving = true
  try {
    const ops: Op[] = []
    for (const item of queue) {
      if ('ops' in item) ops.push(...item.ops)
    }
    const rest = [...out]
    for (const piece of cut(ops, false)) rest.push({ session, cwd, ops: piece })
    queue = []
    out = []
    held = 0
    for (const batch of rest) {
      if ((await send($, to, batch, 1_000)) !== 'ok') return
    }
  } finally {
    leaving = false
  }
}

async function begin($: EngineInterface, dir: string): Promise<void> {
  timer?.cancel()
  timer = undefined
  link = undefined
  const server = await $.env.get('NVIM')
  const token = await $.env.get('NVIM_CLAUDE_TOKEN')
  if (server === undefined || !LOCAL.test(server) || token === undefined || !TOKEN.test(token)) return
  const nvim = await $.env.get('NVIM_CLAUDE_NVIM')
  const debug = await $.env.get('NVIM_CLAUDE_DEBUG')
  session = await $.session.id()
  cwd = dir
  queue = []
  out = []
  held = 0
  ended = undefined
  again = undefined
  boundary = undefined
  reread = true // (what a resumed conversation holds; and with nothing held, the first word to Neovim)
  busy = false
  leaving = false
  failures = 0
  refused = 0
  notBefore = 0
  told = false
  link = {
    server,
    token,
    nvim: nvim !== undefined && nvim.startsWith('/') ? nvim : 'nvim',
    debug: debug === '1',
  }
  timer = $.clock.every(TICK, () => {
    void tick($)
  })
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    try {
      await begin($, e.cwd)
    } catch (error) {
      $.ui.log(`${$.plugin.name}: not started: ${oneLine(String(error), 200)}`, { to: 'debug' })
    }
    return started
  })

  // Nothing is awaited here but the row's own way on: a row is never held up for the history.
  on('session.append', ($, e, next) => {
    if (link !== undefined) {
      try {
        const ops = rowOps(e, link.debug)
        if (e.message.name === 'compact_boundary' && e.agentId === undefined) boundary = e.uuid
        if (ops.length > 0) {
          queue.push({ ops })
          held += ops.length
          if (held > HELD) shed()
        }
      } catch {
        // (a row this cannot read is one line less in the history)
      }
    }
    return next(e)
  }).catch(($, e, next) => next(e))

  on('session.end', async ($, e, next) => {
    const to = link
    if (to !== undefined && (e.reason === 'clear' || e.reason === 'resume')) {
      // these go on under another session id: what follows is another section of the history
      queue.push({ ended: e.sessionId })
      boundary = undefined
    } else if (to !== undefined && (e.reason === 'prompt_input_exit' || e.reason === 'logout')) {
      // Claude Code is leaving, with Neovim still there (not so when a signal ends it: Neovim may be closing)
      try {
        await last($, to)
      } catch {
        // (the last lines are not in the history)
      }
    }
    return next(e)
  })
}
