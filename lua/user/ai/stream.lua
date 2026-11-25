-- What the AI actions share to send a request and to show its answer while it is being written:
--   M.run        a command whose output is the answer as it grows (every backend runs on it)
--   M.decode     JSON text as a table: a line of an answer, an error's body
--   M.post       a streaming request to an API that takes a key; M.get asks such an API a question
--   M.selection  the rows selected in visual mode, for an action that takes a selection
--   M.region     lines of a buffer that are rewritten as the answer grows (one undo step in the end)
--   M.float      a corner window showing the answer live, for answers that are not written into the buffer
local M = {}

--- Run `cmd` (`opts` for vim.system: stdin, cwd) and hand every line of its output to `take(state, line)`:
--- `state.add(piece)` appends to the answer, `state.fail(message)` reports an error (the first one stands).
--- `finish(state, res)` decides what the end of the process means. `opts.cleanup()` runs at that end too,
--- also after a cancel, which skips `finish`.
--- `on_text(text)` gets the whole answer each time it has grown; `on_done(text, info)` runs once, with
--- `info.error` (a string, when the request failed) and `info.done_reason` ("length": cut off). Both run on
--- the main loop, and neither after `cancel()` of the handle. Raises when `cmd` cannot be started.
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

  function state.fail(message)
    if not state.info.error then state.info.error = message end
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
    -- nothing ran, so nothing will clean up later
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

--- JSON text as a table, or nil.
function M.decode(text)
  if text == "" then return end
  local ok, data = pcall(vim.json.decode, text)
  if ok and type(data) == "table" then return data end
end

------------------------------------------------------------------------------------------- APIs with a key

-- An `api` is what a provider's module says about its API: `name` (as error messages call it), `auth` (the
-- header that carries the key, %s in its place), `headers` (the others, optional) and `error_message(data)`
-- (the message in a decoded error body, or nil).

--- curl's options for a request with `key`, for curl's stdin (`--config -`): there the key is in neither the
--- process list nor a file. A key that providers.valid_key refuses could end the quoted value and add options.
local function curl_config(api, key)
  if not require("user.ai.providers").valid_key(key) then error("the API key cannot be one: nothing is sent", 0) end
  local lines = { ('header = "%s"'):format(api.auth:format(key)), 'header = "content-type: application/json"' }
  for _, header in ipairs(api.headers or {}) do
    lines[#lines + 1] = ('header = "%s"'):format(header)
  end
  return table.concat(lines, "\n") .. "\n"
end

--- `text` without `key` in it: a server may repeat the key it was sent in its error message.
local function without(key, text) return (text:gsub(vim.pesc(key), "***")) end

--- POST `body` (a table) to `url` with `key` and read the answer as server-sent events: each `data:` line
--- that is JSON goes to `event(state, data)` (`state` as in M.run), which sets `state.finished` when the
--- provider ends the answer itself. Without that the answer does not count as whole: `info.error` is the
--- first of an error in the stream, curl failing, an HTTP error or a body that is no stream, a stream that
--- just ends. The text before it is still handed over. `on_text`, `on_done` and the handle as in M.run.
function M.post(api, url, key, body, event, on_text, on_done)
  local config = curl_config(api, key)
  -- stdin carries curl's options, so the request goes through a private temporary file
  local file = vim.fn.tempname()
  vim.fn.writefile({ vim.json.encode(body) }, file)

  local function take(state, line)
    line = line:gsub("\r$", "")
    -- (":" starts a comment, sent to keep the connection open; of an event's fields only `data` is the answer)
    if line == "" or line:sub(1, 1) == ":" or line:find "^event:" or line:find "^id:" or line:find "^retry:" then
      return
    end
    local data = line:match "^data:%s*(.*)$"
    if not data then
      -- not part of a stream: an error body (JSON, possibly over several lines), then the status from `-w`
      state.rest = state.rest or {}
      state.rest[#state.rest + 1] = line
      return
    end
    data = M.decode(data) -- (nil for what is not JSON: OpenAI's closing `[DONE]`)
    if data then event(state, data) end
  end
  local function finish(state, res)
    local rest = state.rest or {}
    local status = tonumber((rest[#rest] or ""):match "^%d%d%d$")
    if status then rest[#rest] = nil end
    if res.code ~= 0 then
      state.fail(("no answer from %s (curl exit code %d)"):format(api.name, res.code))
    elseif (status and status >= 400) or #rest > 0 then
      local said = api.error_message(M.decode(table.concat(rest, "\n")))
      state.fail(said or ("%s answered HTTP %s"):format(api.name, status or "with something else"))
    elseif not state.finished then
      state.fail(api.name .. " ended the answer before it was finished")
    end
  end
  local cmd = { "curl", "-sN", "--max-time", "600", "-w", "\n%{http_code}", "--config", "-", url, "-d", "@" .. file }
  local opts = { stdin = config, cleanup = function() vim.fn.delete(file) end }
  return M.run(cmd, opts, take, on_text, finish, function(text, info)
    if info.error then info.error = without(key, info.error) end
    on_done(text, info)
  end)
end

--- GET `url` with `key`, giving up after `seconds`: `on_result(body)` when the answer is 200, else
--- `on_result(nil, message)`, on the main loop.
function M.get(api, url, key, seconds, on_result)
  local cmd = { "curl", "-s", "--max-time", tostring(seconds), "-w", "\n%{http_code}", "--config", "-", url }
  vim.system(
    cmd,
    { text = true, stdin = curl_config(api, key) },
    vim.schedule_wrap(function(res)
      local body, status = (res.stdout or ""):match "^(.*)\n(%d+)%s*$"
      if res.code ~= 0 or not status then
        return on_result(nil, "could not reach " .. (url:match "^https?://([^/]+)" or url))
      end
      if status == "200" then return on_result(body) end
      on_result(nil, without(key, api.error_message(M.decode(body)) or ("HTTP " .. status)))
    end)
  )
end

---------------------------------------------------------------------------------------------- showing it

--- The rows selected in visual mode (first, last: 0-based, inclusive), which it leaves; nothing in other modes.
function M.selection()
  if not vim.fn.mode():match "^[vV\22]" then return end
  local first, last = vim.fn.line "v" - 1, vim.fn.line "." - 1
  vim.cmd.normal { "\27", bang = true }
  return math.min(first, last), math.max(first, last)
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
