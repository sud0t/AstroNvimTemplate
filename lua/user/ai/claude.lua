-- The two ways the AI features reach Claude (lua/user/ai/init.lua picks one), both streaming the answer:
--   M.cli   through Claude Code (`claude -p`): uses the login of the `claude` command, so a Claude subscription
--           and no API key. No tools, no project settings: it only answers the prompt it is given.
--   M.api   the Anthropic API with an API key (billed per token).
-- A request is { system, messages = { { role, content }, ... }, max_tokens }. Both functions call
-- `on_text(text)` with the whole answer so far each time it has grown and `on_done(text, info)` once at the end
-- (`info.error`, `info.done_reason == "length"` when cut off), on the main loop, and return a handle with
-- `cancel()`, as M.chat in lua/user/ai/stream.lua does (`run` there is what the two share).
local M = {}

-- `note` is shown next to the model in <Leader>As; `api_note` only where it is billed per token (the API key)
M.models = {
  fable = {
    id = "claude-fable-5-2",
    name = "Claude Fable 5.2",
    note = "most capable",
    api_note = "twice Opus's price per token",
  },
  opus = { id = "claude-opus-5-5", name = "Claude Opus 5.5" },
  sonnet = { id = "claude-sonnet-5-5", name = "Claude Sonnet 5.5", note = "faster" },
  haiku = { id = "claude-haiku-5-5", name = "Claude Haiku 5.5", note = "fastest" },
}
-- the order they are listed in
M.order = { "fable", "opus", "sonnet", "haiku" }

local run, decode = require("user.ai.stream").run, require("user.ai.stream").decode

---------------------------------------------------------------------------------------------- Claude Code

--- One prompt out of a conversation: `claude -p` takes a single prompt.
local function transcript(messages)
  if #messages == 1 then return messages[1].content end
  local parts = { "This is the conversation so far. Reply to the last message.", "" }
  for _, message in ipairs(messages) do
    vim.list_extend(parts, { ("<%s>"):format(message.role), message.content, ("</%s>"):format(message.role), "" })
  end
  return table.concat(parts, "\n")
end

function M.cli(request, model, on_text, on_done)
  -- a directory of its own: no project instructions or settings, they are for working in the project
  local cwd = vim.fn.stdpath "cache" .. "/ai"
  vim.fn.mkdir(cwd, "p")
  local cmd = {
    "claude",
    "-p",
    "--output-format",
    "stream-json",
    "--include-partial-messages",
    "--verbose", -- (stream-json needs it)
    "--model",
    M.models[model].id,
    "--effort",
    "low", -- short editing tasks: answer quickly
    "--tools",
    "", -- text in, text out
    "--system-prompt",
    request.system,
    "--setting-sources",
    "",
    "--strict-mcp-config",
    "--no-session-persistence",
  }
  local function take(state, line)
    local data = decode(line)
    if not data then return end
    if data.type == "stream_event" then
      local event = data.event or {}
      local delta = event.delta or {}
      if event.type == "content_block_delta" and delta.type == "text_delta" then state.add(delta.text or "") end
      if event.type == "message_delta" and delta.stop_reason == "max_tokens" then state.info.done_reason = "length" end
    elseif data.type == "result" then
      state.got_result = true
      if data.is_error then
        state.info.error = type(data.result) == "string" and data.result ~= "" and data.result
          or ("Claude Code: " .. tostring(data.subtype))
      end
    end
  end
  local function finish(state, res)
    if state.info.error or state.got_result then return end
    local err = vim.trim(res.stderr or "")
    state.info.error = err ~= "" and err or ("Claude Code stopped without an answer (exit code %d)"):format(res.code)
  end
  return run(cmd, { cwd = cwd, stdin = transcript(request.messages) }, take, on_text, finish, on_done)
end

---------------------------------------------------------------------------------------------- Anthropic API

-- ($ANTHROPIC_BASE_URL: the standard override, for a proxy or gateway)
local api_url = (vim.env.ANTHROPIC_BASE_URL or "https://api.anthropic.com"):gsub("/+$", "") .. "/v1"
local api_version = "2026-10-21"

--- curl options on stdin (`--config -`): the key is neither in the process list nor in a file
local function curl_config(key, extra)
  local lines = {
    ('header = "x-api-key: %s"'):format(key),
    ('header = "anthropic-version: %s"'):format(api_version),
    'header = "content-type: application/json"',
  }
  return table.concat(vim.list_extend(lines, extra or {}), "\n") .. "\n"
end

