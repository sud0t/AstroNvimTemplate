-- The two ways the AI actions reach Claude (lua/user/ai/init.lua picks one), both streaming the answer:
--   M.cli   through Claude Code (`claude -p`): uses the login of the `claude` command, so a Claude subscription
--           and no API key. No tools, no project settings: it only answers the prompt it is given.
--   M.api   the Anthropic API with an API key (billed per token).
-- A request is { system, messages = { { role, content }, ... }, max_tokens }; `on_text`, `on_done` and the
-- handle both return are those of `run` in lua/user/ai/stream.lua.
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

local stream = require "user.ai.stream"

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
    local data = stream.decode(line)
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
  return stream.run(cmd, { cwd = cwd, stdin = transcript(request.messages) }, take, on_text, finish, on_done)
end

---------------------------------------------------------------------------------------------- Anthropic API

-- ($ANTHROPIC_BASE_URL: the standard override, for a proxy or gateway)
local api_url = (vim.env.ANTHROPIC_BASE_URL or "https://api.anthropic.com"):gsub("/+$", "") .. "/v1"

--- The message of an error, as a body or as an event of a stream: { type = "error", error = { type, message } }.
local function error_message(data)
  local err = type(data) == "table" and data.error or nil
  if type(err) == "string" and err ~= "" then return err end
  if type(err) ~= "table" then return end
  local said = err.message or err.type
  return type(said) == "string" and said ~= "" and said or nil
end

--- The API as stream.post and stream.get take one. `beta`: a beta feature the request uses.
local function api(beta)
  return {
    name = "the Anthropic API",
    auth = "x-api-key: %s",
    headers = { "anthropic-version: 2026-10-21", beta and ("anthropic-beta: " .. beta) or nil },
    error_message = error_message,
  }
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
  local beta
  if model ~= "haiku" then
    -- if a safety classifier declines the request, the API reruns it on a fallback model in the same call
    -- (not for Haiku: the API has no fallback for it)
    body.fallbacks = "default"
    beta = "server-side-fallback-2026-07-01"
  end

  local function event(state, data)
    -- (a `null` in the JSON is vim.NIL here, which is true and cannot be indexed)
    local delta = type(data.delta) == "table" and data.delta or nil
    if data.type == "content_block_delta" and delta and delta.type == "text_delta" then
      state.add(delta.text or "")
    elseif data.type == "message_delta" and delta then
      local reason = delta.stop_reason
      if reason == "max_tokens" then state.info.done_reason = "length" end
      if reason == "refusal" then state.fail "Claude declined this request" end
    elseif data.type == "message_stop" then
      state.finished = true
    elseif data.type == "error" then
      state.fail(error_message(data) or "the Anthropic API reported an error")
    end
  end
  return stream.post(api(beta), api_url .. "/messages", key, body, event, on_text, on_done)
end

---------------------------------------------------------------------------------------------- chat models

-- Model metadata for CodeCompanion's `anthropic` adapter, fetched here because the adapter's own request
-- puts the key among curl's arguments, where every process on the machine can read it (here it is on curl's
-- stdin: lua/user/ai/stream.lua). Fetched once, waiting up to 3 seconds before the first chat; when the API
-- cannot be reached the adapter gets the static list below (no compaction of long chats).
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
      local asked, why = pcall(stream.get, api(), chat_api .. "/models?limit=100", key, 10, function(body)
        chat_models.fetching = false
        chat_models.retry_at = vim.uv.now() + 60000
        local data = stream.decode(body or "")
        local choices = {}
        for _, model in ipairs(data and type(data.data) == "table" and data.data or {}) do
          local done, id, choice = pcall(transform.from_anthropic, model)
          if done and type(id) == "string" then choices[id] = choice end
        end
        if next(choices) then chat_models.fetched = choices end
      end)
      if not asked then
        chat_models.fetching = false -- (nothing was started: no answer will do it)
        error(why, 0)
      end
    end
  end
  if chat_models.fetching and request and request.async == false then
    vim.wait(3000, function() return not chat_models.fetching end, 10)
  end
  return chat_models.fetched or known_models()
end

--- Is `key` a working API key? `on_result(ok, message)` on the main loop. (Lists one model: free.)
function M.verify_key(key, on_result)
  stream.get(api(), api_url .. "/models?limit=1", key, 20, function(body, message) on_result(body ~= nil, message) end)
end

return M
