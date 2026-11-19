-- What <CR> opens in the Claude Code buffer (lua/user/ai/claude_code.lua): the web address or the file the
-- cursor is on, read from the rows of the terminal. Nothing here touches a window or a job;
-- tests/claude_code.lua runs it as it is.
--
-- Everything on those rows is text the model, a tool or a web page wrote. It is only ever read, and what is
-- done with it is decided here and in `open_target` there: an `http(s)` address goes to the browser (asked
-- first when it reads as another one, `why`, or had to be put together from more than one row, `joined`), a
-- path opens only when it names a file that exists (asked first when that is outside the directory Claude
-- Code was started in), and nothing is run or expanded.
local M = {}

local function one_line(text, max)
  text = (text:match "^[^\r\n]*" or ""):gsub("%c", " ")
  if vim.fn.strchars(text) > max then text = vim.fn.strcharpart(text, 0, max) .. "…" end
  return text
end

------------------------------------------------------------------------------------------------- the rows

-- A terminal has no long lines. An address or a path that is longer than a row has room for is broken where
-- the row ends and goes on in the next one, under that row's indentation. What is told apart from a row
-- that merely ends with an address, and a next row that starts with another word:
--   - a row something is broken in reaches as far to the right as any row of its paragraph (the rows
--     around it up to the next empty one; rows keep the width they were printed at, so how wide the window
--     is now says nothing about them)
--   - the pieces together are longer than that row has room for: what fits is not broken, it is moved
--   - a piece that starts an address of its own (`https://`) goes on from nothing
local slack = 2 -- columns a broken row may stay short of the one that reaches furthest
local max_rows = 4 -- rows one address is put together from

--- Where the text of a row is: its first and last byte, without the indentation and the sides of a box.
local function content(line)
  local lead = line:match "^%s*│%s*" or line:match "^%s*"
  local trail = line:match "%s*│%s*$" or line:match "%s*$"
  local from, to = #lead + 1, #line - #trail
  if from > to then return nil end
  return from, to
end

--- How far the text of a row reaches to the right, in columns: 0 for a rule or the edge of a box, which
--- are as wide as the window whatever is said in it.
local function reach(line)
  local _, last = content(line)
  if not last or line:gsub("\226[\148\149][\128-\191]", ""):match "^%s*$" then return 0 end
  return vim.fn.strdisplaywidth(line:sub(1, last))
end

--- `word` without the quotes, brackets and punctuation around it (a bracket that closes one of its own
--- stays: `…/Vim_(text_editor)`).
local function bare(word)
  word = word:gsub("^[`\"'%(%[{<]+", "")
  while true do
    local last = word:sub(-1)
    local opened, closed = select(2, word:gsub("%(", "")), select(2, word:gsub("%)", ""))
    if not (last:match "[`\"'%]}>.,;:!?]" or (last == ")" and closed > opened)) then break end
    word = word:sub(1, -2)
  end
  return word
end

--- What the cursor is on, as the texts to try in turn: `{ { text, joined }, … }`, or nil on a blank.
--- `lines` are rows of the buffer around the cursor's, `index` the one the cursor is in (from 1) and `col`
--- the cursor's byte in it (from 0). A text put together from more than one row is tried before what is on
--- the cursor's row alone, and says so (`joined`); and what a tool was called with, `Read(src/x.lua)`,
--- before the whole of it.
function M.at(lines, index, col)
  local line = lines[index]
  local at = type(col) == "number" and col + 1 or 0
  local first, last = content(type(line) == "string" and line or "")
  if not first or at < first or at > last or line:sub(at, at):match "%s" then return nil end
  local from, to = at, at
  while from > first and not line:sub(from - 1, from - 1):match "%s" do
    from = from - 1
  end
  while to < last and not line:sub(to + 1, to + 1):match "%s" do
    to = to + 1
  end
  local word = line:sub(from, to)

  -- how far the rows of this paragraph reach
  local furthest = reach(line)
  for step = -1, 1, 2 do
    local i = index + step
    while lines[i] and reach(lines[i]) > 0 do
      furthest, i = math.max(furthest, reach(lines[i])), i + step
    end
  end
  --- Whether row `i` is one of the paragraph that is filled to its end.
  local function full(i) return lines[i] ~= nil and reach(lines[i]) >= math.max(furthest - slack, 1) end
  local function starts_address(text) return text:match "^%a[%w+.-]*://" ~= nil end

  -- the rows it goes on in, then the rows it came from
  local whole, rows, top = word, 1, index
  local i, open = index, to == last
  while open and rows < max_rows and full(i) and lines[i + 1] and reach(lines[i + 1]) > 0 do
    local next_first, next_last = content(lines[i + 1])
    local piece = lines[i + 1]:sub(next_first, next_last):match "^%S+"
    if starts_address(piece) then break end
    whole, rows, i = whole .. piece, rows + 1, i + 1
    open = next_first + #piece - 1 == next_last
  end
  i, open = index, from == first and not starts_address(word)
  while open and rows < max_rows and full(i - 1) do
    local prev_first, prev_last = content(lines[i - 1])
    local piece = lines[i - 1]:sub(prev_first, prev_last):match "%S+$"
    whole, rows, i, top = piece .. whole, rows + 1, i - 1, i - 1
    open = prev_last - #piece + 1 == prev_first and not starts_address(piece)
  end
  if rows > 1 then
    local room = reach(lines[top]) - vim.fn.strdisplaywidth(lines[top]:sub(1, content(lines[top]) - 1))
    if vim.fn.strdisplaywidth(whole) <= room then rows = 1 end
  end

  local found, seen = {}, {}
  local function add(text, joined)
    for _, form in ipairs { text:match "^[%a_][%w_]*%((.+)%)[.,;:]?$" or "", text } do
      form = bare(form)
      if form ~= "" and not seen[form] then
        seen[form] = true
        found[#found + 1] = { text = form, joined = joined }
      end
    end
  end
  if rows > 1 then add(whole, true) end
  add(word, false)
  return #found > 0 and found or nil
end

-------------------------------------------------------------------------------------------- what it names

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

--- What `text` names: a web address, a path, or something that is not opened.
function M.classify(text)
  if type(text) ~= "string" or text == "" or #text > 4096 or text:find "%c" then return nil end
  local scheme = text:match "^(%a[%w+.-]*)://"
  if scheme then
    scheme = scheme:lower()
    if scheme == "http" or scheme == "https" then
      if text:find '[%s<>"`\\]' then return { kind = "refused", what = "not a plain web address" } end
      local authority = text:match "^%a+://([^/?#]*)" or ""
      -- an address that reads as another one is asked about, and told why
      local why = {}
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
