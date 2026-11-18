-- The conversation of a Claude Code session as Markdown, and what <CR> opens in it: the text of the history
-- buffer that lua/user/ai/claude_code.lua shows beside the Claude Code terminal. Nothing here touches a window
-- or a job; tests/claude_code.lua runs it as it is.
--
-- The text arrives as batches from the mod in claude-code/hooks/register.ts:
--   { session = id, cwd = dir, ops = { ... } }
--   { op = "user",      id, text, at, folded }    a prompt (`at`: when, in milliseconds; `folded`: typed while
--                                                 Claude worked, which can come in by two rows: shown once)
--   { op = "assistant", id, text }                a piece of the answer
--   { op = "tool",      id, tool_id, name, input }   a tool call, one line
--   { op = "result",    tool_id, error }          its outcome: ticks that line, with the error's first line
--   { op = "notice",    id, text }                /clear, a compaction, Claude Code exiting
--   { op = "debug",     text }                    what a row was (vim.g.claude_code_debug)
-- A row may arrive twice (the mod sends the conversation again when it restarts, and after /resume): an op
-- whose `id` this section has drawn is skipped, so sending again only fills in what is missing. A batch of
-- another session starts a new section; what the buffer held stays above it.
--
-- Everything in a batch is text the model, a tool or a web page wrote. It is only ever put in the buffer; what
-- <CR> does with it is decided here: `http(s)` links go to the browser (asked first when the link's text hid
-- where it leads, or the address is not what it looks like: `why` says which), paths open only when they
-- name a file that exists (asked first when it is outside the directory Claude Code was started in: opening
-- a file starts what the editor has for its kind, a language server that reads the project's own settings
-- included), and nothing is run or expanded.
local M = {}

--- A history with nothing in it.
function M.new() return { lines = {}, seen = {}, tool_line = {} } end

--------------------------------------------------------------------------------------------------- the text

local function one_line(text, max)
  text = (text:match "^[^\r\n]*" or ""):gsub("%c", " ")
  if vim.fn.strchars(text) > max then text = vim.fn.strcharpart(text, 0, max) .. "…" end
  return text
end

