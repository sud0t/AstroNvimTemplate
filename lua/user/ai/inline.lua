-- <Leader>Ai: prompt the AI (the provider chosen with <Leader>As: the local model, Claude or another provider's
-- model) from inside a buffer.
--   Normal mode: asks for an instruction ("a function that parses an ISO date") and writes the answer below the
--   cursor line (in its place when the line is empty).
--   Visual mode: the instruction is about the selected lines ("handle the empty list", "translate to German"),
--   and the answer replaces them.
-- The answer appears in the buffer as the model writes it. `u` undoes all of it in one step (which also brings a
-- replaced selection back); <Leader>Ai while it is still writing cancels.
-- The model sees the file around the cursor, so it can use what is defined there.
local M = {}

-- How much of the file goes along. The local model has an 8k context (~3 characters per token of code); the
-- providers' models (`claude`: Claude and every other provider) take the whole file in practice.
local limits = {
  ollama = { before = 9000, after = 3000, selection = 8000, answer = 1024 },
  claude = { before = 150000, after = 50000, selection = 150000, answer = 16000 },
}

local system_prompt = [[
You are an editing tool inside a text editor. You get a file, a position or a selection in it, and an instruction.

Rules:
- Reply with exactly the text that goes into the file, inside one code block. No explanation before or after it.
- Write in the language and style of the file, and use what the file already defines.
- Do not repeat the code around the position. Do not add usage examples, tests or "main" code unless asked.
- Indent the first line and all others so that the text fits where it goes.]]

local running = {} -- bufnr -> request

local function notify(msg, level) vim.notify(msg, level or vim.log.levels.INFO, { title = "AI inline" }) end

