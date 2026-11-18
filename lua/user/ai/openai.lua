-- How the AI actions reach the providers in lua/user/ai/providers.lua: one streaming chat-completions request
-- (OpenAI's protocol, which they all speak), text in and text out, as lua/user/ai/claude.lua does for Claude.
-- A request is { system, messages = { { role, content }, ... }, max_tokens }; `on_text`, `on_done` and the
-- handle are those of M.chat in lua/user/ai/stream.lua.
-- An answer only counts as whole when the provider said so. These APIs report trouble in several ways: an HTTP
-- error with a JSON body before anything is streamed, an error inside the stream while the status stays 200
-- (OpenRouter), a finish reason other than "stop", or a stream that just ends. All of them end in
-- `info.error`, so that a review cut short is not applied and half a commit message is not kept as if whole.
local M = {}

local stream = require "user.ai.stream"

--- curl options on stdin (`--config -`): the key is neither in the process list nor in a file. A key has
--- passed providers.valid_key before it gets here, so it cannot end the quoted value.
local function curl_config(key)
  return ('header = "Authorization: Bearer %s"\nheader = "content-type: application/json"\n'):format(key)
end

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

--- `text` without `key` in it: a server may repeat the key it was sent in its error message.
local function without(key, text) return (tostring(text):gsub(vim.pesc(key), "***")) end

--- `provider`: an entry of providers.list; `model`: { id, body? }.
function M.chat(request, provider, model, key, on_text, on_done)
  local messages = { { role = "system", content = request.system } }
  vim.list_extend(messages, request.messages)
  local body = vim.tbl_extend("force", {
    model = model.id,
    stream = true,
    messages = messages,
    [provider.max_tokens] = request.max_tokens,
  }, model.body or {})
  -- the request itself goes through a private temporary file (stdin carries the curl options)
  local file = vim.fn.tempname()
  vim.fn.writefile({ vim.json.encode(body) }, file)

  local function fail(state, message)
    if not state.info.error then state.info.error = without(key, message) end
  end
  local function take(state, line)
    line = line:gsub("\r$", "")
    -- (":" starts a comment: OpenRouter sends them while a model is still loading; the other fields of
    -- server-sent events carry nothing of the answer)
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
    if data == "[DONE]" then return end
    data = stream.decode(data)
    if not data then return end
    local said = error_message(data) -- (also an error in a list, as Gemini sends them)
    if said or (data.error ~= nil and data.error ~= vim.NIL) then
      return fail(state, said or (provider.name .. " reported an error"))
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
        fail(state, ("%s ended the answer early (%s)"):format(provider.name, reason))
      end
    end
  end
  local function finish(state, res)
    if state.info.error then return end
    local rest = state.rest or {}
    local status = tonumber((rest[#rest] or ""):match "^%d%d%d$")
    if status then rest[#rest] = nil end
    if res.code ~= 0 then
      return fail(state, ("no answer from %s (curl exit code %d)"):format(provider.name, res.code))
    end
    if (status and status >= 400) or #rest > 0 then
      local said = error_message(stream.decode(table.concat(rest, "\n")))
      return fail(state, said or ("%s answered HTTP %s"):format(provider.name, status or "with something else"))
    end
    if not state.finished then fail(state, provider.name .. " ended the answer before it was finished") end
  end
  local cmd = {
    "curl",
    "-sN",
    "--max-time",
    "600",
    "-w",
    "\n%{http_code}",
    "--config",
    "-",
    provider.url .. "/chat/completions",
    "-d",
    "@" .. file,
  }
  local opts = { stdin = curl_config(key), cleanup = function() vim.fn.delete(file) end }
  return stream.run(cmd, opts, take, on_text, finish, on_done)
end

--- Is `key` a working key for `provider`? `on_result(ok, message)` on the main loop.
function M.verify(provider, key, on_result)
  local cmd =
    { "curl", "-s", "--max-time", "20", "--config", "-", "-w", "\n%{http_code}", provider.url .. provider.verify }
  vim.system(
    cmd,
    { text = true, stdin = curl_config(key) },
    vim.schedule_wrap(function(res)
      local body, status = (res.stdout or ""):match "^(.*)\n(%d+)%s*$"
      if res.code ~= 0 or not status then
        return on_result(false, "could not reach " .. (provider.url:match "^https://([^/]+)" or provider.url))
      end
      if status == "200" then return on_result(true) end
      on_result(false, without(key, error_message(stream.decode(body)) or ("HTTP " .. status)))
    end)
  )
end

return M
