-- What the AI features share to show an answer while it is being written, token by token:
--   M.chat     a streaming request to Ollama's chat endpoint
--   M.run      a command whose output is the answer as it grows (the other providers' backends)
--   M.region   a range of lines in a buffer that is rewritten as the answer grows (one undo step in the end)
--   M.float    a small window in the corner showing the answer live, for answers that are not written
--              into the buffer as they are (the review: its fixes are applied once the answer is complete)
local M = {}

local url = "http://localhost:11434/api/chat"

--- Send `request` (an Ollama /api/chat body) and stream the answer.
--- `on_text(text)` gets the whole answer so far, each time it has grown; `on_done(text, info)` is called once at
--- the end, with `info.error` (a string, when the request failed) and `info.done_reason`. Both run on the main
--- loop. Returns a handle: `handle.cancel()` stops the request, and no callback runs after it.
function M.chat(request, on_text, on_done)
  request = vim.tbl_extend("force", request, { stream = true })
  local text, pending, info = "", "", {}
  local cancelled, queued = false, false

  local function take(line)
    if line == "" then return end
    local ok, data = pcall(vim.json.decode, line)
    if not ok or type(data) ~= "table" then return end
    if data.error then info.error = tostring(data.error) end
    if data.done_reason then info.done_reason = data.done_reason end
    local piece = vim.tbl_get(data, "message", "content")
    if type(piece) == "string" and piece ~= "" then
      text = text .. piece
      if not queued then
        queued = true
        vim.schedule(function()
          queued = false
          if not cancelled then on_text(text) end
        end)
      end
    end
  end

  local job = vim.system({ "curl", "-sN", "--max-time", "600", url, "-d", "@-" }, {
    stdin = vim.json.encode(request),
    text = true,
    stdout = function(_, chunk)
      if not chunk then return end
      pending = pending .. chunk
      while true do
        local nl = pending:find("\n", 1, true)
        if not nl then break end
        take(pending:sub(1, nl - 1))
        pending = pending:sub(nl + 1)
      end
    end,
  }, function(res)
    take(pending)
    vim.schedule(function()
      if cancelled then return end
      if not info.error and res.code ~= 0 then info.error = "no answer from Ollama (is it running?)" end
      on_done(text, info)
    end)
  end)

  return {
    cancel = function()
      cancelled = true
      job:kill "sigterm"
    end,
  }
end

--- Run `cmd` (with `opts` for vim.system: stdin, cwd) and hand every complete line of its output to
--- `take(state, line)`: `state.add(piece)` appends to the answer, `state.info` is what `on_done` gets with it.
--- `finish(state, res)` decides what the end of the process means. `on_text`, `on_done` and the handle are as
--- in M.chat. `opts.cleanup()` runs when the process has ended, also after a cancel (which skips `finish`).
--- What the backends that are not Ollama share (lua/user/ai/claude.lua, lua/user/ai/openai.lua).
function M.run(cmd, opts, take, on_text, finish, on_done)
  local state = { text = "", info = {} }
  local pending, cancelled, queued = "", false, false
  local cleanup = opts.cleanup
  opts.cleanup = nil

  function state.add(piece)
    state.text = state.text .. piece
    if queued then return end
    queued = true
    vim.schedule(function()
      queued = false
      if not cancelled then on_text(state.text) end
    end)
  end

  opts.text = true
  opts.stdout = function(_, chunk)
    if not chunk then return end
    pending = pending .. chunk
    while true do
      local nl = pending:find("\n", 1, true)
      if not nl then break end
      take(state, pending:sub(1, nl - 1))
      pending = pending:sub(nl + 1)
    end
  end
  local started, job = pcall(vim.system, cmd, opts, function(res)
    take(state, pending)
    vim.schedule(function()
      if cleanup then pcall(cleanup) end
      if cancelled then return end
      finish(state, res)
      on_done(state.text, state.info)
    end)
  end)
  if not started then
    -- (the program is not installed: nothing ran, so nothing will clean up later)
    if cleanup then pcall(cleanup) end
    error(job, 0)
  end
  return {
    cancel = function()
      cancelled = true
      job:kill "sigterm"
    end,
  }
end

--- A line of JSON as a table, or nil.
function M.decode(line)
  if line == "" then return end
  local ok, data = pcall(vim.json.decode, line)
  if ok and type(data) == "table" then return data end
end

local ns = vim.api.nvim_create_namespace "user_ai_stream"

--- The lines `first` to `last` (0-based, end-exclusive; an empty range inserts) of a buffer, to be rewritten with
--- `region:set(lines)` as often as needed. It follows edits made above it meanwhile, and all the rewrites
--- together are one undo step.
function M.region(bufnr, first, last)
  local region = { count = last - first, written = false }
  local mark = vim.api.nvim_buf_set_extmark(bufnr, ns, first, 0, { right_gravity = false })

  function region:row()
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, mark, {})
    return pos[1] or first
  end

  function region:set(lines)
    if not vim.api.nvim_buf_is_loaded(bufnr) then return end
    local row = self:row()
    vim.api.nvim_buf_call(bufnr, function()
      if self.written then pcall(vim.cmd.undojoin) end -- (fails right after an undo: then it is a new step)
      vim.api.nvim_buf_set_lines(bufnr, row, row + self.count, false, lines)
    end)
    self.written, self.count = true, #lines
    vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { id = mark, right_gravity = false })
  end

  --- the lines it covers now: first, last (0-based, end-exclusive)
  function region:range()
    local row = self:row()
    return row, row + self.count
  end

  function region:release() pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, mark) end

  return region
end

--- A window in the bottom right corner that shows text as it comes in: `float.update(text)`, `float.close()`.
function M.float(title)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local width = math.max(math.min(72, vim.o.columns - 6), 20)
  local height = math.max(math.min(10, vim.o.lines - 8), 3)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    anchor = "SE",
    row = vim.o.lines - vim.o.cmdheight - 2,
    col = vim.o.columns - 1,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "left",
    focusable = false,
    noautocmd = true,
    zindex = 60,
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].winhighlight = "NormalFloat:NormalFloat,FloatBorder:FloatBorder"
  pcall(vim.treesitter.start, buf, "markdown")

  local float = {}
  function float.update(text)
    if not vim.api.nvim_win_is_valid(win) then return end
    local lines = vim.split(text, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(win, { #lines, 0 }) -- keep the end in view
  end
  function float.close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end
  return float
end

return M