--- The text to put into the buffer out of an answer (also a partial one): what is inside its code block.
local function extract(text)
  text = text:gsub("<think>.-</think>", ""):gsub("\r", "")
  local lines = vim.split(text, "\n", { plain = true })
  local open
  for i, line in ipairs(lines) do
    if line:find "^%s*```" then
      open = i
      break
    end
  end
  if not open then
    -- no code block (yet): while the first line is still coming in it may be the start of a fence
    if #lines == 1 and lines[1]:find "^%s*`*$" then return {} end
    text = text:gsub("^\n+", ""):gsub("%s+$", "")
    return text == "" and {} or vim.split(text, "\n", { plain = true })
  end
  local out = {}
  for i = open + 1, #lines do
    if lines[i]:find "^%s*```%s*$" then break end
    out[#out + 1] = lines[i]
  end
  -- (a partial last line may be the closing fence arriving)
  if out[#out] and out[#out]:find "^%s*`+$" then out[#out] = nil end
  while out[#out] and out[#out]:find "^%s*$" do
    out[#out] = nil
  end
  return out
end

local function indent_of(line) return line:match "^%s*" end

--- Shift `lines` so that their first line has the indentation `target` (the model often starts at column 0).
local function reindent(lines, target)
  local first
  for _, line in ipairs(lines) do
    if line:find "%S" then
      first = indent_of(line)
      break
    end
  end
  if not first or first == target then return lines end
  local out = {}
  for i, line in ipairs(lines) do
    if not line:find "%S" then
      out[i] = ""
    elseif #first < #target then
      out[i] = target:sub(1, #target - #first) .. line
    elseif vim.startswith(line, first) then
      out[i] = target .. line:sub(#first + 1)
    else
      out[i] = line
    end
  end
  return out
end

local function tail(text, max)
  if #text <= max then return text end
  return (text:sub(-max):gsub("^[^\n]*\n", ""))
end

local function head(text, max)
  if #text <= max then return text end
  return (text:sub(1, max):gsub("\n[^\n]*$", ""))
end

local function block(ft, text) return ("`````%s\n%s\n`````"):format(ft, text) end

--- Start writing. `first`, `last`: the selected lines (0-based, inclusive), or nil to insert at the cursor line.
local function start(bufnr, instruction, first, last, cursor_row)
  local ai = require "user.ai"
  local limit = ai.is_local() and limits.ollama or limits.claude
  local max_before, max_after, max_selection = limit.before, limit.after, limit.selection
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local ft = vim.bo[bufnr].filetype
  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
  local where = (name ~= "" and ("File `%s`"):format(name) or "A new file") .. (ft ~= "" and (" (%s)"):format(ft) or "")
  local join = function(from, to) return table.concat(vim.list_slice(lines, from, to), "\n") end

  local region_first, region_last, target_indent, parts
  if first then
    local selection = join(first + 1, last + 1)
    if #selection > max_selection then
      return notify(
        ("The selection is too long for the local model (%d characters)"):format(#selection),
        vim.log.levels.WARN
      )
    end
    region_first, region_last = first, last + 1
    for i = first + 1, last + 1 do
      if lines[i]:find "%S" then
        target_indent = indent_of(lines[i])
        break
      end
    end
    parts = { where .. "." }
    local before, after = tail(join(1, first), max_before - #selection), head(join(last + 2, #lines), max_after)
    if before:find "%S" then vim.list_extend(parts, { "", "The code before the selection:", block(ft, before) }) end
    vim.list_extend(parts, { "", ("The selected lines (%d to %d):"):format(first + 1, last + 1), block(ft, selection) })
    if after:find "%S" then vim.list_extend(parts, { "", "The code after the selection:", block(ft, after) }) end
    vim.list_extend(parts, {
      "",
      "Instruction: " .. instruction,
      "",
      "Reply with the text that replaces the selected lines, and nothing else.",
    })
  else
    -- an empty line is the place to write; otherwise the answer goes below the cursor line
    local empty = not lines[cursor_row + 1]:find "%S"
    region_first = empty and cursor_row or cursor_row + 1
    region_last = cursor_row + 1
    if empty then target_indent = lines[cursor_row + 1] ~= "" and lines[cursor_row + 1] or nil end
    local before = tail(join(1, empty and cursor_row or cursor_row + 1), max_before)
    local after = head(join(cursor_row + 2, #lines), max_after)
    parts = { where .. "." }
    if before:find "%S" then
      vim.list_extend(parts, { "", "The code before the insertion point:", block(ft, before) })
    end
    if after:find "%S" then vim.list_extend(parts, { "", "The code after the insertion point:", block(ft, after) }) end
    vim.list_extend(parts, {
      "",
      "Instruction: " .. instruction,
      "",
      "Reply with the new text to insert at the insertion point, and nothing else.",
    })
  end

  local request = {
    system = system_prompt,
    messages = { { role = "user", content = table.concat(parts, "\n") } },
    max_tokens = limit.answer,
    ollama = { options = { num_ctx = 8192, temperature = 0.2 } },
  }
  local is_local = ai.is_local()
  local function release_gpu()
    if is_local then require("user.ai.ollama").unload_spilled(ai.local_model()) end
  end

  local stream = require "user.ai.stream"
  local region = stream.region(bufnr, region_first, region_last)
  local written = false
  local function show(text)
    local out = extract(text)
    if #out == 0 and not written then return end -- nothing to show yet: leave the buffer as it is
    if target_indent then out = reindent(out, target_indent) end
    region:set(out)
    written = true
  end

  notify(("Writing with %s... (<Leader>Ai cancels)"):format(ai.label()))
  running[bufnr] = ai.chat(request, show, function(answer, info)
    running[bufnr] = nil
    release_gpu()
    if info.error then
      region:release()
      return notify("Request failed: " .. info.error, vim.log.levels.ERROR)
    end
    show(answer)
    local from, to = region:range()
    region:release()
    if not written then return notify("The model gave no text", vim.log.levels.WARN) end
    notify(
      ("Done: %d line%s%s. u undoes it."):format(
        to - from,
        to - from == 1 and "" or "s",
        info.done_reason == "length" and " (cut off at the length limit)" or ""
      ),
      info.done_reason == "length" and vim.log.levels.WARN or vim.log.levels.INFO
    )
  end)
end

--- <Leader>Ai (normal and visual mode)
function M.run()
  local bufnr = vim.api.nvim_get_current_buf()
  if running[bufnr] then
    running[bufnr].cancel()
    running[bufnr] = nil
    return notify "Cancelled (u undoes what was written)"
  end
  if not vim.bo[bufnr].modifiable then return notify("Buffer is not modifiable", vim.log.levels.WARN) end

  local first, last
  if vim.fn.mode():match "^[vV\22]" then
    first, last = vim.fn.line "v" - 1, vim.fn.line "." - 1
    if first > last then
      first, last = last, first
    end
    vim.cmd.normal { "\27", bang = true }
  end
  local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1

  vim.ui.input({ prompt = first and "AI, about the selection: " or "AI, write here: " }, function(instruction)
    instruction = instruction and vim.trim(instruction) or ""
    if instruction == "" then return end
    if not vim.api.nvim_buf_is_loaded(bufnr) or running[bufnr] then return end
    start(bufnr, instruction, first, last, cursor_row)
  end)
end

M._extract, M._reindent = extract, reindent -- for tests

return M
