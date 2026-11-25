-- The AI chosen in <Leader>As (provider, Claude's connection, the models), kept across sessions in
-- stdpath("state")/ai_provider.json. The file is checked when it is read: a damaged one only means the defaults.
local M = {}

local claude = require "user.ai.claude"
local json_file = require "user.ai.json_file"
local providers = require "user.ai.providers"

local function notify(msg, level) vim.notify(msg, level or vim.log.levels.INFO, { title = "AI provider" }) end

local state_file = vim.fn.stdpath "state" .. "/ai_provider.json"
-- { provider = "ollama" | "claude" | a name in providers.list,
--   route = "login" | "api", model = a name in claude.models   (Claude's connection and model, chosen last),
--   models = { [provider] = model id }                         (the other providers' models, chosen last) }
local state

--- The choice, read from the file the first time. Change it with `save`.
function M.load()
  if state then return state end
  state = { provider = "ollama", route = "login", model = "opus", models = {} }
  local saved = json_file.read(state_file)
  if saved.provider == "claude" or providers.list[saved.provider] then state.provider = saved.provider end
  if saved.route == "api" then state.route = "api" end
  if claude.models[saved.model] then state.model = saved.model end
  for id, model in pairs(type(saved.models) == "table" and saved.models or {}) do
    if providers.list[id] and providers.valid_model_id(model) then state.models[id] = model end
  end
  return state
end

--- Store `changes` (keys of the state; `models` is merged provider by provider). The file is read again first:
--- what another Neovim chose meanwhile for the other keys stays, and so do keys this version does not know.
function M.save(changes)
  local s, file = M.load(), json_file.read(state_file)
  for key, value in pairs(changes) do
    if key == "models" then
      local models = {}
      for id, model in pairs(type(file.models) == "table" and file.models or {}) do
        if type(id) == "string" then models[id] = model end
      end
      for id, model in pairs(value) do
        models[id], s.models[id] = model, model
      end
      file.models = models
    else
      file[key], s[key] = value, value
    end
  end
  -- (an empty table would be written as a list)
  if type(file.models) ~= "table" or next(file.models) == nil then file.models = nil end
  if not json_file.write(state_file, file) then
    notify("Could not write " .. state_file .. ": the choice holds until Neovim closes", vim.log.levels.WARN)
  end
end

function M.is_local() return M.load().provider == "ollama" end

--- the model id in use with `provider` (a name in providers.list): the one chosen last, or its default
function M.model_id(provider) return M.load().models[provider] or providers.list[provider].default end

--- the model in use, for messages: "qwen3:4b-instruct", "Claude Opus 5.5", "GPT-6.2 Sol (OpenAI)"
function M.label()
  local s = M.load()
  if s.provider == "ollama" then return require("user.ai.ollama").model end
  if s.provider == "claude" then return claude.models[s.model].name end
  return ("%s (%s)"):format(providers.model_name(s.provider, M.model_id(s.provider)), providers.list[s.provider].name)
end

--- the API id of the Claude model chosen last, for the CodeCompanion chat with the API key
function M.claude_model_id() return claude.models[M.load().model].id end

--- its short name ("fable", "opus", ...), which is what Claude Code calls it: for the chat through the login
function M.claude_model() return M.load().model end

return M
