-- Tests for Claude Code in a buffer: lua/user/ai/claude_code.lua (how it is started, the keys of its buffer,
-- what happens when it ends), lua/user/ai/claude_links.lua (what <CR> opens) and `open_chat` in
-- lua/user/ai/init.lua (<Leader>AC: Claude Code or the CodeCompanion chat).
--   nvim --clean -i NONE -l ~/.config/nvim/tests/claude_code.lua
-- prints what failed and exits with 1, or "ok". `claude` is a stand-in that writes down how it was started
-- and the bytes it is sent; the browser and the questions are stand-ins too.
--
-- What this cannot show is the real program, and the modes and the cursor of a terminal that is typed in. By
-- hand, with Claude (the Claude Code login) chosen in <Leader>As:
--    1. <Leader>AC in a file of a project: Claude Code fills the window (no split), you can type at once, it
--       is in the project's root, and its tab says `claude`. The cursor at the prompt is the bar of insert
--       mode, and it is the only one: no block beside it.
--    2. Ask it to read ~/.zshrc: refused (reads outside the directory, as `claude` in the shell).
--    3. <Esc>: normal mode, the statusline in its colour, the cursor a block where the caret was. k goes up
--       out of the prompt into the conversation, <C-u> and <C-d> scroll it; v and k select upwards and y
--       yanks; / searches. i is the prompt again, and nothing in the window has moved.
--    4. While Claude works, <Esc> <Esc> stops it (the first leaves the prompt, the second is Claude Code's).
--       In one of its menus the arrows, <C-j> <C-k>, j k and <CR> choose, as long as you are at the prompt.
--    5. `\`: the file tree, and Claude Code draws itself again in the narrower window; `\` once more. Then gg
--       and scroll down: is the conversation there once, or are parts of it repeated? The same question
--       after /compact, and after Ctrl+O twice.
--    6. With Claude Code in the only window, <CR> on a file in the file tree: it opens in a split beside it.
--    7. Above the prompt, <CR> on: a file path Claude named (opens it; `path:12` at the line), a web address
--       (opens in the browser), an address that is broken over two rows (asks first, with all of it), a file
--       outside the project, /etc/hostname say (asks first). <C-o> comes back. And a Markdown link in an
--       answer: is its address printed, to press <CR> on?
--    8. <Leader>fc on a word of the conversation: the picker greps for it; <CR> on a result opens it.
--    9. At the prompt, <S-CR> and `\` then <CR> make a new line. <C-g> opens the prompt in Neovim: <Esc> and
--       :wq work in it, and its text is in the prompt afterwards. <C-x> <C-x> <C-e> opens it too (Claude
--       Code's Ctrl+X Ctrl+E). <C-z> does nothing.
--   10. <Leader>AC from another buffer: the same session. :ls shows one terminal.
--   11. /exit: the buffer stays, in normal mode, with "[Process exited 0]" at its end; <Leader>AC starts the
--       next session, in the same directory. <Leader>x on a running session closes it at once, and /resume
--       in a new one brings the conversation back.
--   12. Quit Neovim with a session running and start it again with the last session (<Leader>Sl): no `claude`
--       starts by itself, no empty terminal buffer.
--   13. <Leader>As, choose Local (or a provider with a key): <Leader>AC is the CodeCompanion chat, in the
--       window (no split); again, and the buffer you were in is back. <Leader>Ac outside a commit still opens
--       its chat in a split.
--   14. <Leader>AC from a file of this configuration asks before it starts Claude Code here; so it does from
--       ~/.config and from ~.
--   15. The prompt is on the last rows of the window: in a new session, with nothing said yet; after `/` and
--       <Esc> (a menu opens and closes); after /clear; and while the first answers come in, without the
--       window jumping. With a long conversation, a menu that closes leaves empty rows at the top of the
--       window, not under the prompt.
--   16. At the prompt <C-h> and <C-l> move in the line. In a prompt of several lines <C-k> and <C-j> move
--       between them, and from the first and the last through the prompts before. <C-h> in an empty prompt
--       opens the agent view. After <Esc> the four are the windows.
--   17. Type a prompt until it takes a second row: the box stays whole (a rule above and below it, its mark
--       at the start). If it does not, <Esc> <C-r> draws it again; and whether it also breaks in a terminal
--       without Neovim says where the fault is:
--         CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 CLAUDE_CODE_NATIVE_CURSOR=1 claude --settings '{"tui":"default"}'
--   18. A window beside Neovim's and away again (narrower, then as wide as before): what was printed stays
--       as narrow as it was, and <Esc> <C-r> prints it again at the window's width.
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

-- `claude`: how it was started, what is on its screen, then every byte it is sent. $CLAUDE_TEST_CHILD has
-- it start another program first: `editor` as Claude Code starts the editor of its Ctrl+G (the terminal is
-- the editor's), `command` as it runs a command that happens to be that editor (it is not), `other` for a
-- program that has the terminal and is not the editor.
write(base .. "/bin/claude", {
  "#!/bin/sh",
  "{",
  [[  printf 'cwd=%s\n' "$PWD"]],
  [[  for a in "$@"; do printf 'arg=%s\n' "$a"; done]],
  [[  printf 'server=[%s]\nopenai=[%s]\nanthropic=[%s]\ngemini=[%s]\nscreen=%s\ncursor=%s\nlinks=%s\n' \]],
  [[    "${NVIM-not set}" "${OPENAI_API_KEY-not set}" "${ANTHROPIC_API_KEY-not set}" "${GEMINI_API_KEY-not set}" \]],
  [[    "$CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN" "$CLAUDE_CODE_NATIVE_CURSOR" "$FORCE_HYPERLINK"]],
  [[} > "$CLAUDE_TEST_OUT/started.$$"]],
  [[mv "$CLAUDE_TEST_OUT/started.$$" "$CLAUDE_TEST_OUT/started"]],
  [[cat "$CLAUDE_TEST_OUT/screen" 2>/dev/null]],
  "stty raw -echo 2>/dev/null",
  [[case "$CLAUDE_TEST_CHILD" in]],
  [[  editor) "$EDITOR" ;;]],
  [[  command) "$EDITOR" < /dev/null & ;;]],
  [[  other) sleep 5 ;;]],
  "esac",
  [[exec cat > "$CLAUDE_TEST_OUT/keys"]],
})
vim.fn.setfperm(base .. "/bin/claude", "rwxr-xr-x")
-- (a script, so that the program is called by this name; it takes the terminal for as long as it is one)
write(base .. "/bin/fake-editor", { "#!/bin/sh", "cat > /dev/null", "sleep 5", "exit 0" })
vim.fn.setfperm(base .. "/bin/fake-editor", "rwxr-xr-x")
vim.env.PATH = base .. "/bin:" .. vim.env.PATH
vim.env.CLAUDE_TEST_OUT = out
vim.env.EDITOR = base .. "/bin/fake-editor"
vim.env.VISUAL = nil
vim.env.OPENAI_API_KEY = "sk-not-for-claude-code"
vim.env.ANTHROPIC_API_KEY = "sk-ant-not-for-claude-code"
vim.fn.setenv("GEMINI_API_KEY", "") -- (set, to nothing: it is that again afterwards)

local notes, asked, answers, opened, fed, typed = {}, {}, {}, {}, {}, {}
vim.notify = function(msg) notes[#notes + 1] = msg end
vim.fn.confirm = function(question)
  asked[#asked + 1] = question
  return table.remove(answers, 1) or 2 -- No, unless the test says otherwise
end
vim.ui.open = function(what) opened[#opened + 1] = what end
-- (a key handed on to the program in the terminal: there is no terminal mode here for it to arrive in)
local fed_mode, fed_escaped
vim.api.nvim_feedkeys = function(keys, mode, escape)
  fed[#fed + 1] = keys
  fed_mode, fed_escaped = mode, escape
end
-- (and no keyboard: the key that is typed after <C-x>)
vim.fn.getcharstr = function() return table.remove(typed, 1) or "" end
-- how Neovim is at the moment the program is started
local at_start = {}
local jobstart = vim.fn.jobstart
vim.fn.jobstart = function(argv, opts)
  at_start = { guicursor = vim.o.guicursor, openai = vim.env.OPENAI_API_KEY, argv = argv }
  return jobstart(argv, opts)
end

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
--- The keys a buffer maps for itself in `mode`, as the bytes of each, in order: without [[ and ]], which
--- Neovim gives every terminal buffer.
local function mapped(buf, mode)
  local keys = {}
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if map.lhs ~= "[[" and map.lhs ~= "]]" then keys[#keys + 1] = vim.keycode(map.lhs) end
  end
  table.sort(keys)
  return keys
end
local function codes(list)
  local keys = vim.tbl_map(vim.keycode, list)
  table.sort(keys)
  return keys
end
local function buffer_text(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") end
local function terminals()
  return vim.tbl_filter(function(buf) return vim.bo[buf].buftype == "terminal" end, vim.api.nvim_list_bufs())
end

local links = require "user.ai.claude_links"

---------------------------------------------------------------------------------------- what <CR> reads

do
  --- What `at` finds with the cursor on `piece` of row `row`: the texts in turn, a joined one marked "+".
  local function at(lines, row, piece)
    local col = assert(lines[row]:find(piece, 1, true), piece)
    local found = links.at(lines, row, col)
    return found and vim.tbl_map(function(text) return (text.joined and "+" or "") .. text.text end, found)
  end
  local function same(a, b) return vim.deep_equal(a, b) end

  local rows = {
    "● See src/main.rs:12:3, or https://example.net/x.",
    "● Read(src/main.rs)",
    "  (in `notes.md`).   and    more",
    "",
    "  https://en.wikipedia.org/wiki/Vim_(text_editor).",
    "",
    "│ src/main.rs#L7 │",
    "",
    "  - https://example.com/longer/than/the/next",
    "  - https://example.com/short",
    "  https://example.com/as/long/as/it/gets/here",
    "  https://example.com/another",
  }
  ok(
    "a path, without the comma after it",
    same(at(rows, 1, "main.rs"), { "src/main.rs:12:3" }),
    vim.inspect(at(rows, 1, "main.rs"))
  )
  ok(
    "an address, without the full stop",
    same(at(rows, 1, "example.net"), { "https://example.net/x" }),
    vim.inspect(at(rows, 1, "example.net"))
  )
  ok(
    "what a tool was called with comes before the whole of it",
    same(at(rows, 2, "main"), { "src/main.rs", "Read(src/main.rs)" }),
    vim.inspect(at(rows, 2, "main"))
  )
  ok(
    "quotes and brackets around it are not part of it",
    same(at(rows, 3, "notes"), { "notes.md" }),
    vim.inspect(at(rows, 3, "notes"))
  )
  ok(
    "a bracket that closes one of its own is",
    same(at(rows, 5, "wikipedia"), { "https://en.wikipedia.org/wiki/Vim_(text_editor)" }),
    vim.inspect(at(rows, 5, "wikipedia"))
  )
  ok("nothing between words", links.at(rows, 3, (rows[3]:find("and    ", 1, true)) + 4) == nil)
  ok("nothing on an empty row, or past the rows", links.at(rows, 4, 0) == nil and links.at(rows, 99, 0) == nil)
  ok(
    "in a box: the text, not its sides",
    same(at(rows, 7, "main"), { "src/main.rs#L7" }),
    vim.inspect(at(rows, 7, "main"))
  )
  ok("and nothing on a side", links.at(rows, 7, 0) == nil and links.at(rows, 7, #rows[7] - 1) == nil)
  ok(
    "the longest row of a list is not broken: what follows is too short to be the rest of it",
    same(at(rows, 9, "longer"), { "https://example.com/longer/than/the/next" }),
    vim.inspect(at(rows, 9, "longer"))
  )
  ok(
    "nor does an address go on in the next one",
    same(at(rows, 11, "as/long"), { "https://example.com/as/long/as/it/gets/here" }),
    vim.inspect(at(rows, 11, "as/long"))
  )
  ok(
    "and the next one is not the rest of it",
    same(at(rows, 12, "another"), { "https://example.com/another" }),
    vim.inspect(at(rows, 12, "another"))
  )

  -- an address that did not fit in its row
  local address = "https://example.com/" .. ("a/"):rep(23) .. "end.html"
  local head = "  see "
  local cut = 60 - #head
  local broken = {
    ("─"):rep(90),
    ("x"):rep(20) .. " " .. ("y"):rep(39),
    head .. address:sub(1, cut),
    "  " .. address:sub(cut + 1) .. " and more",
    "  short https://example.org/b",
    "  next row",
  }
  ok(
    "an address broken at the end of its row is put together, and said to be",
    same(at(broken, 3, "example.com"), { "+" .. address, address:sub(1, cut) }),
    vim.inspect(at(broken, 3, "example.com"))
  )
  ok(
    "from the row it goes on in too",
    same(at(broken, 4, "end.html"), { "+" .. address, address:sub(cut + 1) }),
    vim.inspect(at(broken, 4, "end.html"))
  )
  ok(
    "one that merely ends its row is left as it is",
    same(at(broken, 5, "example.org"), { "https://example.org/b" }),
    vim.inspect(at(broken, 5, "example.org"))
  )
  local longer = "https://example.com/" .. ("a/"):rep(60) .. "end.html"
  local three = {
    ("x"):rep(60),
    head .. longer:sub(1, cut),
    "  " .. longer:sub(cut + 1, cut + 58),
    "  " .. longer:sub(cut + 59) .. ".",
  }
  ok(
    "over three rows, from the one in the middle",
    #longer > cut + 58 and same(at(three, 3, "a/a"), { "+" .. longer, longer:sub(cut + 1, cut + 58) }),
    vim.inspect(at(three, 3, "a/a"))
  )
  ok(
    "a word that would have fitted in its row was not broken there",
    same(at({ "  the first row ends in src/ma", "  in.rs and goes on to the end" }, 1, "src"), { "src/ma" }),
    vim.inspect(at({ "  the first row ends in src/ma", "  in.rs and goes on to the end" }, 1, "src"))
  )
  local boxed = {
    "│ see https://example.com/aaaa │",
    "│ bbbb/end.html and more       │",
  }
  ok(
    "and in a box, up to its side",
    same(at(boxed, 1, "example"), { "+https://example.com/aaaabbbb/end.html", "https://example.com/aaaa" }),
    vim.inspect(at(boxed, 1, "example"))
  )
end

---------------------------------------------------------------------------------------- what it names

do
  ok("an address with a space in it is refused", links.classify("https://example.com/a b").kind == "refused")
  local target = links.classify "https://example.com/a"
  ok(
    "an address has its host, and nothing to ask about",
    target.kind == "url" and target.host == "example.com" and target.why == nil,
    vim.inspect(target)
  )
  for name, case in pairs {
    ["a name before an @"] = { "https://github.com@collector.example/x", "before an @", "collector.example" },
    ["letters of another alphabet"] = { "https://exаmple.com/x", "not plain ASCII", "exаmple.com" },
    ["their xn-- spelling"] = { "https://xn--exmple-4nf.com/x", "xn--", "xn--exmple-4nf.com" },
    ["a mark that turns the text around"] = {
      "https://example.com/\226\128\174gpj.exe",
      "not plain ASCII",
      "example.com",
    },
  } do
    target = links.classify(case[1])
    ok(
      "an address that reads as another is asked about, and why: " .. name,
      target.kind == "url" and has(target.why, case[2]) and target.host == case[3],
      vim.inspect(target)
    )
  end
  ok(
    "what a question shows cannot pass for something else",
    links.spelled "exаmple.com/\226\128\174x\n" == "ex<U+0430>mple.com/<U+202E>x<U+000A>",
    links.spelled "exаmple.com/\226\128\174x\n"
  )
  ok("text with a control character is nothing", links.classify "src/main.rs\27[0m" == nil)
  ok("javascript: is refused", links.classify("javascript:alert(1)").kind == "refused")
  ok("another program's links are refused", links.classify("vscode://file/x").kind == "refused")
  target = links.classify "file:///tmp/a%20b.txt"
  ok(
    "file:// is a path, decoded",
    target.kind == "path" and target.candidates[1].path == "/tmp/a b.txt",
    vim.inspect(target)
  )
  target = links.classify "src/main.rs:12:3"
  ok(
    "a path with a line and a column",
    target.kind == "path" and vim.deep_equal(target.candidates[2], { path = "src/main.rs", line = 12, col = 3 }),
    vim.inspect(target)
  )
  ok("a path with #L", links.classify("src/main.rs#L7").candidates[2].line == 7)

  local found = links.resolve(links.classify "src/main.rs:12:3", { "/nowhere", project }, project)
  ok(
    "a path is looked for in each directory",
    found and found.path == project .. "/src/main.rs" and found.line == 12 and found.col == 3 and found.inside == true,
    vim.inspect(found)
  )
  found = links.resolve(links.classify(odd), {}, project)
  ok("a name with | % # ` $ in it is the file of that name", found and found.path == odd, vim.inspect(found))
  found = links.resolve(links.classify "~/proj/notes.md", {}, project)
  ok("~ is the home directory", found and found.path == project .. "/notes.md" and found.inside, vim.inspect(found))
  found = links.resolve(links.classify(outside), {}, project)
  ok(
    "a file outside Claude Code's directory is said to be",
    found and found.path == outside and found.inside == false,
    vim.inspect(found)
  )
  found = links.resolve(links.classify "../outside.txt", { project }, project)
  ok(
    "also by a path that climbs out of it",
    found and found.path == outside and found.inside == false,
    vim.inspect(found)
  )
  found = links.resolve(links.classify "link.txt", { project }, project)
  ok(
    "and by a link in it that leads out: the file itself",
    found and found.path == outside and found.inside == false,
    vim.inspect(found)
  )
  found = links.resolve(links.classify "src/main.rs", { project }, "/")
  ok("nothing is inside when Claude Code was started in /", found and found.inside == false, vim.inspect(found))
  found = links.resolve(links.classify "src/main.rs", { project }, nil)
  ok("nor when it was not started", found and found.inside == false, vim.inspect(found))
  local why
  found, why = links.resolve(links.classify "$HOME/proj/notes.md", { project }, project)
  ok("a variable is not expanded", not found and has(why, "No file"), vim.inspect(found))
  found, why = links.resolve(links.classify "pipe", { project }, project)
  ok("a pipe is not a file to open", not found and has(why, "No file"), why)
  found, why = links.resolve(links.classify "src", { project }, project)
  ok("a directory is said to be one", not found and has(why, "is a directory"), why)
  found = links.resolve(links.classify "/dev/zero", {}, project)
  ok("a device is not a file to open", not found)
  if uv.fs_stat "/proc/self/environ" then
    found, why = links.resolve(links.classify "/proc/self/environ", {}, "/proc")
    ok("nor what the kernel shows as a file", not found and has(why, "not a file on a disk"), why or vim.inspect(found))
  end
end

-------------------------------------------------------------------------------------------- the buffer

local cc = require "user.ai.claude_code"
local S = cc._state()

-- an address this Neovim can be reached at, as every Neovim with a window has one
local listening = pcall(vim.fn.serverstart, "127.0.0.1:0")
if not (listening and vim.v.servername ~= "") then
  print "(no server could be started here: that Claude Code is not told Neovim's address was not tried)"
end
-- what is on Claude Code's screen
local long = "https://example.com/" .. ("seg/"):rep(20) .. "end.html"
write(out .. "/screen", {
  "● Read(src/main.rs)",
  "  see src/main.rs:12:3, and notes.md.",
  "  docs: https://example.org/a for more",
  "  elsewhere: " .. outside,
  "  bad: https://github.com@collector.example/x and https://exаmple.com/x",
  "  names: link2.txt pipe no/such.txt",
  "  long: " .. long .. " and so on",
  "  the end",
})

vim.cmd.cd(project)
vim.cmd.edit(project .. "/notes.md")
local file_buf = vim.api.nvim_get_current_buf()
local windows = #vim.api.nvim_list_wins()
local cursor = vim.o.guicursor

cc.open()
ok(
  "Claude Code starts",
  wait_for(function() return uv.fs_stat(out .. "/started") ~= nil end),
  table.concat(notes, "\n")
)
local term = vim.api.nvim_get_current_buf()
local info = started()
ok("in the window, without a split", #vim.api.nvim_list_wins() == windows and vim.bo[term].buftype == "terminal")
ok(
  "a listed buffer that is hidden, not unloaded, when left",
  vim.bo[term].buflisted and vim.bo[term].bufhidden == "hide"
)
ok(
  "named after the program, so that its tab says `claude`",
  vim.fn.fnamemodify(vim.api.nvim_buf_get_name(term), ":t") == "claude",
  vim.api.nvim_buf_get_name(term)
)
ok("it starts in Neovim's directory when the file has no project root", info.cwd == project, info.cwd)
local given = #info.args == 2 and info.args[1] == "--settings" and vim.json.decode(info.args[2]) or {}
ok(
  "with the settings `claude` has in the shell, and nothing else",
  vim.tbl_get(given, "permissions", "blockReadsOutsideWorkingDirectories") == true,
  vim.inspect(info.args)
)
ok(
  "its own vim mode is off, and it keeps to the main screen",
  given.editorMode == "normal" and given.tui == "default",
  vim.inspect(given)
)
ok(
  "the main screen, the terminal's cursor and addresses in full are asked for",
  info.screen == "1" and info.cursor == "1" and info.links == "0",
  vim.inspect(info)
)
ok("it is not told where this Neovim listens", info.server == "[]", info.server)
ok("another provider's key does not reach Claude Code: it is not set at all", info.openai == "[not set]", info.openai)
ok("nor a key for Claude: this is the login", info.anthropic == "[not set]", info.anthropic)
ok("nor one that is set to nothing", info.gemini == "[not set]", info.gemini)
ok(
  "Neovim has its keys as before",
  vim.env.OPENAI_API_KEY == "sk-not-for-claude-code"
    and vim.env.ANTHROPIC_API_KEY == "sk-ant-not-for-claude-code"
    and vim.fn.environ().GEMINI_API_KEY == "",
  vim.inspect { vim.env.OPENAI_API_KEY, vim.env.ANTHROPIC_API_KEY, vim.fn.environ().GEMINI_API_KEY }
)
ok(
  "the terminal is made with insert mode's cursor for its prompt",
  has(at_start.guicursor, ",t:ver25") and not has(at_start.guicursor, "t:block") and at_start.openai == nil,
  vim.inspect(at_start)
)
ok("and 'guicursor' is as before", vim.o.guicursor == cursor, vim.o.guicursor)

local job = S.job
vim.api.nvim_win_set_buf(0, file_buf)
cc.open()
ok(
  "<Leader>AC again is the same session",
  S.job == job and vim.api.nvim_get_current_buf() == term and #terminals() == 1
)

-- the keys
ok(
  "the prompt's own keys are these, and no more",
  vim.deep_equal(mapped(term, "t"), codes { "<Esc>", "<C-h>", "<C-j>", "<C-k>", "<C-l>", "<S-CR>", "<C-z>" }),
  vim.inspect(vim.tbl_map(function(map) return map.lhs end, vim.api.nvim_buf_get_keymap(term, "t")))
)
ok(
  "and these above it",
  vim.deep_equal(mapped(term, "n"), codes { "<Esc>", "<C-r>", "<C-x>", "<CR>" }),
  vim.inspect(vim.tbl_map(function(map) return map.lhs end, vim.api.nvim_buf_get_keymap(term, "n")))
)
ok(
  "visual mode and the rest are the editor's own",
  #mapped(term, "x") == 0 and #mapped(term, "o") == 0 and #mapped(term, "i") == 0,
  vim.inspect { mapped(term, "x"), mapped(term, "o"), mapped(term, "i") }
)
local described = true
for _, mode in ipairs { "t", "n" } do
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(term, mode)) do
    described = described and type(map.desc) == "string" and map.desc ~= ""
  end
end
ok("each says what it does (the cheatsheet lists them)", described)
press("t", "<S-CR>")
ok(
  "<S-CR> is a new line for Claude Code",
  wait_for(function() return keys_sent() == "\n" end),
  vim.inspect(keys_sent())
)
typed = { "\11" }
press("n", "<C-X>")
ok(
  "<C-x> above the prompt types Ctrl+X and the key after it at the prompt, past the mappings",
  #fed == 1 and fed[1] == "i\24\11" and fed_mode == "n" and fed_escaped == true,
  vim.inspect { fed, fed_mode, fed_escaped }
)
fed, typed = {}, { vim.keycode "<Left>" }
press("n", "<C-X>")
ok(
  "a key with a name is handed on as it is",
  #fed == 1 and fed[1] == "i\24" .. vim.keycode "<Left>" and fed_escaped == false,
  vim.inspect { fed, fed_escaped }
)
fed, typed = {}, { "\195\128" }
press("n", "<C-X>")
ok("and a letter as a letter", fed[1] == "i\24\195\128" and fed_escaped == true, vim.inspect { fed, fed_escaped })
fed, typed = {}, { "\27" }
press("n", "<C-X>")
ok("<C-x> <Esc> types nothing", #fed == 0, vim.inspect(fed))
press("n", "<Esc>")
ok(
  "<Esc> from normal mode is Claude Code's Escape",
  wait_for(function() return keys_sent() == "\n\27" end),
  vim.inspect(keys_sent())
)
press("n", "<C-R>")
ok(
  "<C-r> from normal mode is Claude Code's Ctrl+L",
  wait_for(function() return keys_sent() == "\n\27\12" end),
  vim.inspect(keys_sent())
)
local arrows = { { "<C-H>", "<Left>" }, { "<C-J>", "<Down>" }, { "<C-K>", "<Up>" }, { "<C-L>", "<Right>" } }
for _, key in ipairs(arrows) do
  fed, fed_mode = {}, nil
  press("t", key[1])
  ok(
    ("%s at the prompt is %s, typed past the mappings"):format(key[1], key[2]),
    #fed == 1 and fed[1] == vim.keycode(key[2]) and fed_mode == "n",
    vim.inspect { fed, fed_mode }
  )
end
fed = {}
press("t", "<Esc>")
vim.wait(100)
ok(
  "leaving the prompt sends it nothing, and the arrows went as keys",
  keys_sent() == "\n\27\12" and #fed == 0,
  vim.inspect { keys_sent(), fed }
)
ok(
  "<C-z> is taken",
  vim.fn.maparg("<C-Z>", "t", false, true).buffer == 1 and vim.fn.maparg("<C-Z>", "t", false, true).rhs == "<Nop>"
)

-- <CR>
ok(
  "what Claude Code prints is in the buffer",
  wait_for(function() return has(buffer_text(term), "the end") end),
  buffer_text(term)
)
local function cursor_on(piece)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(term, 0, -1, false)) do
    local col = line:find(piece, 1, true)
    if col then return vim.api.nvim_win_set_cursor(0, { row, col }) end
  end
  error("not on the screen: " .. piece)
end
cursor_on "src/main.rs:12:3"
press("n", "<CR>")
ok(
  "<CR> on a path opens the file at the line and column",
  vim.api.nvim_buf_get_name(0) == project .. "/src/main.rs"
    and vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 12, 2 }),
  vim.api.nvim_buf_get_name(0) .. " " .. vim.inspect(vim.api.nvim_win_get_cursor(0))
)
ok("in the same window", #vim.api.nvim_list_wins() == windows)
vim.api.nvim_win_set_buf(0, term)
cursor_on "Read(src"
press("n", "<CR>")
ok(
  "<CR> on a tool call opens the file it names",
  vim.api.nvim_buf_get_name(0) == project .. "/src/main.rs",
  vim.api.nvim_buf_get_name(0)
)
vim.api.nvim_win_set_buf(0, term)
cursor_on "example.org"
press("n", "<CR>")
ok(
  "<CR> on a web address opens it, unasked",
  #asked == 0 and opened[1] == "https://example.org/a",
  vim.inspect { asked, opened }
)

asked, answers, opened = {}, {}, {}
cursor_on "outside.txt"
press("n", "<CR>")
ok(
  "<CR> on a file outside Claude Code's directory asks, with the file's own path",
  #asked == 1 and has(asked[1], outside) and vim.api.nvim_get_current_buf() == term,
  vim.inspect(asked)
)
answers = { 1 }
press("n", "<CR>")
ok("and Yes opens it", vim.api.nvim_buf_get_name(0) == outside, vim.api.nvim_buf_get_name(0))
vim.api.nvim_win_set_buf(0, term)
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
  #asked == 1
    and has(asked[1], "/home/two")
    and not has(asked[1], "two\nlines")
    and vim.api.nvim_get_current_buf() == term,
  vim.inspect(asked)
)
asked, answers, notes = {}, {}, {}
cursor_on "pipe"
press("n", "<CR>")
ok("a pipe is not opened", vim.api.nvim_get_current_buf() == term and has(notes[1], "No file"), vim.inspect(notes))
cursor_on "no/such"
press("n", "<CR>")
ok(
  "nor a file that is not there",
  vim.api.nvim_get_current_buf() == term and has(notes[2], "No file: no/such.txt"),
  vim.inspect(notes)
)
notes = {}
vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(term), 0 })
press("n", "<CR>")
ok("and on nothing it says so", has(notes[1], "Nothing to open"), vim.inspect(notes))

