-- How the AI actions reach the providers in lua/user/ai/providers.lua: one streaming chat-completions request
-- (OpenAI's protocol, which they all speak), text in and text out, as lua/user/ai/claude.lua does for Claude.
-- These APIs report trouble in several ways (an HTTP error, an error inside the stream while the status stays
-- 200, a finish reason other than "stop", a stream that just ends): `info.error`, with stream.post.
local M = {}

local stream = require "user.ai.stream"

--- The message of an error body: { error = { message } }, that in a list (Gemini), or { error = "..." }.
local function error_message(data)
  if type(data) ~= "table" then return end
  if vim.islist(data) then data = data[1] end
  local err = type(data) == "table" and data.error or nil
  if type(err) == "string" and err ~= "" then return err end
  if type(err) ~= "table" then return end
  if type(err.message) == "string" and err.message ~= "" then return err.message end
  if err.code ~= nil and err.code ~= vim.NIL then return "error " .. tostring(err.code) end
end

--- `provider` (an entry of providers.list) as stream.post and stream.get take an API.
local function api(provider)
  return { name = provider.name, auth = "Authorization: Bearer %s", error_message = error_message }
end

--- `request`: { system, messages = { { role, content }, ... }, max_tokens }; `provider`: an entry of
--- providers.list; `model`: { id, body? }. `on_text`, `on_done` and the handle are those of stream.run.
function M.chat(request, provider, model, key, on_text, on_done)
  local messages = { { role = "system", content = request.system } }
  vim.list_extend(messages, request.messages)
  local body = vim.tbl_extend("force", {
    model = model.id,
    stream = true,
    messages = messages,
    [provider.max_tokens] = request.max_tokens,
  }, model.body or {})

  local function event(state, data)
    local said = error_message(data)
    if said or (data.error ~= nil and data.error ~= vim.NIL) then
      return state.fail(said or (provider.name .. " reported an error"))
    end
    local choice = type(data.choices) == "table" and data.choices[1] or nil
    if type(choice) ~= "table" then return end -- (the usage figures come without one)
    local piece = type(choice.delta) == "table" and choice.delta.content or nil
    if type(piece) == "string" and piece ~= "" then state.add(piece) end
    local reason = choice.finish_reason
    if type(reason) == "string" then
      state.finished = true
      if reason == "length" then
        state.info.done_reason = "length"
      elseif reason ~= "stop" then
        state.fail(("%s ended the answer early (%s)"):format(provider.name, reason))
      end
    end
  end
  return stream.post(api(provider), provider.url .. "/chat/completions", key, body, event, on_text, on_done)
end

--- Is `key` a working key for `provider`? `on_result(ok, message)` on the main loop.
function M.verify(provider, key, on_result)
  stream.get(
    api(provider),
    provider.url .. provider.verify,
    key,
    20,
    function(body, message) on_result(body ~= nil, message) end
  )
end

return M