function M.api(request, model, key, on_text, on_done)
  local body = {
    model = M.models[model].id,
    max_tokens = request.max_tokens or 16000,
    stream = true,
    system = request.system,
    messages = request.messages,
    output_config = { effort = "low" }, -- short editing tasks: answer quickly
  }
  local extra = {}
  if model ~= "haiku" then
    -- if a safety classifier declines the request, the API reruns it on a fallback model in the same call
    body.fallbacks = "default"
    extra[1] = 'header = "anthropic-beta: server-side-fallback-2026-07-01"'
  end
  -- the request itself goes through a private temporary file (stdin carries the curl options)
  local file = vim.fn.tempname()
  vim.fn.writefile({ vim.json.encode(body) }, file)

  local function fail(state, err)
    local detail = type(err) == "table" and (err.message or err.type) or err
    state.info.error = tostring(detail or "request failed")
  end
  local function take(state, line)
    -- server-sent events: only the `data:` lines matter; an error before the stream starts is plain JSON
    local data = decode(line:match "^data:%s*(.*)$" or (line:find "^{" and line) or "")
    if not data then return end
    if data.type == "content_block_delta" and data.delta and data.delta.type == "text_delta" then
      state.add(data.delta.text or "")
    elseif data.type == "message_delta" and data.delta then
      local reason = data.delta.stop_reason
      if reason == "max_tokens" then state.info.done_reason = "length" end
      if reason == "refusal" then fail(state, "Claude declined this request") end
    elseif data.type == "error" then
      fail(state, data.error)
    end
  end
  local function finish(state, res)
    if not state.info.error and res.code ~= 0 then
      fail(state, "no answer from the Anthropic API (curl exit code " .. res.code .. ")")
    end
  end
  local cmd = { "curl", "-sN", "--max-time", "600", "--config", "-", api_url .. "/messages", "-d", "@" .. file }
  local opts = { stdin = curl_config(key, extra), cleanup = function() vim.fn.delete(file) end }
  return run(cmd, opts, take, on_text, finish, on_done)
end

---------------------------------------------------------------------------------------------- chat models

-- What CodeCompanion's `anthropic` adapter has to know about the models (plugins/codecompanion.lua). By itself
-- it asks the API with the key among curl's arguments, where every process on the machine can read it; here
-- the key goes in on stdin, and the answer is put into the adapter's form by CodeCompanion's own function.
-- A chat keeps the settings it was opened with, so the adapter asks once before the first chat and waits for
-- the answer (up to 3 seconds). When the API cannot be reached the adapter gets what is known here: enough
-- for a chat, with a length limit every model takes and without what depends on the API's answer (compacting
-- a long chat).
local chat_models = { retry_at = 0 }
-- (the address CodeCompanion's adapter sends the chat to: it does not follow $ANTHROPIC_BASE_URL)
local chat_api = "https://api.anthropic.com/v1"

local function known_models()
  local choices = {}
  for _, model in pairs(M.models) do
    choices[model.id] = {
      formatted_name = model.name,
      meta = { context_window = 1000000, max_tokens = 64000 },
      opts = { can_reason = true, has_vision = true },
    }
  end
  return choices
end

--- The adapter's model choices. `key`: nil gives what is known here, without asking the API.
--- `request.async == false`: wait for the API's answer (up to 3 seconds).
function M.chat_models(key, request)
  if key and not chat_models.fetched and not chat_models.fetching and vim.uv.now() >= chat_models.retry_at then
    local ok, transform = pcall(require, "codecompanion.adapters.utils.models.transform")
    if ok and type(transform.from_anthropic) == "function" then
      chat_models.fetching = true
      vim.system(
        { "curl", "-s", "--max-time", "10", "--config", "-", chat_api .. "/models?limit=100" },
        { text = true, stdin = curl_config(key) },
        vim.schedule_wrap(function(res)
          chat_models.fetching = false
          chat_models.retry_at = vim.uv.now() + 60000
          local data = res.code == 0 and decode(res.stdout or "") or nil
          local choices = {}
          for _, model in ipairs(data and type(data.data) == "table" and data.data or {}) do
            local done, id, choice = pcall(transform.from_anthropic, model)
            if done and type(id) == "string" then choices[id] = choice end
          end
          if next(choices) then chat_models.fetched = choices end
        end)
      )
    end
  end
  if chat_models.fetching and request and request.async == false then
    vim.wait(3000, function() return not chat_models.fetching end, 10)
  end
  return chat_models.fetched or known_models()
end

--- Is `key` a working API key? `on_result(ok, message)` on the main loop. (Lists one model: free.)
function M.verify_key(key, on_result)
  vim.system(
    { "curl", "-s", "--max-time", "20", "--config", "-", "-w", "\n%{http_code}", api_url .. "/models?limit=1" },
    { text = true, stdin = curl_config(key) },
    vim.schedule_wrap(function(res)
      local body, status = (res.stdout or ""):match "^(.*)\n(%d+)%s*$"
      if res.code ~= 0 or not status then return on_result(false, "could not reach api.anthropic.com") end
      if status == "200" then return on_result(true) end
      local data = decode(body) or {}
      on_result(false, vim.tbl_get(data, "error", "message") or ("HTTP " .. status))
    end)
  )
end

return M
