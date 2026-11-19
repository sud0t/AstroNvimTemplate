-- Claude Code in a buffer.
--
-- <Leader>AC, when the AI chosen in <Leader>As is Claude through the Claude Code login (lua/user/ai/init.lua,
-- `open_chat`), runs the `claude` terminal program itself as an ordinary buffer in the current window: no
-- split. Pressed again from anywhere it comes back to the session that is running. Claude Code starts in the
-- project of the file you were in (the root AstroNvim finds for it), or in Neovim's directory.
--
-- It is one terminal buffer, used with the keys of every other buffer. The prompt is its insert mode
-- (terminal mode: what you type goes to Claude Code), and what Claude Code has printed above it is text:
--   <Esc>         leaves the prompt, as it leaves insert mode. j k and the other motions then go up into the
--                 conversation, / searches it, v V select and y yanks; `\` is the file tree and <Leader>…
--                 what it is everywhere. i a I A go back to the prompt, and p pastes into it.
--   <C-k>         from the prompt: up, into the conversation (as <Esc>)
--   <C-j>         from the conversation: down, to the prompt (as i)
--   <C-h> <C-l>   the window on that side, as everywhere; so are <C-j> at the prompt and <C-k> above it
--   <Esc>         above the prompt is Claude Code's own Escape: it stops Claude, closes a menu
--   <CR>          above the prompt opens what the cursor is on: a web address in the browser, a file in this
--                 window, at `path:12:3` when it says so (lua/user/ai/claude_links.lua)
--   <S-CR>        a new line in the prompt (so is `\` then <CR>; <C-j> is the window below, see above)
--   <C-x>         leaves the prompt, as in every terminal. Above the prompt it is Claude Code's own Ctrl+X,
--                 with the key after it: its Ctrl+X Ctrl+K is <C-x><C-x><C-k> from the prompt, and you are
--                 at the prompt again (<C-x><Esc>: nothing)
--   <C-z>         nothing: it would stop Claude Code, with no shell here to bring it back
-- Nothing else is mapped here. <Leader>fc, <Leader>x, gx, <Tab> and the rest are the global mappings, and a
-- file opened from the file tree or a picker goes where it goes from any terminal (a split of its own, when
-- this is the only window). Like every terminal the buffer cannot be edited (x, dd, u say so): the prompt
-- is edited at the prompt, or with Claude Code's Ctrl+G in a Neovim of its own, which gets <Esc> while it is
-- open.
--
-- Claude Code runs as `claude` does in the shell (where a function of the same name adds the first of
-- these), with what makes it a buffer:
--   - reads outside the directory it works in are refused
--   - its own vim mode is off: the modes are Neovim's (`editorMode`)
--   - it prints on the terminal's main screen and never takes the whole of it, so the conversation stays in
--     the buffer, above the prompt (CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN; `tui` for its offer to switch).
--     The buffer keeps the last 'scrollback' rows of it.
--   - its caret is the terminal's cursor, not a block it draws: one cursor, where Neovim's is, shaped as in
--     insert mode at the prompt and a block above it (CLAUDE_CODE_NATIVE_CURSOR, and `start`)
--   - a web link is printed as its address, which <CR> and gx can read (FORCE_HYPERLINK)
--   - it uses the login, not a key Neovim may have in $ANTHROPIC_API_KEY (that one is for the CodeCompanion
--     chat, and would be read by every command Claude Code runs); and it is not told where this Neovim
--     listens ($NVIM), with which a command it runs could drive the editor
-- Started in this configuration's own directory or one that holds it (asked first, like the home directory)
-- it can change everything here for the next start of Neovim: as it can any project's files.
--
-- <CR> on a file outside the directory Claude Code was started in asks first, with the file's real path:
-- what is printed need not be what it seems, and opening a file starts what the editor has for its kind (a
-- language server takes its settings, and for some languages programs to run, from the file's project).
--
-- Closing the buffer ends the program, as with every terminal (<Leader>x does not ask). The conversation is
-- kept by Claude Code: /resume in a new session brings it back. When Claude Code exits by itself the buffer
-- stays to be read, until it is closed or <Leader>AC starts the next session. It is not stored in a session
-- (resession).
--
-- tests/claude_code.lua has the tests, and at its top what to check by hand with the real program.
local M = {}

local links = require "user.ai.claude_links"

local settings = '{"permissions":{"blockReadsOutsideWorkingDirectories":true},"editorMode":"normal","tui":"default"}'
local environment = {
  CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN = "1",
  CLAUDE_CODE_NATIVE_CURSOR = "1",
  FORCE_HYPERLINK = "0",
  NVIM = "",
}
-- variables of Neovim's that Claude Code is started without
local not_passed = { "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY", "OPENROUTER_API_KEY" }
-- rows either side of the cursor that <CR> reads: enough for the paragraph the cursor is in, whose rows say
-- where a row ends (claude_links.lua)
local context = 100

-- one session per Neovim
local S = {
  term = nil, -- the terminal buffer
  job = nil, -- its job, while Claude Code runs
  cwd = nil, -- where Claude Code was started
  keys = {}, -- the mappings of the buffer that talk to Claude Code: { mode, lhs }
}

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

----------------------------------------------------------------------------------------------------- <CR>

local function open_address(target, joined)
  -- an address can read as another one, with what the model has read in it; and one put together from two
  -- rows is not what either row shows. The question shows it so that it cannot mislead: see `spelled`
  local why = {}
  if joined then
    why[#why + 1] = "it was put together from the rows it is broken over (gx opens what is on this row alone)"
  end
  why[#why + 1] = target.why
  if #why > 0 then
    local question = ("Open this address? Asked because %s.\nHost: %s\n%s"):format(
      table.concat(why, "; "),
      links.spelled(target.host),
      links.spelled(target.url)
    )
    if vim.fn.confirm(question, "&Yes\n&No", 2) ~= 1 then return end
  end
  local _, err = vim.ui.open(target.url)
  if err then notify(err, vim.log.levels.ERROR) end
end

local function open_file(found)
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

--- Open what the cursor is on (see the top of this file and claude_links.lua).
local function open_target()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local first = math.max(row - context, 1)
  local rows = vim.api.nvim_buf_get_lines(0, first - 1, row + context, false)
  -- where a path that does not start at `/` is looked for: where Claude Code was started, and here
  local dirs = {}
  for _, dir in ipairs { S.cwd or false, vim.fn.getcwd() } do
    if dir and not vim.list_contains(dirs, dir) then dirs[#dirs + 1] = dir end
  end
  local why
  for _, text in ipairs(links.at(rows, row - first + 1, col) or {}) do
    local target = links.classify(text.text)
    if target and target.kind == "url" then return open_address(target, text.joined) end
    if target and target.kind == "path" then
      local found
      found, why = links.resolve(target, dirs, S.cwd)
      if found then return open_file(found) end
    elseif target then
      why = "Not opened: " .. target.what
    end
  end
  notify(why or "Nothing to open under the cursor", why and vim.log.levels.WARN or nil)
end

------------------------------------------------------------------------------------------------- the keys

local function send(keys)
  if alive() then vim.api.nvim_chan_send(S.job, keys) end
end

--- Whether Claude Code has handed the terminal to its editor (Ctrl+G: $VISUAL or $EDITOR, which it starts
--- with the terminal for its input), where the keys taken here for the prompt are the editor's. Read from
--- /proc, as lua/plugins/toggleterm.lua does: Linux only (elsewhere the editor is not seen, and <Esc> in it
--- leaves to normal mode here). An editor that a command of Claude Code's runs is not it: its input is not
--- the terminal.
local function handed_over()
  if not alive() then return false end
  local pid = vim.fn.jobpid(S.job)
  local terminal = vim.uv.fs_readlink(("/proc/%d/fd/0"):format(pid))
  local tasks = terminal and vim.uv.fs_scandir(("/proc/%d/task"):format(pid))
  if not tasks then return false end
  local editors = {}
  for _, name in ipairs { "VISUAL", "EDITOR" } do
    local program = (vim.env[name] or ""):match "%S+"
    if program then editors[vim.fs.basename(program):sub(1, 15)] = true end -- (as much as /proc keeps of a name)
  end
  if next(editors) == nil then editors = { vi = true, nano = true } end -- (what it then looks for)
  for task in function() return vim.uv.fs_scandir_next(tasks) end do
    local list = io.open(("/proc/%d/task/%s/children"):format(pid, task))
    local children = list and list:read "*a" or ""
    if list then list:close() end
    for child in children:gmatch "%d+" do
      local comm = io.open(("/proc/%s/comm"):format(child))
      local name = comm and comm:read "*l"
      if comm then comm:close() end
      if editors[name or ""] and vim.uv.fs_readlink(("/proc/%s/fd/0"):format(child)) == terminal then return true end
    end
  end
  return false
end

--- `key` to the program in the terminal as it was typed, past the mappings.
local function pass(key) vim.api.nvim_feedkeys(vim.keycode(key), "n", false) end

local function keys(buf)
  S.keys = {}
  local function map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, desc = desc, nowait = true })
    S.keys[#S.keys + 1] = { mode, lhs }
  end
  map("t", "<Esc>", function()
    if handed_over() then return pass "<Esc>" end
    vim.cmd.stopinsert()
  end, "Leave the prompt (normal mode)")
  map("t", "<C-k>", function()
    if handed_over() then return vim.cmd.wincmd "k" end -- (what the key is in every terminal)
    vim.cmd.stopinsert()
  end, "Up: from the prompt into the conversation")
  map("n", "<C-j>", function() vim.cmd.startinsert() end, "Down: from the conversation to the prompt")
  map("n", "<Esc>", function() send "\27" end, "Claude Code's Escape (stop, close a menu)")
  -- Ctrl+X starts some of Claude Code's commands (Ctrl+X Ctrl+K). The key after it is read here and both
  -- are typed at the prompt past the mappings: there <C-k> and others are the editor's
  map("n", "<C-x>", function()
    local read, key = pcall(vim.fn.getcharstr)
    if not read or key == "" or key == "\27" or not alive() then return end
    -- (a key with a name starts with the byte that marks one; in a letter that byte is a letter's)
    vim.api.nvim_feedkeys("i\24" .. key, "n", key:byte() ~= 0x80)
  end, "Claude Code's Ctrl+X, and the key after it")
  -- Shift+Enter is a plain Enter (send!) for a program that has not asked for the kitty key encoding;
  -- Ctrl+J is a new line in Claude Code's prompt whatever it asked for
  map("t", "<S-CR>", function()
    if handed_over() then return pass "<S-CR>" end
    send "\n"
  end, "New line in the prompt")
  map("t", "<C-z>", "<Nop>", "Nothing (it would suspend Claude Code)")
  -- (not one of the program's: it stays when Claude Code has exited)
  vim.keymap.set(
    "n",
    "<CR>",
    open_target,
    { buffer = buf, desc = "Open the link or file under the cursor", nowait = true }
  )
end

---------------------------------------------------------------------------------------------- the session

--- Where Claude Code starts: the project of the file in `buf` (the buffer it takes the place of), else
--- Neovim's directory; and where the last session did, when `buf` is what is left of that one. nil when the
--- home directory or this configuration is in there (or it is in this configuration), and you would rather
--- not: Claude Code may read and write all of the directory it is started in.
local function start_dir(buf)
  local dir
  if buf == S.term then
    dir = S.cwd
  elseif vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= "" then
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

--- 'guicursor' with terminal mode's cursor as insert mode's is: what the option says for `t` taken out (it
--- would go on blinking under another shape), and what it says for `i` said for `t` too. nil when it says
--- nothing for insert mode.
local function prompt_cursor()
  local parts, prompt = {}, {}
  for part in vim.o.guicursor:gmatch "[^,]+" do
    local modes, look = part:match "^([^:]+):(.+)$"
    if not modes then return nil end
    modes = vim.split(modes, "-", { plain = true })
    if vim.list_contains(modes, "i") then prompt[#prompt + 1] = "t:" .. look end
    modes = vim.tbl_filter(function(mode) return mode ~= "t" end, modes)
    if #modes > 0 then parts[#parts + 1] = table.concat(modes, "-") .. ":" .. look end
  end
  return #prompt > 0 and table.concat(vim.list_extend(parts, prompt), ",") or nil
end

--- `jobstart` for Claude Code, with the two things that are only said by how Neovim is at that moment. Its
--- environment is Neovim's without the keys of `not_passed`: not set at all, which an empty one may not be
--- the same as to Claude Code. And a terminal is given its cursor when it is made, from 'guicursor', and
--- keeps it (the program can change it; Claude Code does not): this one gets insert mode's, since its
--- prompt is where you type. Both are put back before anything else runs.
local function start(argv, opts)
  local environ, cursor, prompt = vim.fn.environ(), vim.o.guicursor, prompt_cursor()
  for _, name in ipairs(not_passed) do
    vim.fn.setenv(name, vim.NIL)
  end
  local started, job = pcall(function()
    if prompt then vim.o.guicursor = prompt end
    return vim.fn.jobstart(argv, opts)
  end)
  if prompt then vim.o.guicursor = cursor end
  for _, name in ipairs(not_passed) do
    if environ[name] ~= nil then vim.fn.setenv(name, environ[name]) end
  end
  return started, job
end

local function launch(win)
  local exe = vim.fn.exepath "claude"
  if exe == "" then return notify("`claude` is not installed (<Leader>As, Set up provider)", vim.log.levels.ERROR) end
  local before = vim.api.nvim_win_get_buf(win)
  local dir, why = start_dir(before)
  if not dir then return why and notify(why, vim.log.levels.ERROR) end

  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_buf(win, buf)
  -- (the program itself, by its name: the buffer is named after what is started, and listed as `claude`)
  local started, job = start({ exe, "--settings", settings }, {
    term = true,
    cwd = dir,
    env = environment,
    on_exit = function(id, code)
      vim.schedule(function()
        if S.job ~= id then return end
        S.job = nil
        if not vim.api.nvim_buf_is_valid(buf) then return end
        for _, key in ipairs(S.keys) do
          pcall(vim.keymap.del, key[1], key[2], { buffer = buf })
        end
        if vim.api.nvim_get_current_buf() == buf then
          -- (in terminal mode the next key would close the buffer, and what there is to read with it)
          if vim.api.nvim_get_mode().mode == "t" then vim.cmd.stopinsert() end
        elseif #vim.fn.win_findbuf(buf) == 0 then
          notify(("Claude Code exited (code %d)"):format(code))
        end
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
  S.term, S.job, S.cwd = buf, job, dir
  -- hidden, not unloaded, when another buffer takes the window; and a buffer with 'bufhidden' set is left out
  -- of a stored session (AstroNvim's is_restorable), which would start `claude` anew when it is loaded
  vim.bo[buf].bufhidden = "hide"
  vim.b[buf].claude_code = true
  keys(buf)
  vim.cmd.startinsert()
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

--- For tests/claude_code.lua: the state, as it is.
function M._state() return S end

return M