--- `text` as a code span, whatever backticks it has in it.
local function code(text)
  local longest = 0
  for run in text:gmatch "`+" do
    longest = math.max(longest, #run)
  end
  local fence = ("`"):rep(longest + 1)
  local pad = (text:sub(1, 1) == "`" or text:sub(-1) == "`") and " " or ""
  return fence .. pad .. text .. pad .. fence
end

--- A path as the history shows it: from Claude Code's directory when it is in there.
local function relative(path, cwd)
  if cwd and vim.startswith(path, cwd .. "/") then return path:sub(#cwd + 2) end
  return path
end

--- What a tool call was about, in one line: the file, the command, the pattern.
function M.describe(name, input, cwd)
  name = type(name) == "string" and one_line(name, 80) or "tool"
  input = type(input) == "table" and input or {}
  local function str(key) return type(input[key]) == "string" and input[key] ~= "" and input[key] or nil end
  local server, tool = name:match "^mcp__(.-)__(.+)$"
  if server then name = server .. ": " .. tool end
  local path = str "file_path" or str "notebook_path" or str "path"
  if str "command" then return name .. " " .. code(one_line(str "command", 100)) end
  if str "pattern" then
    local where = path and (" in " .. code(relative(one_line(path, 200), cwd))) or ""
    return name .. " " .. code(one_line(str "pattern", 100)) .. where
  end
  if path then return name .. " " .. code(relative(one_line(path, 200), cwd)) end
  local url = str "url"
  if url and url:match "^https?://[^%s<>]+$" then return name .. " <" .. url .. ">" end
  if str "query" then return name .. " " .. code(one_line(str "query", 100)) end
  if str "description" then return name .. ": " .. one_line(str "description", 100) end
  if str "skill" then return name .. " " .. code(one_line(str "skill", 100)) end
  return name
end

--- Apply a batch to `state`. Returns what changed: `first`, the index of the first new line, and `changed`,
--- the earlier lines that were rewritten (a tool call that got its result), as a set of indices.
function M.apply(state, batch)
  local lines = state.lines
  local first, changed = #lines + 1, {}

  -- (one line each, whatever a name has in it: a line with a line break in it cannot be put in a buffer)
  local function push(line) lines[#lines + 1] = (line:gsub("\n", " ")) end
  --- An empty line before the next block, unless there is one or nothing above.
  local function gap()
    if #lines > 0 and lines[#lines] ~= "" then push "" end
  end
  local function text_lines(text)
    for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
      push((line:gsub("\r$", "")))
    end
  end
  local function claude_heading()
    if state.turn == "claude" then return end
    gap()
    push "## Claude"
    push ""
    state.turn, state.last = "claude", nil
  end

  if type(batch.cwd) == "string" and batch.cwd ~= "" then
    if state.cwd and state.cwd ~= batch.cwd and state.session == batch.session then
      gap()
      push(("_Now in %s_"):format(vim.fn.fnamemodify(batch.cwd, ":~")))
      state.last = "notice"
    end
    state.cwd = batch.cwd
  end
  if type(batch.session) == "string" and batch.session ~= state.session then
    gap()
    local where = state.cwd and (" · " .. vim.fn.fnamemodify(state.cwd, ":~")) or ""
    push(("# Claude Code · %s%s"):format(os.date "%H:%M", where))
    state.session, state.seen, state.turn, state.last, state.said = batch.session, {}, nil, nil, nil
    state.tool_line = {} -- (a conversation that is resumed draws its tool calls again, in this section)
  end

  for _, op in ipairs(type(batch.ops) == "table" and batch.ops or {}) do
    local kind = type(op) == "table" and op.op
    local text = type(op) == "table" and type(op.text) == "string" and op.text or nil
    local id = type(op) == "table" and type(op.id) == "string" and op.id or nil
    if id and state.seen[id] then
      kind = nil -- drawn before
    elseif id then
      state.seen[id] = true
    end

    if kind == "user" and text then
      -- (a prompt typed while Claude was working can come in by two rows; one typed twice is two prompts)
      if not (op.folded == true and state.said == text) then
        gap()
        -- (a time that is one: this century's, in milliseconds)
        local at = type(op.at) == "number" and op.at > 0 and op.at < 4102444800000 and op.at or nil
        local clock = at and os.date("%H:%M", math.floor(at / 1000))
        push("## You" .. (type(clock) == "string" and (" · " .. clock) or ""))
        push ""
        text_lines(text)
        state.turn, state.last, state.said = "you", "text", text
      end
    elseif kind == "assistant" and text then
      claude_heading()
      gap()
      text_lines(text)
      state.last, state.said = "text", nil
    elseif kind == "tool" and type(op.tool_id) == "string" then
      if not state.tool_line[op.tool_id] then
        claude_heading()
        if state.last ~= "tool" then gap() end
        push("- [ ] " .. M.describe(op.name, op.input, state.cwd))
        state.tool_line[op.tool_id] = #lines
        state.last, state.said = "tool", nil
      end
    elseif kind == "result" and type(op.tool_id) == "string" then
      local i = state.tool_line[op.tool_id]
      if i and lines[i] and lines[i]:sub(1, 5) == "- [ ]" then
        local failed = ""
        if type(op.error) == "string" then
          local why = one_line(op.error, 200)
          failed = " **failed**" .. (why ~= "" and (": " .. why) or "")
        end
        lines[i] = "- [x]" .. lines[i]:sub(6) .. failed
        if i < first then changed[i] = true end
      end
    elseif kind == "notice" and text then
      gap()
      push("_" .. one_line(text, 300) .. "_")
      state.last = "notice"
    elseif kind == "debug" and text then
      gap()
      push("<!-- " .. one_line(text, 300):gsub("%-%-", "- -") .. " -->")
      state.last = "notice"
    end
  end
  return { first = first, changed = changed }
end

-------------------------------------------------------------------------------------- what <CR> opens

--- The link, autolink or code span the position is in, from the syntax tree: with the cursor on a link's text
--- this is still where the link leads. `row` and `col` count from 0.
local function node_target(buf, row, col)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown")
  if not ok or not parser then return nil end
  if not pcall(function() parser:parse { row, row + 1 } end) then return nil end
  local found, node = pcall(vim.treesitter.get_node, { bufnr = buf, pos = { row, col }, ignore_injections = false })
  if not found then return nil end
  local function text_of(n) return vim.treesitter.get_node_text(n, buf) end
  while node do
    local kind = node:type()
    if kind == "inline_link" or kind == "image" then
      local dest, shown
      for child in node:iter_children() do
        local child_kind = child:type()
        if child_kind == "link_destination" then dest = text_of(child) end
        if child_kind == "link_text" or child_kind == "image_description" then shown = text_of(child) end
      end
      if not dest then return nil end
      dest = dest:match "^<(.*)>$" or dest -- `[text](<a path with spaces>)`
      return { text = dest, hidden = shown ~= dest }
    elseif kind == "uri_autolink" then
      return { text = text_of(node):sub(2, -2) }
    elseif kind == "code_span" then
      return { text = vim.trim((text_of(node):gsub("^`+", ""):gsub("`+$", ""))) }
    end
    node = node:parent()
  end
end

--- The run of non-blank characters around `col` in `line`, without the quotes, brackets and punctuation
--- around it.
local function word_at(line, col)
  if line:sub(col + 1, col + 1):match "^%s?$" then return nil end
  local from, to = col + 1, col + 1
  while from > 1 and not line:sub(from - 1, from - 1):match "%s" do
    from = from - 1
  end
  while to < #line and not line:sub(to + 1, to + 1):match "%s" do
    to = to + 1
  end
  local word = line:sub(from, to):gsub("^[`\"'%(%[{<]+", ""):gsub("[`\"'%)%]}>.,;:!?]+$", "")
  return word ~= "" and word or nil
end

local function percent_decode(text)
  return (text:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

--- A file name and where in it: `path:12`, `path:12:3`, `path#L12`, `path#L12C3`, `path#L12-L20`. The first
--- is the text as it is, for a file whose name has such an ending.
local function path_candidates(text)
  local list = { { path = text } }
  local path, line, col = text:match "^(.+):(%d+):(%d+):?$"
  if not path then
    path, line = text:match "^(.+):(%d+):?$"
  end
  if not path then
    path, line, col = text:match "^(.+)#L(%d+)C(%d+)"
  end
  if not path then
    path, line = text:match "^(.+)#L(%d+)"
  end
  if path then list[#list + 1] = { path = path, line = tonumber(line), col = tonumber(col) } end
  return list
end

--- `text` for a question: every character that is not plain ASCII as its number, so that none passes for
--- another (a Cyrillic а for a Latin one) or turns the text around.
function M.spelled(text)
  local out = {}
  for _, char in ipairs(vim.fn.str2list(text, true)) do
    out[#out + 1] = (char >= 32 and char < 127) and string.char(char) or ("<U+%04X>"):format(char)
  end
  return table.concat(out)
end

--- What `text` (a link's destination, a code span, a word) names: a web address, a path, or something that
--- is not opened.
function M.classify(text, hidden)
  if type(text) ~= "string" or text == "" or #text > 4096 or text:find "%c" then return nil end
  local scheme = text:match "^(%a[%w+.-]*)://"
  if scheme then
    scheme = scheme:lower()
    if scheme == "http" or scheme == "https" then
      if text:find "[%s<>\"`\\]" then return { kind = "refused", what = "not a plain web address" } end
      local authority = text:match "^%a+://([^/?#]*)" or ""
      -- an address that reads as another one is asked about, as one a link's text hid, and told why
      local why = {}
      if hidden == true then why[#why + 1] = "the link's text is not this address" end
      if authority:find("@", 1, true) then
        why[#why + 1] = "it has a name before an @: where it leads is what follows the @"
      end
      if text:find "[\128-\255]" then
        why[#why + 1] = "it has characters that are not plain ASCII, which can look like other ones"
      end
      if authority:lower():find("xn--", 1, true) then
        why[#why + 1] = "its host is in another alphabet, spelled with xn--"
      end
      return {
        kind = "url",
        url = text,
        host = authority:match "[^@]*$", -- (where it leads, not the name before an @)
        hidden = #why > 0,
        why = #why > 0 and table.concat(why, "; ") or nil,
      }
    end
    if scheme ~= "file" then return { kind = "refused", what = scheme .. ": links are not opened" } end
    local path = text:match "^%a+://[^/]*(/.*)$"
    if not path then return nil end
    return { kind = "path", candidates = path_candidates(percent_decode(path)) }
  end
  for _, other in ipairs { "javascript:", "data:", "vbscript:", "mailto:", "tel:" } do
    if text:sub(1, #other):lower() == other then
      return { kind = "refused", what = other .. " links are not opened" }
    end
  end
  return { kind = "path", candidates = path_candidates(text) }
end

--- What is under the position in the history buffer: `{ kind = "url", url, host, hidden }`,
--- `{ kind = "path", candidates }`, `{ kind = "refused", what }` or nil. `row` and `col` count from 0.
function M.target(buf, row, col)
  local found = node_target(buf, row, col)
  if found then return M.classify(found.text, found.hidden) end
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  return M.classify(word_at(line, col))
end

--- The file a path target names, looked for in `dirs` in turn: `{ path, line, col, inside }`, or nil and why
--- not. `path` is the file itself (links followed) and `inside` whether that is in `root`, the directory
--- Claude Code was started in. Only a file that exists and is an ordinary one: not a pipe or a device, which
--- would block the editor, not what the kernel shows as files, and never a name Neovim would expand (the
--- name is taken as it is written).
function M.resolve(target, dirs, root)
  local home = vim.uv.os_homedir()
  root = type(root) == "string" and vim.uv.fs_realpath(root) or nil
  local directory, kernel
  for _, candidate in ipairs(target.candidates or {}) do
    local path = candidate.path
    if home and (path == "~" or path:sub(1, 2) == "~/") then path = home .. path:sub(2) end
    local bases = path:sub(1, 1) == "/" and { "" } or dirs
    for _, base in ipairs(bases) do
      if type(base) == "string" then
        local full = vim.fs.normalize(base == "" and path or (base .. "/" .. path), { expand_env = false })
        local stat = vim.uv.fs_stat(full)
        local real = stat and stat.type == "file" and vim.uv.fs_realpath(full)
        if real and (real:find "^/proc/" or real:find "^/sys/" or real:find "^/dev/") then
          kernel = kernel or real
        elseif real then
          local inside = root ~= nil and root ~= "/" and vim.startswith(real, root .. "/")
          return { path = real, line = candidate.line, col = candidate.col, inside = inside }
        end
        if stat and stat.type == "directory" then directory = directory or full end
      end
    end
  end
  if kernel then return nil, "Not opened: " .. one_line(kernel, 200) .. " is not a file on a disk" end
  if directory then return nil, vim.fn.fnamemodify(directory, ":~") .. " is a directory" end
  local name = target.candidates and target.candidates[1] and target.candidates[1].path or ""
  return nil, "No file: " .. one_line(name, 200)
end

return M
