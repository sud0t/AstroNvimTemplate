-- Tests for Claude Code in a buffer and its chat history: lua/user/ai/claude_code.lua (the two buffers, the
-- keys, what the mod's batches turn into), lua/user/ai/claude_history.lua (the Markdown, what <CR> opens) and
-- `open_chat` in lua/user/ai/init.lua (<Leader>AC: Claude Code or the CodeCompanion chat).
--   nvim --clean -i NONE -l ~/.config/nvim/tests/claude_code.lua
-- prints what failed and exits with 1, or "ok". `claude` is a stand-in that writes down how it was started
-- and the bytes it is sent; the browser, the picker and the questions are stand-ins too.
-- The mod has tests of its own: `claude plugin test ~/.config/nvim/claude-code`.
--
-- What this cannot show is the real program in the terminal buffer, and the mod talking to this Neovim. By
-- hand, with Claude (the Claude Code login) chosen in <Leader>As:
--    1. <Leader>AC in a file of a project: Claude Code fills the window (no split), you can type at once, and
--       it is in the project's root. No question about a plugin or mod comes up.
--    2. Ask it to read ~/.zshrc: refused (reads outside the directory, as `claude` in the shell).
--    3. In its prompt: Esc and i switch between NORMAL and INSERT; <S-CR> and `\` then <CR> make a new line;
--       <C-g> opens the prompt in the editor, and so does <C-x><C-x><C-e>; <C-z> does nothing.
--    4. <C-k> (or any of <C-h/j/k/l> with no window that way): the chat history, with what was said so far.
--       The same key again: back in Claude Code, typing. With a split open, the keys move between the
--       windows as always.
--    5. While Claude works, the history follows: your prompt under "## You", the answer under "## Claude",
--       a line per tool call that gets its tick, a failed one marked. Type a second prompt while it is still
--       working: that one shows up under "## You" as well. (If it does not: `:let g:claude_code_debug = 1`,
--       start a new session, do it again, and the `<!-- row: ... -->` lines say what the prompt came in as.)
--    6. In the history, <CR> on: a file path the answer names (opens it; `path:12` at the line), a link whose
--       text is its address (opens in the browser), a link with other text (asks first, with the address),
--       a file outside the project, /etc/hostname say (asks first, with its path). <C-o> comes back.
--    7. In the history, <Leader>fc on a word: the picker greps Claude Code's directory; <CR> on a result
--       opens it.
--    8. <Leader>AC from another buffer: the same session. :ls shows one terminal.
--    9. /clear: a new "# Claude Code" heading in the history. /resume of an earlier conversation: its
--       messages appear. /compact: a line saying so, what was above stays. /exit: "Claude Code exited";
--       <Leader>AC starts it again.
--   10. <Leader>x on Claude Code asks first. <Leader>x on the history closes it; a window key brings it back,
--       whole.
--   11. Quit Neovim with a session running and start it again with the last session (<Leader>Sl): no `claude`
--       starts by itself, no empty terminal buffer.
--   12. <Leader>As, choose Local (or a provider with a key): <Leader>AC is the CodeCompanion chat, in the
--       window (no split); again, and the buffer you were in is back. <Leader>Ac outside a commit still opens
--       its chat in a split.
--   13. <Leader>AC from a file of this configuration asks before it starts Claude Code here; so it does from
--       ~/.config and from ~.
local uv = vim.uv

local repo = vim.fs.dirname(vim.fs.dirname(assert(uv.fs_realpath(debug.getinfo(1, "S").source:sub(2)))))

local base = assert(uv.fs_realpath(assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/claude-code-test.XXXXXX"))))
vim.env.XDG_CONFIG_HOME = base .. "/config"
vim.env.XDG_DATA_HOME = base .. "/data"
vim.env.XDG_STATE_HOME = base .. "/state"
vim.env.XDG_CACHE_HOME = base .. "/cache"
vim.env.HOME = base .. "/home"
vim.opt.rtp:prepend(repo)
vim.g.mapleader = " "
vim.o.swapfile = false
vim.o.wrap = false

local failures, count = {}, 0
local function ok(name, cond, detail)
  count = count + 1
  if not cond then failures[#failures + 1] = name .. (detail ~= nil and ("\n      " .. tostring(detail)) or "") end
end
local function has(text, piece) return type(text) == "string" and text:find(piece, 1, true) ~= nil end
local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

---------------------------------------------------------------------------------------------------- stand-ins

local project = base .. "/home/proj"
local out = base .. "/out"
for _, dir in ipairs { project .. "/src", out, base .. "/bin", base .. "/state/nvim" } do
  vim.fn.mkdir(dir, "p")
end
local numbered = {}
for i = 1, 20 do
  numbered[i] = ("line %d of main"):format(i)
end
write(project .. "/src/main.rs", numbered)
write(project .. "/notes.md", { "notes" })
local odd = project .. "/we|ird %name #1 `x` $HOME.txt"
write(odd, { "odd" })
vim.fn.system { "mkfifo", project .. "/pipe" }
local outside = base .. "/home/outside.txt"
write(outside, { "not in the project" })
assert(uv.fs_symlink(outside, project .. "/link.txt"))
local two_lines = base .. "/home/two\nlines.txt" -- (a name that would put a line of its own in a question)
write(two_lines, { "nor this" })
assert(uv.fs_symlink(two_lines, project .. "/link2.txt"))

-- `claude`: how it was started, then every byte it is sent
write(base .. "/bin/claude", {
  "#!/bin/sh",
  "{",
  [[  printf 'cwd=%s\n' "$PWD"]],
  [[  for a in "$@"; do printf 'arg=%s\n' "$a"; done]],
  [[  printf 'token=%s\nnvim=%s\nwatch=%s\nserver=%s\nopenai=[%s]\nanthropic=[%s]\n' \]],
  [[    "$NVIM_CLAUDE_TOKEN" "$NVIM_CLAUDE_NVIM" "$CLAUDE_CODE_PLUGIN_DIR_WATCH" "$NVIM" \]],
  [[    "${OPENAI_API_KEY-not set}" "${ANTHROPIC_API_KEY-not set}"]],
  [[} > "$CLAUDE_TEST_OUT/started.$$"]],
  [[mv "$CLAUDE_TEST_OUT/started.$$" "$CLAUDE_TEST_OUT/started"]],
  "stty raw -echo 2>/dev/null",
  [[exec cat > "$CLAUDE_TEST_OUT/keys"]],
})
vim.fn.setfperm(base .. "/bin/claude", "rwxr-xr-x")
vim.env.PATH = base .. "/bin:" .. vim.env.PATH
vim.env.CLAUDE_TEST_OUT = out
vim.env.OPENAI_API_KEY = "sk-not-for-claude-code"
vim.env.ANTHROPIC_API_KEY = "sk-ant-not-for-claude-code"

local notes, asked, answers, opened, grepped = {}, {}, {}, {}, {}
vim.notify = function(msg) notes[#notes + 1] = msg end
vim.fn.confirm = function(question)
  asked[#asked + 1] = question
  return table.remove(answers, 1) or 2 -- No, unless the test says otherwise
end
vim.ui.open = function(what) opened[#opened + 1] = what end
package.loaded["snacks"] = { picker = { grep_word = function(opts) grepped[#grepped + 1] = opts or {} end } }

local function wait_for(cond, ms) return vim.wait(ms or 4000, cond, 20) end
local function started()
  local lines = uv.fs_stat(out .. "/started") and vim.fn.readfile(out .. "/started") or {}
  local info = { args = {} }
  for _, line in ipairs(lines) do
    local key, value = line:match "^(%w+)=(.*)$"
    if key == "arg" then
      info.args[#info.args + 1] = value
    elseif key then
      info[key] = value
    end
  end
  return info
end
local function keys_sent()
  local file = io.open(out .. "/keys", "rb")
  local bytes = file and file:read "*a" or ""
  if file then file:close() end
  return bytes
end
--- Press a key of the buffer: its buffer-local mapping, run as the key would run it.
local function press(mode, lhs)
  local map = vim.fn.maparg(lhs, mode, false, true)
  assert(map.buffer == 1 and map.callback, ("no buffer-local %s mapping of %s"):format(mode, lhs))
  map.callback()
end
local function buffer_text(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") end
local function terminals()
  return vim.tbl_filter(function(buf) return vim.bo[buf].buftype == "terminal" end, vim.api.nvim_list_bufs())
end

local history = require "user.ai.claude_history"

--------------------------------------------------------------------------------------------- the Markdown

do
  local state = history.new()
  local first = {
    session = "s1",
    cwd = "/work/proj",
    ops = {
      { op = "user", id = "u1", text = "hello\nthere", at = 1795000000000 },
      { op = "assistant", id = "a1:0", text = "Hi **there**" },
      { op = "tool", id = "a1:1", tool_id = "t1", name = "Read", input = { file_path = "/work/proj/src/main.rs" } },
      { op = "tool", id = "a1:2", tool_id = "t2", name = "Bash", input = { command = "cargo test\nsecond line" } },
      { op = "result", tool_id = "t1" },
      { op = "result", tool_id = "t2", error = "error[E0433]: failed\nmore" },
      { op = "assistant", id = "a2:0", text = "Done." },
      { op = "notice", id = "n1", text = "Conversation compacted" },
    },
  }
  local edits = history.apply(state, first)
  local text = table.concat(state.lines, "\n")
  ok("a section starts with its heading", state.lines[1]:match "^# Claude Code · %d%d:%d%d · /work/proj$", state.lines[1])
  ok("a prompt has its heading and its lines", has(text, "\n## You · ") and has(text, "\n\nhello\nthere\n"), text)
  ok("an answer has one heading", select(2, text:gsub("## Claude", "")) == 1, text)
  ok("a tool call that was answered is ticked", has(text, "\n- [x] Read `src/main.rs`\n"), text)
  ok(
    "a tool call that failed says so, in one line",
    has(text, "\n- [x] Bash `cargo test` **failed**: error[E0433]: failed\n"),
    text
  )
  ok("text after tool calls is set apart", has(text, "failed\n\nDone.\n\n_Conversation compacted_"), text)
  ok("a first batch is all new lines", edits.first == 1 and next(edits.changed) == nil, vim.inspect(edits))

  local before = #state.lines
  history.apply(state, first)
  ok("a batch that comes again adds nothing", #state.lines == before, #state.lines)

  edits = history.apply(state, {
    session = "s1",
    cwd = "/work/proj",
    ops = {
      { op = "tool", id = "a3:0", tool_id = "t3", name = "mcp__github__list_issues", input = {} },
      { op = "assistant", id = "a3:1", text = "one block" },
      { op = "assistant", id = "a3:2", text = "and the next\nwith a line" },
    },
  })
  text = table.concat(state.lines, "\n")
  ok("new rows go below", edits.first == before + 1, vim.inspect(edits))
  ok("an MCP tool is named by its server", has(text, "- [ ] github: list_issues"), text)
  ok("blocks of text are paragraphs", has(text, "one block\n\nand the next\nwith a line"), text)
  local third = #state.lines
  edits = history.apply(state, { session = "s1", ops = { { op = "result", tool_id = "t3" } } })
  local row
  for i, line in ipairs(state.lines) do
    if has(line, "github: list_issues") then row = i end
  end
  ok(
    "a result for an earlier line rewrites that line only",
    edits.changed[row] and edits.first == third + 1 and state.lines[row] == "- [x] github: list_issues",
    vim.inspect(edits)
  )

  history.apply(state, { session = "s1", cwd = "/work/other", ops = {} })
  ok("another directory is said", has(state.lines[#state.lines], "_Now in /work/other_"), state.lines[#state.lines])

  local kept = #state.lines
  history.apply(state, { session = "s2", cwd = "/work/other", ops = { { op = "user", id = "u1", text = "again" } } })
  text = table.concat(state.lines, "\n")
  ok("another session is a new section below", select(2, text:gsub("# Claude Code · ", "")) == 2 and #state.lines > kept, text)
  ok("and its rows are its own", has(text, "\n\nagain"), text)
  history.apply(state, { session = "s1", cwd = "/work/proj", ops = first.ops })
  text = table.concat(state.lines, "\n")
  ok(
    "a conversation that is resumed is drawn again, tool calls too",
    select(2, text:gsub("%- %[x%] Read `src/main.rs`", "")) == 2,
    text
  )
  history.apply(state, { session = "s2", cwd = "/work/other", ops = {} })

  local same = #state.lines
  for _, junk in ipairs {
    "text",
    {},
    { op = "user" },
    { op = "user", text = 5 },
    { op = "tool", name = "Read" },
    { op = "result", tool_id = "never" },
    { op = "result" },
    { op = "nonsense", text = "x" },
  } do
    local fine, err = pcall(history.apply, state, { session = "s2", ops = { junk } })
    ok("an op that is not one is passed over", fine and #state.lines == same, err or vim.inspect(junk))
  end
  ok("a batch without ops is passed over", pcall(history.apply, state, { session = "s2", ops = 7 }))

  history.apply(state, { session = "s2", ops = { { op = "user", id = "u7", text = "twice", folded = true } } })
  local once = #state.lines
  history.apply(state, { session = "s2", ops = { { op = "user", id = "u8", text = "twice", folded = true } } })
  ok("a prompt typed while Claude worked, which comes in by two rows, is shown once", #state.lines == once)
  history.apply(state, {
    session = "s2",
    ops = {
      { op = "user", id = "u9", text = "go on" },
      { op = "notice", id = "n9", text = "/model opus" },
      { op = "user", id = "u10", text = "go on" },
    },
  })
  ok(
    "a prompt typed twice is two prompts",
    select(2, table.concat(state.lines, "\n"):gsub("\ngo on", "")) == 2,
    table.concat(state.lines, "\n")
  )

  ok(
    "a line is cut by its characters, not its bytes",
    history.describe("Bash", { command = ("日"):rep(45) }) == "Bash `" .. ("日"):rep(45) .. "`"
      and history.describe("Bash", { command = ("日"):rep(120) }) == "Bash `" .. ("日"):rep(100) .. "…`"
  )

  ok("a command with backticks stays one code span", history.describe("Bash", { command = "echo `date`" }) == "Bash `` echo `date` ``")
  ok(
    "a search names its pattern and where",
    history.describe("Grep", { pattern = "parse_args", path = "/p/src" }, "/p") == "Grep `parse_args` in `src`"
  )
  ok("a fetch names its address", history.describe("WebFetch", { url = "https://example.com/a" }) == "WebFetch <https://example.com/a>")
  ok("an address that is not one is left out", history.describe("WebFetch", { url = "https://x/ <y>" }) == "WebFetch")
  ok("input that is not a table is nothing", history.describe("Read", "x") == "Read" and history.describe(nil, nil) == "tool")
end

---------------------------------------------------------------------------------------- what <CR> opens

do
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "markdown"
  local lines = {
    "See [the docs](https://example.com/docs?q=1) and [https://example.com/a](https://example.com/a).",
    "<https://example.org/a>",
    "Run `src/main.rs:12:3` now, or src/main.rs#L7 maybe.",
    "plain https://example.net/x, and   text",
    "[bad](javascript:alert(1)) [f](file:///tmp/a%20b.txt) [v](vscode://file/x)",
    "[spaced](<src/with space.rs>)",
  }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local function at(row, piece)
    local col = assert(lines[row]:find(piece, 1, true), piece) - 1
    return history.target(buf, row - 1, col + 1)
  end

  local target = at(1, "the docs")
  ok(
    "on a link's text: where it leads, and that the text hid it",
    target and target.kind == "url" and target.url == "https://example.com/docs?q=1" and target.hidden == true,
    vim.inspect(target)
  )
  target = at(1, "https://example.com/a]")
  ok("a link whose text is its address hides nothing", target and target.kind == "url" and not target.hidden, vim.inspect(target))
  target = at(2, "example.org")
  ok("an autolink", target and target.url == "https://example.org/a" and not target.hidden, vim.inspect(target))
  target = at(3, "main.rs:12")
  ok(
    "a path in a code span, with line and column",
    target and target.kind == "path" and vim.deep_equal(target.candidates[2], { path = "src/main.rs", line = 12, col = 3 }),
    vim.inspect(target)
  )
  target = at(3, "main.rs#L7")
  ok("a path with #L", target and target.kind == "path" and target.candidates[2].line == 7, vim.inspect(target))
  target = at(4, "example.net")
  ok("a bare address, without the comma after it", target and target.url == "https://example.net/x", vim.inspect(target))
  ok("nothing between words", history.target(buf, 3, (lines[4]:find("and   ", 1, true)) + 3) == nil)
  target = at(5, "bad")
  ok("javascript: is refused", target and target.kind == "refused", vim.inspect(target))
  target = at(5, "[v]")
  ok("another program's links are refused", target and target.kind == "refused", vim.inspect(target))
  target = at(5, "[f]")
  ok(
    "file:// is a path, decoded",
    target and target.kind == "path" and target.candidates[1].path == "/tmp/a b.txt",
    vim.inspect(target)
  )
  target = at(6, "spaced")
  ok("a path in angle brackets", target and target.candidates[1].path == "src/with space.rs", vim.inspect(target))

  ok("an address with a space in it is refused", history.classify("https://example.com/a b").kind == "refused")
  target = history.classify "https://example.com/a"
  ok(
    "an address has its host, and nothing to ask about",
    target.host == "example.com" and target.hidden == false and target.why == nil,
    vim.inspect(target)
  )
  target = history.classify("https://example.com/a", true)
  ok("one a link's text hid is asked about", target.hidden == true and has(target.why, "the link's text"), vim.inspect(target))
  for name, case in pairs {
    ["a name before an @"] = { "https://github.com@collector.example/x", "before an @", "collector.example" },
    ["letters of another alphabet"] = { "https://exаmple.com/x", "not plain ASCII", "exаmple.com" },
    ["their xn-- spelling"] = { "https://xn--exmple-4nf.com/x", "xn--", "xn--exmple-4nf.com" },
    ["a mark that turns the text around"] = { "https://example.com/\226\128\174gpj.exe", "not plain ASCII", "example.com" },
  } do
    target = history.classify(case[1])
    ok(
      "an address that reads as another is asked about, and why: " .. name,
      target.kind == "url" and target.hidden == true and has(target.why, case[2]) and target.host == case[3],
      vim.inspect(target)
    )
  end
  ok(
    "what a question shows cannot pass for something else",
    history.spelled "exаmple.com/\226\128\174x\n" == "ex<U+0430>mple.com/<U+202E>x<U+000A>",
    history.spelled "exаmple.com/\226\128\174x\n"
  )
  ok("text with a control character is nothing", history.classify "src/main.rs\27[0m" == nil)

  local found = history.resolve(history.classify "src/main.rs:12:3", { "/nowhere", project }, project)
  ok(
    "a path is looked for in each directory",
    found and found.path == project .. "/src/main.rs" and found.line == 12 and found.col == 3 and found.inside == true,
    vim.inspect(found)
  )
  found = history.resolve(history.classify(odd), {}, project)
  ok("a name with | % # ` $ in it is the file of that name", found and found.path == odd, vim.inspect(found))
  found = history.resolve(history.classify "~/proj/notes.md", {}, project)
  ok("~ is the home directory", found and found.path == project .. "/notes.md" and found.inside, vim.inspect(found))
  found = history.resolve(history.classify(outside), {}, project)
  ok("a file outside Claude Code's directory is said to be", found and found.path == outside and found.inside == false, vim.inspect(found))
  found = history.resolve(history.classify "../outside.txt", { project }, project)
  ok("also by a path that climbs out of it", found and found.path == outside and found.inside == false, vim.inspect(found))
  found = history.resolve(history.classify "link.txt", { project }, project)
  ok("and by a link in it that leads out: the file itself", found and found.path == outside and found.inside == false, vim.inspect(found))
  found = history.resolve(history.classify "src/main.rs", { project }, "/")
  ok("nothing is inside when Claude Code was started in /", found and found.inside == false, vim.inspect(found))
  found = history.resolve(history.classify "src/main.rs", { project }, nil)
  ok("nor when it was not started", found and found.inside == false, vim.inspect(found))
  local why
  found, why = history.resolve(history.classify "$HOME/proj/notes.md", { project }, project)
  ok("a variable is not expanded", not found and has(why, "No file"), vim.inspect(found))
  found, why = history.resolve(history.classify "pipe", { project }, project)
  ok("a pipe is not a file to open", not found and has(why, "No file"), why)
  found, why = history.resolve(history.classify "src", { project }, project)
  ok("a directory is said to be one", not found and has(why, "is a directory"), why)
  found = history.resolve(history.classify "/dev/zero", {}, project)
  ok("a device is not a file to open", not found)
  if uv.fs_stat "/proc/self/environ" then
    found, why = history.resolve(history.classify "/proc/self/environ", {}, "/proc")
    ok("nor what the kernel shows as a file", not found and has(why, "not a file on a disk"), why or vim.inspect(found))
  end
end

----------------------------------------------------------------------------------------- the two buffers

local cc = require "user.ai.claude_code"
local S = cc._state()

vim.cmd.cd(project)
vim.cmd.edit(project .. "/notes.md")
local file_buf = vim.api.nvim_get_current_buf()
local windows = #vim.api.nvim_list_wins()

cc.open()
ok("Claude Code starts", wait_for(function() return uv.fs_stat(out .. "/started") ~= nil end), table.concat(notes, "\n"))
local term = vim.api.nvim_get_current_buf()
local info = started()
ok("in the window, without a split", #vim.api.nvim_list_wins() == windows and vim.bo[term].buftype == "terminal")
ok("a listed buffer that is hidden, not unloaded, when left", vim.bo[term].buflisted and vim.bo[term].bufhidden == "hide")
ok("it starts in Neovim's directory when the file has no project root", info.cwd == project, info.cwd)
ok(
  "with the settings `claude` has in the shell",
  info.args[1] == "--settings" and has(info.args[2], '"blockReadsOutsideWorkingDirectories":true'),
  vim.inspect(info.args)
)
ok(
  "and the mod of this configuration",
  info.args[#info.args - 1] == "--plugin-dir" and info.args[#info.args] == vim.fn.stdpath "config" .. "/claude-code",
  vim.inspect(info.args)
)
ok("the launch has a token", info.token ~= nil and info.token:match "^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$" and info.token == S.token, info.token)
ok("the mod is told which nvim to call", info.nvim == vim.v.progpath, info.nvim)
ok("and where this Neovim listens", info.server == vim.v.servername, info.server)
if vim.v.servername == "" then
  -- (where no socket can be made, as in a sandbox)
  ok("a Neovim that cannot be reached says so in the history", has(table.concat(S.hist.lines, "\n"), "has no address"))
end
ok("the mod is not reloaded while the session runs", info.watch == "0", info.watch)
ok("another provider's key does not reach Claude Code: it is not set at all", info.openai == "[not set]", info.openai)
ok("nor a key for Claude: this is the login", info.anthropic == "[not set]", info.anthropic)

local job = S.job
vim.api.nvim_win_set_buf(0, file_buf)
cc.open()
ok("<Leader>AC again is the same session", S.job == job and vim.api.nvim_get_current_buf() == term and #terminals() == 1)

-- keys
press("t", "<S-CR>")
ok("<S-CR> is a new line for Claude Code", wait_for(function() return keys_sent() == "\n" end), vim.inspect(keys_sent()))
press("n", "<C-X>")
ok("<C-x> from normal mode sends Ctrl+X", wait_for(function() return keys_sent() == "\n\24" end), vim.inspect(keys_sent()))
ok("<C-z> is taken", vim.fn.maparg("<C-Z>", "t", false, true).buffer == 1)

press("t", "<C-K>")
local hist = vim.api.nvim_get_current_buf()
ok(
  "a window key with no window that way is the history",
  vim.api.nvim_buf_get_name(hist) == "claude-code://history" and #vim.api.nvim_list_wins() == windows,
  vim.api.nvim_buf_get_name(hist)
)
ok(
  "which is Markdown that cannot be typed in and is not a file",
  vim.bo[hist].filetype == "markdown" and not vim.bo[hist].modifiable and vim.bo[hist].buftype == "nofile"
)
ok("and wraps", vim.wo.wrap and vim.wo.linebreak)
press("n", "<C-J>")
ok("the same again is Claude Code", vim.api.nvim_get_current_buf() == term)
ok("where long lines are as they were", not vim.wo.wrap)

-- with smart-splits, as in the configuration: at the edge it goes around to the far window by itself
local moved = {}
local splits = {}
for dir, name in pairs { h = "left", j = "down", k = "up", l = "right" } do
  splits["move_cursor_" .. name] = function()
    moved[#moved + 1] = name
    if vim.fn.winnr(dir) == vim.fn.winnr() then
      vim.cmd.wincmd(({ h = "l", l = "h", j = "k", k = "j" })[dir] .. "999")
      vim.cmd(("999wincmd %s"):format(({ h = "l", l = "h", j = "k", k = "j" })[dir]))
    else
      vim.cmd.wincmd(dir)
    end
  end
end
package.loaded["smart-splits"] = splits
vim.cmd "leftabove vsplit"
vim.api.nvim_win_set_buf(0, file_buf)
local left = vim.api.nvim_get_current_win()
vim.cmd.wincmd "l"
local right = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(right, term)
press("n", "<C-H>")
ok(
  "with a window that way the key goes there, as everywhere",
  vim.api.nvim_get_current_win() == left and vim.api.nvim_win_get_buf(right) == term and moved[1] == "left",
  vim.inspect(moved)
)
vim.api.nvim_set_current_win(right)
press("n", "<C-L>")
ok(
  "and with none, to the history: not around to the far window",
  vim.api.nvim_get_current_win() == right and vim.api.nvim_get_current_buf() == hist and #moved == 1,
  vim.inspect(moved)
)
press("n", "<C-L>")
ok("and back", vim.api.nvim_get_current_win() == right and vim.api.nvim_get_current_buf() == term and #moved == 1)
press("t", "<C-H>")
ok("from terminal mode too", vim.api.nvim_get_current_win() == left and vim.api.nvim_win_get_buf(right) == term)
vim.api.nvim_set_current_win(right)
press("n", "<C-K>")
press("n", "q")
ok("q in the history is Claude Code", vim.api.nvim_get_current_buf() == term)
package.loaded["smart-splits"] = nil

-- the window the chat takes
vim.api.nvim_set_current_win(left)
vim.wo[left].winfixbuf = true
ok("a window that keeps its buffer is not taken: the one the cursor came from", cc.window() == right)
vim.api.nvim_win_close(right, true)
local made = cc.window()
ok(
  "and with no other, a new one",
  made ~= left and #vim.api.nvim_list_wins() == windows + 1 and not vim.wo[made].winfixbuf,
  #vim.api.nvim_list_wins()
)
vim.api.nvim_set_current_win(made)
cc.open()
ok("where Claude Code then is", vim.api.nvim_get_current_win() == made and vim.api.nvim_get_current_buf() == term)
vim.wo[left].winfixbuf = false
vim.api.nvim_win_close(left, true)
ok("one window again", #vim.api.nvim_list_wins() == windows, #vim.api.nvim_list_wins())

-- batches
local function batch(ops, over)
  return vim.json.encode(vim.tbl_extend("force", {
    v = 1,
    token = S.token,
    session = "s1",
    cwd = project,
    ops = #ops > 0 and ops or vim.empty_dict(),
  }, over or {}))
end
-- (a history that is still empty after a while says so when it is looked at)
notes = {}
S.started = S.started - 30000
press("n", "<C-K>")
ok("a history with no word from the mod says so", has(notes[1], "Nothing from Claude Code's history mod"), vim.inspect(notes))
press("n", "q")
press("n", "<C-K>") -- in the history, on its last line
local reply = cc.receive(batch {
  { op = "user", id = "u1", text = "où est src/main.rs:12:3 ? 日本語" },
  { op = "assistant", id = "a1:0", text = "See [the docs](https://example.com/docs) or <https://example.org/a>." },
  { op = "tool", id = "a1:1", tool_id = "t1", name = "Read", input = { file_path = project .. "/src/main.rs" } },
})
vim.wait(100)
local text = buffer_text(hist)
ok("a batch is taken", reply == "ok", reply)
ok("and is in the history, other alphabets too", has(text, "où est src/main.rs:12:3 ? 日本語") and has(text, "- [ ] Read `src/main.rs`"), text)
ok("which stays read-only", not vim.bo[hist].modifiable)
ok(
  "the window on the last line follows",
  vim.api.nvim_win_get_cursor(0)[1] == vim.api.nvim_buf_line_count(hist),
  vim.inspect(vim.api.nvim_win_get_cursor(0))
)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
cc.receive(batch { { op = "result", tool_id = "t1" }, { op = "assistant", id = "a2:0", text = "Done." } })
vim.wait(100)
text = buffer_text(hist)
ok("a result ticks its line", has(text, "- [x] Read `src/main.rs`") and has(text, "Done."), text)
ok("a window that was scrolled back stays there", vim.api.nvim_win_get_cursor(0)[1] == 1)

ok("a batch of another launch is refused", cc.receive(batch({}, { token = "0000000000000000" })) == "stale")
ok("what is not a batch is refused", cc.receive "not JSON at all" == "bad" and cc.receive "[1,2" == "bad" and cc.receive(5) == "bad")
ok("nor a batch without ops", cc.receive(vim.json.encode { token = S.token }) == "bad")
local big = ("é"):rep(40000)
ok("a large batch is taken", cc.receive(batch { { op = "assistant", id = "big", text = big } }) == "ok")
vim.wait(100)
ok("whole", has(buffer_text(hist), big))

-- what a batch may hold that it should not
local function in_step()
  return not vim.bo[hist].modifiable and vim.deep_equal(vim.api.nvim_buf_get_lines(hist, 0, -1, false), S.hist.lines)
end
reply = cc.receive(batch({ { op = "assistant", id = "nl", text = "in the odd directory" } }, { cwd = project .. "/a\nb" }))
vim.wait(100)
ok(
  "a directory with a line break in its name is one line of the history",
  reply == "ok" and in_step() and has(buffer_text(hist), "/proj/a b_") and has(buffer_text(hist), "in the odd directory"),
  buffer_text(hist):sub(-200)
)
vim.cmd("bdelete! " .. hist)
press("n", "<C-K>")
ok(
  "which can still be closed and brought back",
  vim.api.nvim_buf_get_name(0) == "claude-code://history" and has(buffer_text(0), "in the odd directory"),
  vim.api.nvim_buf_get_name(0)
)
hist = vim.api.nvim_get_current_buf()
cc.receive(batch({}, { cwd = project }))
vim.wait(100)
local lines_before = #S.hist.lines
reply = cc.receive(batch { { op = "user", id = "when", text = "a prompt from no time at all", at = 1e300 } })
vim.wait(100)
ok(
  "a time that is none is left out, and the prompt is there",
  reply == "ok" and in_step() and #S.hist.lines == lines_before + 4 and S.hist.lines[lines_before + 2] == "## You",
  vim.inspect(vim.list_slice(S.hist.lines, lines_before + 1))
)
lines_before = #S.hist.lines
reply = cc.receive(vim.json.encode {
  v = 1,
  token = S.token,
  session = "s1",
  cwd = { "not", "a", "directory" },
  ops = {
    5,
    "text",
    { op = "user", id = { 1 }, text = 5, at = "noon" },
    { op = "assistant", id = 7, text = { "a table" } },
    { op = "tool", id = "x", tool_id = 9, name = { 1 }, input = "none" },
    { op = "tool", id = "odd-tool", tool_id = "odd", name = 5, input = { command = { 1 }, file_path = 3 } },
    { op = "result", tool_id = { 1 }, error = { 1 } },
    { op = "result", tool_id = "odd", error = 5 },
    { op = { 1 }, id = "y", text = "z" },
    vim.NIL,
    { op = "assistant", id = "after-null", text = "after an op that is null" },
  },
})
vim.wait(100)
ok(
  "fields of the wrong kind are passed over: only what can be drawn is",
  reply == "ok"
    and in_step()
    and vim.deep_equal(vim.list_slice(S.hist.lines, lines_before + 1, lines_before + 4), { "", "## Claude", "", "- [x] tool" }),
  vim.inspect(reply) .. " " .. vim.inspect(vim.list_slice(S.hist.lines, lines_before + 1))
)
ok("ops that are not a list are no batch", cc.receive(vim.json.encode { token = S.token, ops = "all of them" }) == "bad")

-- the same, the way the mod sends it: another nvim, with the mod's own code and the batch on standard input
do
  -- (the code and the arguments are those of claude-code/hooks/register.ts: `SEND` and `send`)
  local source = table.concat(vim.fn.readfile(repo .. "/claude-code/hooks/register.ts"), "\n")
  local code = {}
  for line in vim.gsplit(source:match "const SEND = `\n(.-)\n`" or "", "\n", { plain = true }) do
    code[#code + 1] = vim.trim(line)
  end
  code = table.concat(code, " ")
  ok("the mod's code for it is found", #code > 500 and not code:find "[\\`]", code:sub(1, 80))
  local function hand(input, where, env)
    local done
    vim.system(
      { vim.v.progpath, "-u", "NONE", "-i", "NONE", "--headless", "-c", "lua " .. code, "-c", "cquit 1" },
      { cwd = "/", env = vim.tbl_extend("force", { NVIM_LOG_FILE = "/dev/null", NVIM = where }, env or {}), stdin = input },
      function(res) done = res end
    )
    wait_for(function() return done ~= nil end, 12000)
    return done or { code = -1, stdout = "", stderr = "no answer" }
  end

  local started_server, address = pcall(vim.fn.serverstart, base .. "/nvim.sock")
  if not started_server or address == "" then
    started_server, address = pcall(vim.fn.serverstart, "127.0.0.1:0") -- (where no socket can be made)
  end
  if started_server and address ~= "" then
    local done = hand(batch { { op = "assistant", id = "rpc", text = "over the socket" } }, address)
    vim.wait(100)
    ok("the mod's call answers ok", done.code == 0 and done.stdout == "ok", vim.inspect(done))
    ok("and its batch is in the history", has(buffer_text(hist), "over the socket"))
    done = hand(batch { { op = "assistant", id = "rpc-long", text = ("long 日本 "):rep(100000) .. "the end of it" } }, address)
    vim.wait(200)
    ok("a long batch goes through in one", done.code == 0 and done.stdout == "ok", vim.inspect(done):sub(1, 300))
    ok("whole", has(buffer_text(hist), "long 日本 the end of it"))
    done = hand(batch({}, { token = "0000000000000000" }), address)
    ok("another launch's is answered stale", done.code == 0 and done.stdout == "stale", vim.inspect(done))
    done = hand("not a batch", address)
    ok("what is not a batch is answered bad", done.code == 0 and done.stdout == "bad", vim.inspect(done))
  else
    print "(no server could be started here: the mod's call was not tried against this Neovim)"
  end
  local done = hand(batch {}, "collector.example:6666")
  ok(
    "nothing is sent to what is not a Neovim of this machine",
    done.code == 1 and done.stdout == "" and has(done.stderr, "not where a Neovim of this machine listens"),
    vim.inspect(done)
  )
  done = hand(batch {}, base .. "/no-such.sock")
  ok("a Neovim that is gone is a failure, said on standard error", done.code == 1 and done.stdout == "" and done.stderr ~= "", vim.inspect(done))

  -- what answers there is not Neovim: it asks the caller to run code, then says "ok"
  local trap = uv.new_tcp()
  local bound = pcall(function() assert(trap:bind("127.0.0.1", 0)) end)
  if bound then
    local marker = out .. "/ran-in-the-sender"
    local asks = vim.mpack.encode { 0, 7, "nvim_exec_lua", { ("io.open(%q, 'w'):close() return 1"):format(marker), {} } }
    local answers_ok = vim.mpack.encode { 1, 1, vim.NIL, "ok" }
    local served = 0
    trap:listen(8, function()
      local peer = uv.new_tcp()
      trap:accept(peer)
      served = served + 1
      peer:read_start(function() end)
      peer:write(asks)
      local later = uv.new_timer()
      later:start(200, 0, function()
        peer:write(answers_ok)
        later:close()
      end)
    end)
    done = hand(batch {}, "127.0.0.1:" .. trap:getsockname().port)
    vim.wait(400)
    ok(
      "what answers in Neovim's place cannot have the caller run anything, nor pass for Neovim",
      served == 1 and done.code == 1 and done.stdout == "" and not uv.fs_stat(marker),
      vim.inspect(done)
    )
    trap:close()
  else
    print "(no port could be listened on here: the answer of something that is not Neovim was not tried)"
  end
end

-- <CR>
local function cursor_on(piece)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(hist, 0, -1, false)) do
    local col = line:find(piece, 1, true)
    if col then return vim.api.nvim_win_set_cursor(0, { row, col }) end
  end
  error("not in the history: " .. piece)
end
cursor_on "src/main.rs:12:3"
press("n", "<CR>")
ok(
  "<CR> on a path opens the file at the line and column",
  vim.api.nvim_buf_get_name(0) == project .. "/src/main.rs" and vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 12, 2 }),
  vim.api.nvim_buf_get_name(0) .. " " .. vim.inspect(vim.api.nvim_win_get_cursor(0))
)
ok("in the same window, which no longer wraps", #vim.api.nvim_list_wins() == windows and not vim.wo.wrap)
vim.api.nvim_win_set_buf(0, hist)

cursor_on "the docs"
press("n", "<CR>")
ok("<CR> on a link with other text asks, with the address", #asked == 1 and has(asked[1], "https://example.com/docs"), vim.inspect(asked))
ok("and No opens nothing", #opened == 0)
answers = { 1 }
press("n", "<CR>")
ok("Yes opens it", opened[1] == "https://example.com/docs", vim.inspect(opened))
cursor_on "example.org"
press("n", "<CR>")
ok("<CR> on an address that shows itself opens it unasked", #asked == 2 and opened[2] == "https://example.org/a", vim.inspect(opened))

cc.receive(batch {
  {
    op = "assistant",
    id = "a4:0",
    text = "elsewhere: [src/main.rs](" .. outside .. ") and <https://github.com@collector.example/x>"
      .. " and <https://exаmple.com/x> and `link2.txt`",
  },
})
vim.wait(100)
asked, answers, opened = {}, {}, {}
cursor_on "[src/main.rs]("
press("n", "<CR>")
ok(
  "<CR> on a file outside Claude Code's directory asks, with the file's own path",
  #asked == 1 and has(asked[1], outside) and vim.api.nvim_get_current_buf() == hist,
  vim.inspect(asked)
)
answers = { 1 }
press("n", "<CR>")
ok("and Yes opens it", vim.api.nvim_buf_get_name(0) == outside, vim.api.nvim_buf_get_name(0))
vim.api.nvim_win_set_buf(0, hist)
asked, answers = {}, {}
cursor_on "collector.example"
press("n", "<CR>")
ok(
  "<CR> on an address that reads as another asks, with why and the host it leads to",
  #asked == 1 and has(asked[1], "before an @") and has(asked[1], "Host: collector.example\n") and #opened == 0,
  vim.inspect(asked)
)
asked, answers = {}, {}
cursor_on "mple.com/x"
press("n", "<CR>")
ok(
  "letters of another alphabet are spelled out in the question",
  #asked == 1 and has(asked[1], "Host: ex<U+0430>mple.com\n") and not has(asked[1], "exаmple") and #opened == 0,
  vim.inspect(asked)
)
asked, answers = {}, {}
cursor_on "link2.txt"
press("n", "<CR>")
ok(
  "a file's name does not put lines of its own in the question",
  #asked == 1 and has(asked[1], "/home/two") and not has(asked[1], "two\nlines") and vim.api.nvim_get_current_buf() == hist,
  vim.inspect(asked)
)
asked, answers = {}, {}

cc.receive(batch {
  { op = "assistant", id = "a3:0", text = "odd: `` " .. odd .. " `` pipe: `pipe` gone: `no/such.txt`" },
})
vim.wait(100)
cursor_on "we|ird"
press("n", "<CR>")
ok("a file with | % # ` $ in its name opens as that file", vim.api.nvim_buf_get_name(0) == odd, vim.api.nvim_buf_get_name(0))
vim.api.nvim_win_set_buf(0, hist)
notes = {}
cursor_on "`pipe`"
press("n", "<CR>")
ok("a pipe is not opened", vim.api.nvim_get_current_buf() == hist and has(notes[1], "No file"), vim.inspect(notes))
cursor_on "no/such"
press("n", "<CR>")
ok("nor a file that is not there", vim.api.nvim_get_current_buf() == hist and has(notes[2], "No file: no/such.txt"), vim.inspect(notes))

cursor_on "Done"
press("n", "<Space>fc")
ok("<Leader>fc greps Claude Code's directory", grepped[1] and grepped[1].cwd == project, vim.inspect(grepped))

-- closed and brought back
vim.api.nvim_win_set_buf(0, term)
vim.cmd("bdelete! " .. hist) -- as <Leader>x closes it
press("n", "<C-K>")
local again = vim.api.nvim_get_current_buf()
ok(
  "a history that was closed comes back whole",
  vim.api.nvim_buf_get_name(again) == "claude-code://history" and has(buffer_text(again), "Done.") and has(buffer_text(again), "odd: "),
  buffer_text(again)
)
hist = again
press("n", "<C-J>")

-- the session ends
asked, answers = {}, {}
press("n", "<Space>x")
ok("<Leader>x on Claude Code asks, and No leaves it running", #asked == 1 and S.job == job and vim.api.nvim_buf_is_valid(term), vim.inspect(asked))
answers = { 1 }
press("n", "<Space>x")
ok("and Yes ends it", wait_for(function() return S.job == nil end) and not vim.api.nvim_buf_is_valid(term))
ok("and said in the history", has(buffer_text(hist), "_Claude Code exited"), buffer_text(hist))
local old_token = S.token
uv.fs_unlink(out .. "/started")
vim.api.nvim_win_set_buf(0, file_buf)
cc.open()
ok("<Leader>AC then starts it again", wait_for(function() return uv.fs_stat(out .. "/started") ~= nil end) and S.job ~= job)
ok("as a new launch", S.token ~= old_token and cc.receive(batch({}, { token = old_token })) == "stale")
ok("with one terminal buffer", #terminals() == 1, #terminals())

-- the home directory
vim.fn.jobstop(S.job)
wait_for(function() return S.job == nil end)
vim.api.nvim_win_set_buf(0, file_buf)
vim.cmd.cd(vim.env.HOME)
vim.cmd.enew()
asked, answers = {}, {}
uv.fs_unlink(out .. "/started")
cc.open()
vim.wait(300)
ok("in the home directory it asks first, and No starts nothing", #asked == 1 and has(asked[1], "~") and S.job == nil and not uv.fs_stat(out .. "/started"), vim.inspect(asked))
answers = { 1 }
cc.open()
ok("Yes starts it there", wait_for(function() return uv.fs_stat(out .. "/started") ~= nil end) and started().cwd == vim.env.HOME, started().cwd)
vim.fn.jobstop(S.job)
wait_for(function() return S.job == nil end)

-- this configuration
local config = vim.fn.stdpath "config"
write(config .. "/lua/plugins/x.lua", { "return {}" })
vim.cmd.cd(project)
vim.cmd.edit(config .. "/lua/plugins/x.lua")
vim.cmd.cd(config)
asked, answers = {}, {}
uv.fs_unlink(out .. "/started")
cc.open()
vim.wait(300)
ok(
  "in this configuration it asks first, and No starts nothing",
  #asked == 1 and has(asked[1], "configuration") and S.job == nil and not uv.fs_stat(out .. "/started"),
  vim.inspect(asked)
)
for name, case in pairs {
  ["a directory this configuration is in"] = { vim.fs.dirname(config), "configuration" },
  ["a directory the home directory is in"] = { base, "everything in there" },
} do
  vim.cmd.enew()
  vim.cmd.cd(case[1])
  asked, answers = {}, {}
  cc.open()
  vim.wait(300)
  ok(
    "it asks first too in " .. name,
    #asked == 1 and has(asked[1], case[2]) and S.job == nil and not uv.fs_stat(out .. "/started"),
    vim.inspect(asked)
  )
end
vim.cmd.cd(project)
vim.cmd.edit(project .. "/notes.md")

------------------------------------------------------------------------------------------- <Leader>AC

do
  local state_file = vim.fn.stdpath "state" .. "/ai_provider.json"
  -- CodeCompanion, as much of it as `open_chat` uses
  local chat_buf = vim.api.nvim_create_buf(false, true)
  local chat, made, hidden = nil, {}, {}
  local ui = {}
  function ui:show_in_win(opts)
    self.window_opts = opts.window_opts
    vim.api.nvim_win_set_buf(opts.winnr, chat_buf)
  end
  function ui:hide(opts) hidden[#hidden + 1] = opts or {} end
  package.loaded["codecompanion"] = {
    last_chat = function() return chat end,
    chat = function(args)
      made[#made + 1] = args
      ui.window_opts = args.window_opts
      chat = { bufnr = chat_buf, ui = ui }
      vim.api.nvim_set_current_buf(chat_buf)
    end,
  }
  package.loaded["codecompanion.config"] = { display = { chat = { window = { layout = "vertical" } } } }
  package.loaded["codecompanion.utils.context"] = { get = function(buf) return { bufnr = buf } end }

  local opens = 0
  local function chosen(saved)
    for name in pairs(package.loaded) do
      if name:find "^user%.ai" and name ~= "user.ai.claude_code" and name ~= "user.ai.claude_history" then
        package.loaded[name] = nil
      end
    end
    write(state_file, { vim.json.encode(saved) })
    opens = 0
    local real = cc.open
    cc.open = function() opens = opens + 1 end
    local fine, err = pcall(function() require("user.ai").open_chat() end)
    cc.open = real
    return fine, err
  end
  local file = vim.api.nvim_get_current_buf()
  local count_before = #vim.api.nvim_list_wins()
  local fine, err = chosen { provider = "claude", route = "login" }
  ok("with Claude through the login chosen, <Leader>AC is Claude Code", fine and opens == 1 and #made == 0, err)
  fine, err = chosen { provider = "claude", route = "api" }
  ok(
    "with Claude by API key, the CodeCompanion chat: in the window, as a buffer",
    fine
      and opens == 0
      and #made == 1
      and made[1].window_opts.layout == "buffer"
      and vim.api.nvim_get_current_buf() == chat_buf
      and #vim.api.nvim_list_wins() == count_before,
    err or vim.inspect(made)
  )
  fine, err = chosen { provider = "ollama" }
  ok(
    "again, and the buffer that was there is back",
    fine and #made == 1 and vim.api.nvim_get_current_buf() == file and hidden[1] and hidden[1].keep_window == true,
    err or vim.inspect(hidden)
  )
  fine, err = chosen { provider = "ollama" }
  ok(
    "with the local model, the same chat again, told which buffer it took the place of",
    fine and #made == 1 and vim.api.nvim_get_current_buf() == chat_buf and chat.buffer_context.bufnr == file,
    err or vim.inspect(chat)
  )

  -- the chat in one window, the cursor in another: go there, and leave this window alone
  vim.cmd "rightbelow vsplit"
  local other = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(other, file)
  local chat_win = vim.fn.win_getid(vim.fn.winnr "h")
  fine, err = chosen { provider = "ollama" }
  ok(
    "a chat that is in another window is gone to, not hidden",
    fine and vim.api.nvim_get_current_win() == chat_win and vim.api.nvim_win_get_buf(other) == file and #hidden == 1,
    err or vim.inspect(hidden)
  )
  vim.api.nvim_win_close(other, true)

  -- shown over a buffer that is gone when it is hidden again
  fine, err = chosen { provider = "ollama" } -- (hide)
  local gone = vim.api.nvim_create_buf(false, true)
  vim.bo[gone].bufhidden = "wipe"
  vim.api.nvim_win_set_buf(0, gone)
  fine, err = chosen { provider = "ollama" } -- (show, over `gone`, which is wiped by it: no buffer before this one)
  fine, err = chosen { provider = "ollama" } -- (hide)
  ok(
    "hidden with no buffer to go back to, the window has an empty one",
    fine
      and not vim.api.nvim_buf_is_valid(gone)
      and vim.api.nvim_get_current_buf() ~= chat_buf
      and vim.api.nvim_get_current_buf() ~= file
      and vim.api.nvim_buf_get_name(0) == "",
    err
      or vim.inspect {
        now = vim.api.nvim_get_current_buf(),
        chat = chat_buf,
        file = file,
        gone = vim.api.nvim_buf_is_valid(gone),
        hidden = #hidden,
      }
  )

  -- a chat with a window of its own (the commit message's): hiding it is CodeCompanion's
  ui.window_opts = nil
  vim.api.nvim_win_set_buf(0, chat_buf)
  hidden = {}
  fine, err = chosen { provider = "ollama" }
  ok("a chat in a split of its own is hidden as CodeCompanion does it", fine and #hidden == 1 and hidden[1].keep_window == nil, err or vim.inspect(hidden))
end

---------------------------------------------------------------------------------------------------- result

vim.fn.delete(base, "rf")
if #failures > 0 then
  print(("%d of %d checks failed:"):format(#failures, count))
  for _, failure in ipairs(failures) do
    print("  - " .. failure)
  end
  os.exit(1)
end
print(("ok: %d checks"):format(count))
