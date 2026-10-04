-- <Leader>AR: review the buffer (or the visual selection) with a local model and apply its fixes in place.
-- The model (qwen3:4b-instruct, fits entirely in the T1000's VRAM) answers with whole fixed functions; each one
-- replaces its function in the buffer and is shown as an inline diff (CodeCompanion's diff UI), one fix at a
-- time, with the reason in the banner:
--   g2  accept this fix      g3  reject it (restores the code)      g1  accept this and all remaining fixes
-- <Leader>AR while the model is still answering cancels the review.
local M = {}

local model = "qwen3:4b-instruct"
local url = "http://localhost:11434/api/chat"
-- fits the model's 6k context (~3.5 characters per token) next to the prompt and the answer
local max_chars = 15000

local system_prompt = [[
You review code for an experienced programmer. Output only concrete fixes to the given code.

Look for, in this order:
1. security: SQL/shell/path injection, unsafe deserialization, secrets in code
2. bugs: off-by-one, wrong conditions, crashes on nil/None or empty input, division by zero, mutable default arguments
3. resource leaks: files, sockets or connections that are never closed
4. needless work: repeated computation, quadratic loops with a simple linear fix

Only report a problem if you can say which input makes it fail or what it costs. Never:
- explain language basics or describe what the code does
- suggest comments, docstrings, type hints, logging, tests, or renaming
- give general advice ("consider", "make sure", "it is good practice")
- remove code because it looks "unnecessary"
- write an introduction or a summary

Reply with up to 5 fixes, most important first. Each fix is these three parts, in this order, before the next fix starts:

**`<function name>`**: <one sentence: what fails and when>
> `<the offending line, copied exactly>`
````<language>
<the complete fixed function: every line of it, changed or not, with its original indentation>
````

Give each fix its own code block containing only that one function; never output the whole file. Change only the lines needed for the fix. For code outside any function, use `<module>` as the name and give the fixed lines, starting and ending with an unchanged line.
If the code has none of these problems, reply with just "No changes needed."]]

local job -- running request
local session -- fixes waiting for accept/reject

local function notify(msg, level) vim.notify(msg, level or vim.log.levels.INFO, { title = "AI review", id = "ai_review" }) end

---------------------------------------------------------------------------------------------------- parsing

local function is_function(node)
  local t = node:type()
  return (t:find "function" or t:find "method")
    and (t:match "_definition$" or t:match "_declaration$" or t:match "_item$")
end

--- name of a function node; `source` is a buffer or a string
local function node_name(node, source)
  local n, d = node:field("name")[1], node
  while not n do -- C: the name is nested in (pointer_)declarator -> function_declarator -> identifier
    d = d:field("declarator")[1]
    if not d then return end
    if d:type():find "identifier" then n = d end
  end
  return vim.treesitter.get_node_text(n, source):match "[%w_]+$"
end

--- outermost functions in a code string (methods count, functions nested in functions do not):
--- { name, code = lines } with decorators included
local function split_functions(code, lang)
  local ok, parser = pcall(vim.treesitter.get_string_parser, code, lang)
  if not ok or not parser then return {} end
  local ok_parse, trees = pcall(parser.parse, parser)
  if not ok_parse or not trees[1] then return {} end
  local lines, out = vim.split(code, "\n"), {}
  local function walk(node)
    for child in node:iter_children() do
      local name = is_function(child) and node_name(child, code)
      if name then
        local outer = child:parent() and child:parent():type() == "decorated_definition" and child:parent() or child
        local srow, _, erow, ecol = outer:range()
        table.insert(out, { name = name, code = vim.list_slice(lines, srow + 1, ecol == 0 and erow or erow + 1) })
      else
        walk(child)
      end
    end
  end
  walk(trees[1]:root())
  return out
end

--- Fixes in the model's answer: { label, name, reason, offending, code }.
--- Small models do not always keep each fix next to its code (some send all the reasons, then one block with the
--- whole file), so the code blocks are split into functions and matched to the reasons by function name.
local function parse(text, lang)
  text = text:gsub("<think>.-</think>", "")
  local header = "%*%*`?([^`*\n]+)`?%*%*:?[ \t]*([^\n]*)"
  local reasons, items = {}, {} -- reasons by function name; headers and code blocks in answer order
  local pos = 1
  while true do
    local hs, he, label, reason = text:find(header, pos)
    local fs, fe, fence = text:find("\n[ \t]*(```+)[^\n]*\n", pos)
    if not hs and not fs then break end
    if hs and (not fs or hs < fs) then
      label = vim.trim(label)
      local h = {
        label = label,
        name = label:gsub("%b()", ""):match "[%w_]+$",
        reason = vim.trim(reason),
        offending = text:sub(he, (text:find("\n%s*\n", he) or #text)):match ">[ \t]*`(.-)`",
      }
      table.insert(items, h)
      if h.name then reasons[h.name] = reasons[h.name] or {} table.insert(reasons[h.name], h) end
      pos = he + 1
    else
      local cs, ce = text:find("\n[ \t]*" .. fence, fe)
      if not cs then break end -- answer cut off inside the code
      table.insert(items, { code = text:sub(fe + 1, cs - 1) })
      pos = ce + 1
    end
  end

  local fixes, seen, last_header = {}, {}, nil
  for _, item in ipairs(items) do
    if not item.code then
      last_header = item
    else
      local funcs = split_functions(item.code, lang)
      if #funcs == 0 then -- code outside functions: belongs to the reason right before it
        local h = last_header or {}
        table.insert(fixes, {
          label = h.label or "<module>",
          reason = h.reason or "",
          offending = h.offending,
          code = vim.split(item.code, "\n"),
        })
      end
      for _, f in ipairs(funcs) do
        local hs = reasons[f.name] or (#funcs == 1 and last_header and { last_header }) or {}
        if not seen[f.name] then
          seen[f.name] = true
          local h = hs[1] or {}
          table.insert(fixes, {
            label = h.label or f.name,
            name = f.name,
            reason = table.concat(vim.tbl_map(function(x) return x.reason end, hs), "; "),
            offending = h.offending,
            code = f.code,
          })
        end
      end
      last_header = nil
    end
  end
  return fixes
end

---------------------------------------------------------------------------------------------------- locating

local function first_code_line(lines)
  for _, l in ipairs(lines) do
    if l:match "%S" and not l:match "^%s*@" then return l end
  end
  return ""
end

--- line range (0-based, end exclusive) of a function node, including decorators when the fix has them
local function node_range(node, fix)
  local parent = node:parent()
  if parent and parent:type() == "decorated_definition" and vim.trim(fix.code[1] or ""):sub(1, 1) == "@" then
    node = parent
  end
  local srow, _, erow, ecol = node:range()
  return srow, ecol == 0 and erow or erow + 1
end

--- function nodes overlapping rows [first, last]
local function functions(bufnr, first, last)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then return {} end
  local out = {}
  local function walk(node)
    for child in node:iter_children() do
      local srow, _, erow = child:range()
      if erow >= first and srow <= last then
        if is_function(child) then table.insert(out, child) end
        walk(child)
      end
    end
  end
  walk(parser:parse()[1]:root())
  return out
end

local function find_line(lines, wanted, from, to)
  wanted = vim.trim(wanted or "")
  if wanted == "" then return end
  for i = from, math.min(to, #lines) do
    if vim.trim(lines[i]) == wanted then return i end
  end
end

--- rows [srow, erow) in the buffer that the fix replaces, or nil
local function locate(bufnr, lines, fix, range)
  local first, last = range[1], math.min(range[2], #lines - 1)
  local nodes = functions(bufnr, first, last)
  local offending = find_line(lines, fix.offending, first + 1, last + 1)

  -- the fix has to be a whole function: its first line names it
  local function whole(name) return name and first_code_line(fix.code):find(name, 1, true) end

  -- 1. the function the model named (the one with the offending line if several share the name)
  if fix.name and whole(fix.name) then
    local match
    for _, node in ipairs(nodes) do
      if node_name(node, bufnr) == fix.name then
        local srow, erow = node_range(node, fix)
        if not match or (offending and offending - 1 >= srow and offending - 1 < erow) then match = { srow, erow } end
      end
    end
    if match then return match[1], match[2] end
  end

  -- 2. the innermost function around the offending line
  if offending then
    local inner
    for _, node in ipairs(nodes) do
      local srow, _, erow = node:range()
      if offending - 1 >= srow and offending - 1 <= erow then inner = node end
    end
    if inner and whole(node_name(inner, bufnr)) then return node_range(inner, fix) end
  end

  -- 3. plain lines: anchored by the fix's first and last line, which the prompt asks to leave unchanged
  local code = vim.tbl_filter(function(l) return l:match "%S" end, fix.code)
  if #code == 0 then return end
  local s = find_line(lines, code[1], first + 1, last + 1)
  local e = s and find_line(lines, code[#code], s, math.min(last + 1, s + #fix.code + 20))
  if e then return s - 1, e end
end

--- the fix's lines, shifted to the indentation of the code they replace
local function reindent(code, target)
  local from = (first_code_line(code):match "^%s*" or "")
  local to = (first_code_line(target):match "^%s*" or "")
  local tabs = vim.iter(target):any(function(l) return l:match "^\t" end)
  local sw = vim.fn.shiftwidth()
  local out = {}
  for i, l in ipairs(code) do
    if l:match "%S" then
      if l:sub(1, #from) == from then l = to .. l:sub(#from + 1) end
      if tabs then
        l = l:gsub("^(\t*)( +)", function(t, s) return t .. ("\t"):rep(math.floor(#s / sw)) .. (" "):rep(#s % sw) end)
      end
    else
      l = ""
    end
    out[i] = l
  end
  -- drop blank lines the model added around the code
  while out[1] == "" do table.remove(out, 1) end
  while out[#out] == "" do table.remove(out) end
  return out
end

---------------------------------------------------------------------------------------------------- applying

local function finish()
  local s = session
  session = nil
  if not s then return end
  local msg = ("%d of %d fixes applied"):format(s.accepted, #s.fixes)
  if #s.skipped > 0 then msg = msg .. "\nSkipped (could not place in the buffer):\n" .. table.concat(s.skipped, "\n") end
  notify(msg, #s.skipped > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
end

local show_next

local function show_fix(fix)
  local s, bufnr = session, session.bufnr
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local srow, erow = locate(bufnr, lines, fix, s.range)
  if not srow then
    table.insert(s.skipped, ("  %s: %s"):format(fix.label, fix.reason))
    return show_next()
  end
  local new = reindent(fix.code, vim.list_slice(lines, srow + 1, erow))
  if vim.deep_equal(new, vim.list_slice(lines, srow + 1, erow)) then return show_next() end
  local to_lines = vim.list_extend(vim.list_slice(lines, 1, srow), new)
  vim.list_extend(to_lines, vim.list_slice(lines, erow + 1))
  local delta = #new - (erow - srow)

  if s.accept_all then
    vim.api.nvim_buf_set_lines(bufnr, srow, erow, false, new)
    s.accepted, s.range[2] = s.accepted + 1, s.range[2] + delta
    return show_next()
  end

  local keys = require("codecompanion.config").interactions.shared.keymaps
  local reason = fix.reason ~= "" and fix.reason or "(no reason given)"
  local label = ("Fix %d/%d `%s`: %s"):format(s.index, #s.fixes, fix.label, reason)
  notify(label)
  require("codecompanion.helpers").show_diff {
    bufnr = bufnr,
    from_lines = lines,
    to_lines = to_lines,
    diff_id = math.random(10000000),
    inline = true,
    banner = ("%s  │  %s accept  %s reject  %s accept all"):format(
      label,
      keys.accept_change.modes.n,
      keys.reject_change.modes.n,
      keys.always_accept.modes.n
    ),
    keymaps = {
      on_accept = function()
        s.accepted, s.range[2] = s.accepted + 1, s.range[2] + delta
        vim.schedule(show_next) -- after the diff UI has cleaned up
      end,
      on_reject = function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.schedule(show_next)
      end,
      on_always_accept = function() s.accept_all = true end, -- runs right after on_accept
    },
  }
end

show_next = function()
  local s = session
  if not s then return end
  if not vim.api.nvim_buf_is_valid(s.bufnr) then
    session = nil
    return
  end
  s.index = s.index + 1
  local fix = s.fixes[s.index]
  if not fix then return finish() end
  show_fix(fix)
end

local function start(bufnr, fixes, range)
  -- drop "fixes" that change nothing (small models often return untouched functions too)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  fixes = vim.tbl_filter(function(fix)
    local srow, erow = locate(bufnr, lines, fix, range)
    return not srow or not vim.deep_equal(reindent(fix.code, vim.list_slice(lines, srow + 1, erow)), vim.list_slice(lines, srow + 1, erow))
  end, fixes)
  if #fixes == 0 then return notify "No changes needed." end
  session = { bufnr = bufnr, fixes = fixes, range = range, index = 0, accepted = 0, skipped = {} }
  -- the diff is shown in the buffer's window; wait until the buffer is visible again
  if vim.fn.bufwinid(bufnr) == -1 then
    notify(("%d fixes ready, shown when you return to %s"):format(#fixes, vim.fn.bufname(bufnr)))
    vim.api.nvim_create_autocmd("BufWinEnter", { buffer = bufnr, once = true, callback = vim.schedule_wrap(show_next) })
    return
  end
  require "codecompanion" -- load the plugin (and its config) before using its diff UI
  show_next()
end

--- apply the model's answer to rows [range[1], range[2]] (0-based) of the buffer
function M.apply(bufnr, answer, range)
  if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local ft = vim.bo[bufnr].filetype
  local fixes = parse(answer, vim.treesitter.language.get_lang(ft) or ft)
  if #fixes == 0 then return notify "No changes needed." end
  start(bufnr, fixes, range)
end

---------------------------------------------------------------------------------------------------- request

function M.run()
  if job then
    job:kill "sigterm"
    job = nil
    return notify "Review cancelled"
  end
  if session then return notify("Finish the fixes on screen first (accept or reject)", vim.log.levels.WARN) end

  local bufnr = vim.api.nvim_get_current_buf()
  if not vim.bo[bufnr].modifiable then return notify("Buffer is not modifiable", vim.log.levels.WARN) end
  local first, last = 0, vim.api.nvim_buf_line_count(bufnr) - 1
  local visual = vim.fn.mode():match "^[vV\22]"
  if visual then
    first, last = vim.fn.line "v" - 1, vim.fn.line "." - 1
    if first > last then first, last = last, first end
    vim.cmd.normal { "\27", bang = true }
  end
  local code = table.concat(vim.api.nvim_buf_get_lines(bufnr, first, last + 1, false), "\n")
  if #code > max_chars then
    return notify(
      ("Too large for the local model (%d chars, max ~%d). Select a region and try again."):format(#code, max_chars),
      vim.log.levels.WARN
    )
  end

  local ft, name = vim.bo[bufnr].filetype, vim.fn.expand "%:."
  local scope = visual and ("lines %d-%d of `%s`"):format(first + 1, last + 1, name) or ("the file `%s`"):format(name)
  local body = vim.json.encode {
    model = model,
    stream = false,
    keep_alive = "0s", -- unload as soon as it answers, handing the GPU back to completion
    messages = {
      { role = "system", content = system_prompt },
      { role = "user", content = ("Review %s:\n\n````%s\n%s\n````"):format(scope, ft, code) },
    },
    options = {
      num_ctx = 6144, -- KV cache is ~75KB/token here; 8k leaves too little VRAM headroom
      temperature = 0.1, -- stick to the format and the code
      num_gpu = 99, -- all layers on the GPU (Ollama's own estimate only places half of them)
      num_predict = 1024, -- hard cap on answer length; 5 fixed functions fit easily
    },
  }

  -- the review model only fits on the GPU on its own; completion reloads afterwards (~1s, once)
  require("user.ollama").make_room_for(model)
  notify(("Reviewing %s with %s… (<Leader>AR cancels)"):format(visual and "selection" or "buffer", model))
  local this
  this = vim.system({ "curl", "-s", "--max-time", "600", url, "-d", "@-" }, { stdin = body, text = true }, function(res)
    vim.schedule(function()
      if job ~= this then return end -- cancelled
      job = nil
      require("user.ollama").unload_spilled(model)
      local ok, data = pcall(vim.json.decode, res.stdout or "")
      if res.code ~= 0 or not ok or type(data) ~= "table" or not data.message then
        local err = ok and type(data) == "table" and data.error or res.stderr
        return notify("Request failed: " .. (err ~= "" and err or "is Ollama running?"), vim.log.levels.ERROR)
      end
      M.apply(bufnr, data.message.content or "", { first, last })
    end)
  end)
  job = this
end

return M