asked, answers, opened = {}, {}, {}
cursor_on "seg/seg"
press("n", "<CR>")
ok(
  "<CR> on an address that goes on in the next row asks, with all of it",
  #asked == 1 and has(asked[1], "put together") and has(asked[1], long) and #opened == 0,
  vim.inspect(asked)
)
answers = { 1 }
press("n", "<CR>")
ok("and Yes opens all of it", opened[1] == long, vim.inspect(opened))
asked, answers, opened = {}, { 1 }, {}
cursor_on "end.html"
press("n", "<CR>")
ok("from its second row too", #asked == 1 and opened[1] == long, vim.inspect { asked, opened })
asked, answers, opened = {}, {}, {}

-- shown in another window
vim.cmd "rightbelow vsplit"
local right = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(right, file_buf)
vim.wo[right].number = true
cc.open()
ok(
  "in another window it is the terminal it was: no line numbers",
  vim.api.nvim_get_current_buf() == term and not vim.wo[right].number
)
vim.api.nvim_win_set_buf(right, file_buf)
ok("and the file that was there has its own again", vim.wo[right].number)
vim.api.nvim_win_close(right, true)

-- the window the chat takes
vim.cmd "leftabove vsplit"
vim.api.nvim_win_set_buf(0, file_buf)
local left = vim.api.nvim_get_current_win()
vim.cmd.wincmd "l"
right = vim.api.nvim_get_current_win()
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

-- the session ends by itself
notes = {}
vim.fn.jobstop(job)
ok("Claude Code exits", wait_for(function() return S.job == nil end))
ok("its buffer stays to be read", vim.api.nvim_buf_is_valid(term) and has(buffer_text(term), "the end"))
ok(
  "without the keys that talked to it; <CR> still opens things",
  #mapped(term, "t") == 0 and vim.deep_equal(mapped(term, "n"), codes { "<CR>" }),
  vim.inspect(vim.tbl_map(function(map) return map.lhs end, vim.api.nvim_buf_get_keymap(term, "n")))
)
ok("and what the window shows needs no saying", #notes == 0, vim.inspect(notes))
uv.fs_unlink(out .. "/started")
vim.cmd.cd(base .. "/home") -- (the next session is where the last one was, wherever Neovim is by now)
cc.open()
ok(
  "<Leader>AC then starts it again",
  wait_for(function() return uv.fs_stat(out .. "/started") ~= nil end) and S.job ~= nil and S.job ~= job
)
ok("where the last session was started, unasked", started().cwd == project and #asked == 0, started().cwd)
ok(
  "with one terminal buffer: the old one is gone",
  #terminals() == 1 and not vim.api.nvim_buf_is_valid(term),
  #terminals()
)
vim.cmd.cd(project)
term = vim.api.nvim_get_current_buf()

-- it ends while another buffer is in the window
vim.api.nvim_win_set_buf(0, file_buf)
notes = {}
vim.fn.jobstop(S.job)
ok(
  "an exit that nothing shows is said",
  wait_for(function() return S.job == nil end) and has(notes[1], "Claude Code exited"),
  vim.inspect(notes)
)

-- the buffer is closed, as <Leader>x closes it
uv.fs_unlink(out .. "/started")
cc.open()
wait_for(function() return uv.fs_stat(out .. "/started") ~= nil end)
term = vim.api.nvim_get_current_buf()
job = S.job
vim.api.nvim_win_set_buf(0, file_buf)
vim.cmd("bdelete! " .. term)
ok(
  "closing the buffer ends Claude Code",
  wait_for(function() return S.job == nil end) and #terminals() == 0,
  #terminals()
)
uv.fs_unlink(out .. "/started")
cc.open()
ok(
  "and <Leader>AC starts it again",
  wait_for(function() return uv.fs_stat(out .. "/started") ~= nil end) and S.job ~= job and #terminals() == 1
)

-- the editor of Claude Code's Ctrl+G
local function with_child(kind)
  vim.fn.jobstop(S.job)
  wait_for(function() return S.job == nil end)
  vim.api.nvim_win_set_buf(0, file_buf)
  uv.fs_unlink(out .. "/started")
  uv.fs_unlink(out .. "/keys")
  vim.env.CLAUDE_TEST_CHILD = kind
  cc.open()
  vim.env.CLAUDE_TEST_CHILD = nil
  assert(wait_for(function() return uv.fs_stat(out .. "/started") ~= nil end), "claude did not start")
  -- (the program it starts is there)
  local pid = vim.fn.jobpid(S.job)
  assert(wait_for(function() return #vim.api.nvim_get_proc_children(pid) > 0 end), "no child of claude: " .. kind)
  vim.wait(200)
  fed = {}
end
if uv.fs_stat "/proc/self/task" then
  with_child "editor"
  ok("<Esc> is the editor's while Claude Code has handed it the terminal", wait_for(function()
    fed = {}
    press("t", "<Esc>")
    return #fed == 1
  end) and fed[1] == vim.keycode "<Esc>", vim.inspect(fed))
  fed = {}
  press("t", "<S-CR>")
  ok(
    "so is <S-CR>",
    #fed == 1 and fed[1] == vim.keycode "<S-CR>" and keys_sent() == "",
    vim.inspect { fed, keys_sent() }
  )
  for _, key in ipairs(arrows) do
    fed, fed_mode = {}, nil
    press("t", key[1])
    ok(
      ("and %s, not an arrow"):format(key[1]),
      #fed == 1 and fed[1] == vim.keycode(key[1]) and fed_mode == "n",
      vim.inspect { fed, fed_mode }
    )
  end

  with_child "command"
  press("t", "<Esc>")
  ok("an editor that a command runs does not have the terminal: <Esc> leaves the prompt", #fed == 0, vim.inspect(fed))
  with_child "other"
  press("t", "<Esc>")
  ok("nor is another program the editor", #fed == 0, vim.inspect(fed))
else
  print "(no /proc here: the editor of Claude Code's Ctrl+G was not tried)"
end

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
ok(
  "in the home directory it asks first, and No starts nothing",
  #asked == 1 and has(asked[1], "~") and S.job == nil and not uv.fs_stat(out .. "/started"),
  vim.inspect(asked)
)
answers = { 1 }
cc.open()
ok(
  "Yes starts it there",
  wait_for(function() return uv.fs_stat(out .. "/started") ~= nil end) and started().cwd == vim.env.HOME,
  started().cwd
)
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
  local chat, made_chats, hidden = nil, {}, {}
  local ui = {}
  function ui:show_in_win(opts)
    self.window_opts = opts.window_opts
    vim.api.nvim_win_set_buf(opts.winnr, chat_buf)
  end
  function ui:hide(opts) hidden[#hidden + 1] = opts or {} end
  package.loaded["codecompanion"] = {
    last_chat = function() return chat end,
    chat = function(args)
      made_chats[#made_chats + 1] = args
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
      if name:find "^user%.ai" and name ~= "user.ai.claude_code" and name ~= "user.ai.claude_links" then
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
  ok("with Claude through the login chosen, <Leader>AC is Claude Code", fine and opens == 1 and #made_chats == 0, err)
  fine, err = chosen { provider = "claude", route = "api" }
  ok(
    "with Claude by API key, the CodeCompanion chat: in the window, as a buffer",
    fine
      and opens == 0
      and #made_chats == 1
      and made_chats[1].window_opts.layout == "buffer"
      and vim.api.nvim_get_current_buf() == chat_buf
      and #vim.api.nvim_list_wins() == count_before,
    err or vim.inspect(made_chats)
  )
  fine, err = chosen { provider = "ollama" }
  ok(
    "again, and the buffer that was there is back",
    fine and #made_chats == 1 and vim.api.nvim_get_current_buf() == file and hidden[1] and hidden[1].keep_window == true,
    err or vim.inspect(hidden)
  )
  fine, err = chosen { provider = "ollama" }
  ok(
    "with the local model, the same chat again, told which buffer it took the place of",
    fine and #made_chats == 1 and vim.api.nvim_get_current_buf() == chat_buf and chat.buffer_context.bufnr == file,
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
  ok(
    "a chat in a split of its own is hidden as CodeCompanion does it",
    fine and #hidden == 1 and hidden[1].keep_window == nil,
    err or vim.inspect(hidden)
  )
end

------------------------------------------------------------------------------------------------------ the pin

-- Where the window is, at the prompt and above it. Seen in another Neovim, which has what a script's has
-- not: terminal mode, in which the window follows its terminal.
do
  -- `claude`: three rows of conversation, then a frame of four with the cursor in its second. A key at a
  -- time: o prints a row above the frame, m opens a menu of five rows under it, c closes that.
  write(base .. "/pin/claude", {
    "#!/bin/sh",
    [[here() { printf '\r\033[8C'; }]],
    [[frame() { printf -- '----------\r\nPROMPT> \r\n----------\r\nFOOTER\033[2A'; here; }]],
    [[printf 'one\r\ntwo\r\nthree\r\n']],
    "stty raw -echo",
    "frame",
    [[while key=$(dd bs=1 count=1 2>/dev/null) && [ -n "$key" ]; do]],
    [[  case "$key" in]],
    [[    o) printf '\033[1A\r\033[Jmore\r\n'; frame ;;]],
    [[    m) printf '\033[2B\r\nMENU 1\r\nMENU 2\r\nMENU 3\r\nMENU 4\r\nMENU 5\033[7A'; here ;;]],
    [[    c) printf '\033[3B\r\033[J\033[3A'; here ;;]],
    "  esac",
    "done",
  })
  vim.fn.setfperm(base .. "/pin/claude", "rwxr-xr-x")
  local child = vim.fn.jobstart({ vim.v.progpath, "--embed", "--headless", "--clean", "-i", "NONE" }, {
    rpc = true,
    cwd = project,
    env = { PATH = base .. "/pin:" .. vim.env.PATH },
  })
  local function run(code, ...) return vim.rpcrequest(child, "nvim_exec_lua", code, { ... }) end
  local function type_keys(keys) vim.rpcrequest(child, "nvim_input", keys) end
  --- What the window shows: rows are the screen's, 0 for one that is not in the window.
  local function seen()
    return run [[
      local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local function row(text)
        for lnum = #lines, 1, -1 do
          if lines[lnum]:find(text, 1, true) then return vim.fn.screenpos(win, lnum, 1).row end
        end
        return 0
      end
      local view, cursor = vim.fn.winsaveview(), vim.api.nvim_win_get_cursor(win)
      return {
        mode = vim.api.nvim_get_mode().mode,
        last = vim.fn.win_screenpos(win)[1] + vim.api.nvim_win_get_height(win) - 1,
        footer = row "FOOTER",
        prompt = row "PROMPT>",
        menu = row "MENU 5",
        cursor = vim.fn.screenpos(win, cursor[1], cursor[2] + 1).row,
        top = lines[view.topline],
        filler = view.topfill,
        scrollback = #lines - vim.api.nvim_win_get_height(win),
        scrolloff = vim.wo[win].scrolloff,
      }
    ]]
  end
  local s
  --- Wait until what the window shows is as `cond` says; `s` is then what it shows.
  local function shows(cond)
    return wait_for(function()
      s = seen()
      return cond(s)
    end)
  end
  local function at_bottom(what) return s[what] == s.last and s.cursor == s.prompt end

  run(
    [[
    vim.opt.rtp:prepend(...)
    vim.o.swapfile = false
    vim.o.scrolloff = 10
    require("user.ai.claude_code").open()
  ]],
    repo
  )
  ok(
    "a session starts with its prompt at the bottom of the window, and empty rows above what it has said",
    shows(function() return s.mode == "t" and s.prompt > 0 and at_bottom "footer" end)
      and s.filler > 0
      and s.scrollback == 0,
    vim.inspect(s)
  )
  type_keys "m"
  ok(
    "a menu under the prompt takes the rows it needs",
    shows(function() return at_bottom "menu" end) and s.footer == s.last - 5,
    vim.inspect(s)
  )
  type_keys "c"
  ok(
    "and the prompt is at the bottom again when it closes",
    shows(function() return s.menu == 0 and at_bottom "footer" end),
    vim.inspect(s)
  )
  type_keys(("o"):rep(30))
  ok(
    "with more said than the window holds it is the terminal's own last row",
    shows(function() return s.scrollback > 10 and at_bottom "footer" end) and s.filler == 0,
    vim.inspect(s)
  )
  type_keys "m"
  shows(function() return at_bottom "menu" end)
  type_keys "c"
  ok(
    "the rows a menu leaves under the prompt are then empty rows at the top of the window",
    shows(function() return s.menu == 0 and at_bottom "footer" end) and s.filler == 5 and s.mode == "t",
    vim.inspect(s)
  )
  type_keys "<Esc>"
  ok(
    "above the prompt they are rows of the conversation, and the prompt stays where it is",
    shows(function() return s.mode == "nt" end) and at_bottom "footer" and s.filler == 0 and s.top == "more",
    vim.inspect(s)
  )
  ok("for which 'scrolloff' is 0 in the window of the session", s.scrolloff == 0, vim.inspect(s))
  type_keys "i"
  ok(
    "and at the prompt again as before",
    shows(function() return s.mode == "t" and s.filler == 5 end) and at_bottom "footer",
    vim.inspect(s)
  )
  type_keys "<Esc>"
  shows(function() return s.mode == "nt" end)
  local elsewhere = run [[
    vim.cmd.enew()
    local file = vim.wo.scrolloff
    vim.cmd.vnew()
    require("user.ai.claude_code").open()
    return { file = file, session = vim.wo.scrolloff }
  ]]
  ok(
    "another buffer in the window has its own 'scrolloff', and another window with the session this one",
    elsewhere.file == 10 and elsewhere.session == 0,
    vim.inspect(elsewhere)
  )
  ok(
    "<Leader>AC in another window: the prompt at the bottom of that one",
    shows(function() return s.mode == "t" and at_bottom "footer" end),
    vim.inspect(s)
  )
  vim.fn.jobstop(child)
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
