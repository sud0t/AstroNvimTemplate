-- Claude Code in a buffer, with its conversation in a second one.
--
-- <Leader>AC, when the AI chosen in <Leader>As is Claude through the Claude Code login (lua/user/ai/init.lua,
-- `open_chat`), shows the `claude` terminal program itself, unchanged, as an ordinary buffer in the current
-- window: no split. Pressed again from anywhere it comes back to the session that is running. Claude Code
-- starts in the project of the file you were in (the root AstroNvim finds for it), or in Neovim's directory.
--
-- The second buffer is the chat history: the conversation as Markdown, read-only, following along as it
-- happens (lua/user/ai/claude_history.lua has what it looks like). It is a real buffer, so everything works
-- in it as in a file:
--   <CR>         opens what the cursor is on: a web link in the browser (asked first when the link's text hid
--                where it leads), a file in this window, at `path:12:3` or `path#L12` when it says so
--   <Leader>fc   greps the word under the cursor in Claude Code's directory (the snacks picker, as everywhere)
--   q            back to Claude Code
--
-- Switching between the two is <C-h> <C-j> <C-k> <C-l>, the keys that move between windows: where there is a
-- window in that direction they go there as always, and where there is none they swap the chat and the
-- history in the window. So in the Claude Code buffer these four do not reach Claude Code (a new line in the
-- prompt is <S-CR> or `\` then <CR>). <C-x> leaves terminal mode as in every terminal; <C-x> again, from normal
-- mode, sends Ctrl+X to Claude Code and goes back in (its Ctrl+X Ctrl+E is <C-x><C-x><C-e>).
--
-- How the conversation gets here: Claude Code is started with the mod in claude-code/ of this configuration
-- (`--plugin-dir`: only the sessions started here load it). The mod sees each row the conversation keeps and
-- hands it to this Neovim, which is `$NVIM` for everything a terminal buffer runs. It starts
--   nvim -u NONE -i NONE --headless -c 'lua …'       (the code is a constant of the mod, `SEND`)
-- with a batch (JSON) on its standard input, which calls `receive` here with it, over the socket. (Not
-- `--remote-expr` with the batch in it: the arguments of a program can be read by every account on the
-- machine.) `receive` only ever turns a batch into lines of the buffer. A batch names the launch it belongs
-- to (`NVIM_CLAUDE_TOKEN`): one from a session that was closed since is dropped. That is housekeeping, not a
-- lock: whatever can reach Neovim's socket can already do anything in it.
--
-- Claude Code runs as `claude` does in the shell, where a function of the same name adds the `--settings`
-- below: reads outside the directory it works in are refused. It uses the login, not a key Neovim may have
-- in $ANTHROPIC_API_KEY (that one is for the CodeCompanion chat, and would be read by every command Claude
-- Code runs). The mod is not reloaded while a session runs (CLAUDE_CODE_PLUGIN_DIR_WATCH=0), and runs no file
-- of its folder while one does: otherwise a command Claude Code runs in its sandbox could rewrite the mod
-- and have it run outside the sandbox at once. Started in this configuration's own directory or one that
-- holds it (asked first, like the home directory) it can change the mod and everything else here for the
-- next start, of Claude Code or of Neovim: as it can any project's files.
--
-- <CR> on a file outside the directory Claude Code was started in asks first, with the file's real path: a
-- link's text need not be where it leads, and opening a file starts what the editor has for its kind (a
-- language server takes its settings, and for some languages programs to run, from the file's project).
--
-- Closing the Claude Code buffer ends the program (<Leader>x asks first; the other ways of closing buffers do
-- not). The conversation is kept by Claude Code: /resume in a new session brings it back, history included.
-- Neither buffer is stored in a session (resession).
--
-- tests/claude_code.lua has the tests, and at its top what to check by hand with the real program.
local M = {}

local history = require "user.ai.claude_history"

local settings = '{"permissions":{"blockReadsOutsideWorkingDirectories":true}}'
-- variables of Neovim's that Claude Code is started without
local not_passed = { "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY", "OPENROUTER_API_KEY" }
local history_name = "claude-code://history"

-- one session per Neovim
local S = {
  term = nil, -- the terminal buffer
  job = nil, -- its job, while Claude Code runs
  token = nil, -- names this launch in the batches of its mod
  cwd = nil, -- where Claude Code was started (the history has where it is now: `S.hist.cwd`)
  hist = history.new(),
  buf = nil, -- the history buffer: a view of `S.hist.lines`
  at_end = true, -- whether the history was left with the cursor on its last line
  heard = false, -- whether the mod of this launch has reported in
  started = 0, -- when it was launched (vim.uv.now)
}

-- the longest batch taken: far more than a conversation's longest message
local max_batch = 16 * 1024 * 1024

local function notify(msg, level) vim.notify(msg, level or vim.log.levels.INFO, { title = "Claude Code" }) end

local function alive() return S.job ~= nil and vim.fn.jobwait({ S.job }, 0)[1] == -1 end

--- The window a chat goes in: the current one, unless it is one that keeps its buffer (a float, the file
--- tree, the quickfix list). Then the window the cursor came from, or the first that shows a file; and with
--- none of those, a new one. (Also for the CodeCompanion chat: `open_chat` in lua/user/ai/init.lua.)
function M.window()
  local function usable(win)
    if vim.api.nvim_win_get_config(win).relative ~= "" then return false end
    return not (vim.wo[win].winfixbuf or vim.wo[win].winfixwidth or vim.wo[win].winfixheight)
  end
  local current = vim.api.nvim_get_current_win()
  if usable(current) then return current end
  local previous = vim.fn.win_getid(vim.fn.winnr "#")
  if previous ~= 0 and previous ~= current and usable(previous) then return previous end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if usable(win) and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "" then return win end
  end
  -- (only the file tree is open, say)
  local empty = vim.api.nvim_create_buf(false, true)
  vim.bo[empty].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(empty, false, { split = "right", win = -1 })
  vim.wo[win].winfixbuf, vim.wo[win].winfixwidth, vim.wo[win].winfixheight = false, false, false
  return win
end

------------------------------------------------------------------------------------------- history buffer

--- Bring the buffer in line with `S.hist.lines` after `edits` (what history.apply returned; nil: all of it).
--- A window that was on the last line stays on the last line.
local function draw(edits)
  local buf = S.buf
  if not (buf and vim.api.nvim_buf_is_loaded(buf)) then return end
  local lines = S.hist.lines
  local count = vim.api.nvim_buf_line_count(buf)
  local following = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_get_cursor(win)[1] >= count then following[#following + 1] = win end
  end
  vim.bo[buf].modifiable = true
  local drawn, err = pcall(function()
    if not edits then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    else
      for i in pairs(edits.changed) do
        vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { lines[i] })
      end
      -- (a buffer with nothing in it has one empty line, which the first lines take the place of)
      if edits.first <= #lines then
        vim.api.nvim_buf_set_lines(buf, edits.first - 1, -1, false, vim.list_slice(lines, edits.first))
      end
    end
  end)
  vim.bo[buf].modifiable = false -- (whatever happened: the history is never left open to typing)
  if not drawn then error(err, 0) end
  for _, win in ipairs(following) do
    pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
  end
end

--- A line of this module's own in the history (Claude Code exited, the mod never reported in).
local function note(text) draw(history.apply(S.hist, { ops = { { op = "notice", text = text } } })) end

--- Open what the cursor is on (see the top of this file and claude_history.lua).
local function open_target()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local target = history.target(vim.api.nvim_get_current_buf(), row - 1, col)
  if not target then return notify "Nothing to open under the cursor" end
  if target.kind == "refused" then return notify("Not opened: " .. target.what, vim.log.levels.WARN) end
  if target.kind == "url" then
    -- a link's text can say one thing and lead to another, with what the model has read in the address; and
    -- an address can read as another one. The question shows it so that it cannot: see `spelled`
    if target.hidden then
      local question = ("Open this address? Asked because %s.\nHost: %s\n%s"):format(
        target.why,
        history.spelled(target.host),
        history.spelled(target.url)
      )
      if vim.fn.confirm(question, "&Yes\n&No", 2) ~= 1 then return end
    end
    local _, err = vim.ui.open(target.url)
    if err then notify(err, vim.log.levels.ERROR) end
    return
  end
  -- where a path that does not start at `/` is looked for: where Claude Code is now, where it started, here
  local dirs = {}
  for _, dir in ipairs { S.hist.cwd or false, S.cwd or false, vim.fn.getcwd() } do
    if dir and not vim.list_contains(dirs, dir) then dirs[#dirs + 1] = dir end
  end
  local found, why = history.resolve(target, dirs, S.cwd)
  if not found then return notify(why, vim.log.levels.WARN) end
  if not found.inside then
    -- (`strtrans`: a name with a line break or a mark that turns text around in it is shown as what it is)
    local question = "Open this file? It is outside the directory Claude Code was started in.\n"
      .. vim.fn.strtrans(found.path)
    if vim.fn.confirm(question, "&Yes\n&No", 2) ~= 1 then return end
  end
  vim.cmd "normal! m'"
  -- (by buffer, not `:edit`: no part of the name is expanded or read as a command)
  local file = vim.fn.bufadd(found.path)
  vim.bo[file].buflisted = true
  vim.api.nvim_win_set_buf(0, file)
  if found.line then
    local line = math.min(math.max(found.line, 1), vim.api.nvim_buf_line_count(file))
    local text = vim.api.nvim_buf_get_lines(file, line - 1, line, false)[1] or ""
    pcall(vim.api.nvim_win_set_cursor, 0, { line, math.min(math.max((found.col or 1) - 1, 0), #text) })
    vim.cmd "normal! zz"
  end
end

local nav -- (below)

--- The history buffer, made (again, after it was closed) from what the history holds.
local function history_buffer()
  if S.buf and vim.api.nvim_buf_is_loaded(S.buf) then return S.buf end
  -- closed with <Leader>x it is unloaded and unlisted, and still has the name
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf) == history_name then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  end
  local buf = vim.api.nvim_create_buf(true, true) -- listed, scratch: no file, no swap file, hidden when left
  S.buf = buf
  vim.api.nvim_buf_set_name(buf, history_name)
  vim.bo[buf].modeline = false -- (nothing the model wrote sets options)
  vim.bo[buf].undolevels = -1
  vim.bo[buf].filetype = "markdown"
  pcall(vim.treesitter.start, buf, "markdown")
  vim.bo[buf].modifiable = true
  pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, S.hist.lines)
  vim.bo[buf].modifiable = false

  local function map(lhs, rhs, desc) vim.keymap.set("n", lhs, rhs, { buffer = buf, desc = desc, nowait = true }) end
  map("<CR>", open_target, "Open the link or file under the cursor")
  map("q", function() M.switch() end, "Back to Claude Code")
  map(
    "<Leader>fc",
    function() require("snacks").picker.grep_word { cwd = S.hist.cwd or S.cwd } end,
    "Find word under cursor (Claude Code's directory)"
  )
  for _, dir in ipairs { "h", "j", "k", "l" } do
    map("<C-" .. dir .. ">", function() nav(dir) end, "Window in that direction, or Claude Code")
  end

  local group = vim.api.nvim_create_augroup("claude_code_history_" .. buf, { clear = true })
  -- Long paragraphs wrap, for this buffer in the window only (as `:setlocal`): the next buffer in the window
  -- has the window's own setting again, with nothing to put back.
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    buffer = buf,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_buf(win) ~= buf then return end
      vim.api.nvim_set_option_value("wrap", true, { win = win, scope = "local" })
      vim.api.nvim_set_option_value("linebreak", true, { win = win, scope = "local" })
    end,
  })
  vim.api.nvim_create_autocmd("BufLeave", {
    group = group,
    buffer = buf,
    callback = function()
      S.at_end = vim.api.nvim_win_get_cursor(0)[1] >= vim.api.nvim_buf_line_count(buf)
    end,
  })
  return buf
end

-------------------------------------------------------------------------------------------- the two buffers

--- The other one of the two in this window: the history from Claude Code, Claude Code from anywhere else.
function M.switch()
  local win = vim.api.nvim_get_current_win()
  if S.term and vim.api.nvim_get_current_buf() == S.term then
    vim.cmd.stopinsert()
    local buf = history_buffer()
    vim.api.nvim_win_set_buf(win, buf)
    if S.at_end then pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 }) end
    if alive() and not S.heard and vim.uv.now() - S.started > 20000 then
      notify(
        "Nothing from Claude Code's history mod yet: Claude Code says why in a dim line of its own, or with --debug",
        vim.log.levels.WARN
      )
    end
  elseif alive() and vim.api.nvim_buf_is_valid(S.term) then
    vim.api.nvim_win_set_buf(win, S.term)
    vim.cmd.startinsert()
  else
    notify "Claude Code is not running (<Leader>AC starts it)"
  end
end

--- <C-h/j/k/l> in the two buffers: with a window in that direction, what the key does everywhere else; with
--- none, the other buffer. (Decided before moving: at the edge smart-splits goes around to the far window,
--- or on to the terminal's next pane.)
function nav(dir)
  if vim.fn.winnr(dir) == vim.fn.winnr() then return M.switch() end
  if vim.api.nvim_get_mode().mode ~= "t" then
    local names = { h = "left", j = "down", k = "up", l = "right" }
    local loaded, splits = pcall(require, "smart-splits") -- (AstroNvim's normal mode keys)
    local move = loaded and splits["move_cursor_" .. names[dir]]
    if type(move) == "function" then return move() end
  end
  vim.cmd.wincmd(dir) -- (and its terminal mode keys)
end

local function send(keys)
  if alive() then vim.api.nvim_chan_send(S.job, keys) end
end

local function terminal_keys(buf)
  local function map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, desc = desc, nowait = true })
  end
  for _, dir in ipairs { "h", "j", "k", "l" } do
    map({ "t", "n" }, "<C-" .. dir .. ">", function() nav(dir) end, "Window in that direction, or the chat history")
  end
  -- Shift+Enter is a plain Enter (send!) for a program that has not asked for the kitty key encoding;
  -- Ctrl+J is a new line in Claude Code's prompt whatever it asked for
  map("t", "<S-CR>", function() send "\n" end, "New line in the prompt")
  -- Ctrl+Z would stop Claude Code with no shell around it to bring it back
  map("t", "<C-z>", "<Nop>", "Nothing (it would suspend Claude Code)")
  map("n", "<C-x>", function()
    send "\24"
    vim.cmd.startinsert()
  end, "Send Ctrl+X to Claude Code")
  map("n", "<Leader>x", function()
    if alive() and vim.fn.confirm("End the Claude Code session?", "&Yes\n&No", 2) ~= 1 then return end
    local closed = pcall(function() require("astrocore.buffer").close(buf, true) end)
    if not closed then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  end, "Close Claude Code (asks first)")
end

--- Where Claude Code starts: the project of the file in `buf` (the buffer it takes the place of), else
--- Neovim's directory. nil when the home directory or this configuration is in there (or it is in this
--- configuration), and you would rather not: Claude Code may read and write all of the directory it is
--- started in.
local function start_dir(buf)
  local dir
  if vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= "" then
    local ok, roots = pcall(function() return require("astrocore.rooter").detect(buf) end)
    dir = ok and type(roots) == "table" and roots[1] and roots[1].paths[1] or nil
  end
  dir = vim.uv.fs_realpath(dir or vim.fn.getcwd())
  if not dir then return nil, "the directory to start in is gone" end
  local config = vim.uv.fs_realpath(vim.fn.stdpath "config")
  local home = vim.uv.fs_realpath(vim.uv.os_homedir() or "")
  --- Whether `inner` is `outer` or in it.
  local function holds(outer, inner) return inner ~= nil and vim.startswith(inner .. "/", outer:gsub("/$", "") .. "/") end
  local why
  if dir == "/" or holds(dir, home) then
    why = "It may read and change everything in there."
  elseif config and (holds(config, dir) or holds(dir, config)) then
    why = "It may change the editor's own configuration, which runs outside every sandbox."
  end
  if why then
    local question = ("Start Claude Code in %s?\n%s"):format(vim.fn.fnamemodify(dir, ":~"), why)
    if vim.fn.confirm(question, "&Yes\n&No", 2) ~= 1 then return nil end
  end
  return dir
end

local function launch(win)
  local exe = vim.fn.exepath "claude"
  if exe == "" then return notify("`claude` is not installed (<Leader>As, Set up provider)", vim.log.levels.ERROR) end
  local before = vim.api.nvim_win_get_buf(win)
  local dir, why = start_dir(before)
  if not dir then return why and notify(why, vim.log.levels.ERROR) end

  local token = vim.uv.random(8):gsub(".", function(byte) return ("%02x"):format(byte:byte()) end)
  -- where the mod reaches this Neovim (`$NVIM` in what a terminal buffer runs); one started without an
  -- address gets one now
  local server = vim.v.servername
  if server == "" then
    local listening, address = pcall(vim.fn.serverstart)
    server = listening and type(address) == "string" and address or ""
  end
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_buf(win, buf)
  local argv = { exe, "--settings", settings, "--plugin-dir", vim.fn.stdpath "config" .. "/claude-code" }
  -- the login, not a key; and not the other providers' keys, as for the Claude Code chat of
  -- lua/plugins/codecompanion.lua. `env -u`: not set at all, which an empty one (below, for where there is no
  -- `env`) may not be the same as to Claude Code
  local env = vim.fn.exepath "env"
  if env ~= "" and not exe:find("=", 1, true) then
    local unset = { env }
    for _, name in ipairs(not_passed) do
      vim.list_extend(unset, { "-u", name })
    end
    argv = vim.list_extend(unset, argv)
  end
  local started, job = pcall(vim.fn.jobstart, argv, {
    term = true,
    cwd = dir,
    env = {
      NVIM = server ~= "" and server or nil,
      NVIM_CLAUDE_TOKEN = token,
      NVIM_CLAUDE_NVIM = vim.v.progpath,
      NVIM_CLAUDE_DEBUG = vim.g.claude_code_debug and "1" or "",
      CLAUDE_CODE_PLUGIN_DIR_WATCH = "0",
      ANTHROPIC_API_KEY = "",
      OPENAI_API_KEY = "",
      GEMINI_API_KEY = "",
      GOOGLE_API_KEY = "",
      OPENROUTER_API_KEY = "",
    },
    on_exit = function(id, code)
      vim.schedule(function()
        if S.job ~= id then return end
        S.job = nil
        note(("Claude Code exited (code %d)"):format(code))
      end)
    end,
  })
  if not started or job <= 0 then
    if vim.api.nvim_buf_is_valid(before) then pcall(vim.api.nvim_win_set_buf, win, before) end
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return notify("Claude Code did not start" .. (started and "" or (":\n" .. tostring(job))), vim.log.levels.ERROR)
  end
  -- (the buffer of a session that ended, which stayed to be read)
  if S.term and S.term ~= buf and vim.api.nvim_buf_is_valid(S.term) then
    pcall(vim.api.nvim_buf_delete, S.term, { force = true })
  end
  S.term, S.job, S.token, S.cwd, S.heard, S.started = buf, job, token, dir, false, vim.uv.now()
  -- hidden, not unloaded, when another buffer takes the window; and a buffer with 'bufhidden' set is left out
  -- of a stored session (AstroNvim's is_restorable), which would start `claude` anew when it is loaded
  vim.bo[buf].bufhidden = "hide"
  vim.b[buf].claude_code = true
  terminal_keys(buf)
  vim.cmd.startinsert()
  if server == "" then
    note "This Neovim has no address Claude Code could reach it at (:help serverstart): the history stays empty"
  end
end

--- <Leader>AC: Claude Code in the current window, started when it is not running.
function M.open()
  if alive() and vim.api.nvim_buf_is_valid(S.term) then
    local win = M.window()
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_buf(win, S.term)
    vim.cmd.startinsert()
    return
  end
  launch(M.window())
end

--------------------------------------------------------------------------------------------------- the mod

--- What the mod's sender calls (see the top of this file) with a batch: the JSON of
--- `{ token, session, cwd, ops }`. Answers "ok", "stale" (not this launch's: the mod stops sending) or "bad".
--- Never an error: the answer is all the mod has to go by.
function M.receive(text)
  if type(text) ~= "string" or #text > max_batch then return "bad" end
  local decoded, batch = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not decoded or type(batch) ~= "table" or type(batch.ops) ~= "table" then return "bad" end
  if not S.token or batch.token ~= S.token then return "stale" end
  S.heard = true
  -- (not from inside the call: it changes a buffer)
  vim.schedule(function()
    local applied, err = pcall(function() draw(history.apply(S.hist, batch)) end)
    if applied then return end
    pcall(draw) -- (what went in before it failed: the buffer is the history's lines again, all of them)
    if not S.failed then
      S.failed = true -- once: every later batch would say the same
      notify("The chat history could not be written:\n" .. tostring(err), vim.log.levels.ERROR)
    end
  end)
  return "ok"
end

--- For tests/claude_code.lua: the state, as it is.
function M._state() return S end

return M
