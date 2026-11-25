-- Which AI the editor's AI actions use: Local (Ollama), Claude (the Claude Code login or an Anthropic API
-- key), or a provider from providers.lua. <Leader>As swaps it; ghost-text completion always stays local.
-- This module is what the rest of the configuration calls: the public names of its parts (state.lua, keys.lua,
-- chat.lua, provider_menu.lua), and `chat`, one request to the AI chosen. docs/ai-modules.md maps the modules.
local M = {}

local chat = require "user.ai.chat"
local claude = require "user.ai.claude"
local keys = require "user.ai.keys"
local provider_menu = require "user.ai.provider_menu"
local providers = require "user.ai.providers"
local state = require "user.ai.state"

-- The parts' public names. Each is documented where it is defined.
M.is_local = state.is_local
M.model_id = state.model_id
M.label = state.label
M.claude_model_id = state.claude_model_id
M.claude_model = state.claude_model

M.key = keys.key
M.api_key = keys.api_key
--- The key of `id` if it is known already, without its source: never asks the keyring, never waits.
function M.known_key(id) return (keys.known_key(id)) end

M.bridge_path = chat.bridge_path
M.chat_adapter = chat.chat_adapter
M.current_chat_adapter = chat.current_chat_adapter
M.open_chat = chat.open_chat
M.rules_files = chat.rules_files
M.rules_group = chat.rules_group

M.select = provider_menu.select

--- `request` to the current provider. Raises when it cannot be sent.
local function send(request, on_text, on_done)
  local s = state.load()
  local function no_key(name) error(("no %s API key (<Leader>As, Set up provider)"):format(name), 0) end
  if s.provider == "claude" then
    if s.route ~= "api" then return claude.cli(request, s.model, on_text, on_done) end
    local key = M.api_key() or no_key "Anthropic"
    return claude.api(request, s.model, key, on_text, on_done)
  end
  local provider = providers.list[s.provider]
  if provider then
    local key = M.key(s.provider) or no_key(provider.name)
    local id = M.model_id(s.provider)
    local model = providers.model(s.provider, id) or { id = id }
    return require("user.ai.openai").chat(request, provider, model, key, on_text, on_done)
  end
  local ollama = require "user.ai.ollama"
  local wanted = request.ollama or {}
  local messages = { { role = "system", content = request.system } }
  vim.list_extend(messages, request.messages)
  return ollama.chat({
    model = ollama.model,
    think = false, -- the tag is the non-thinking variant, but Ollama lists the capability
    keep_alive = wanted.keep_alive or "5m",
    options = vim.tbl_extend("force", { num_predict = request.max_tokens }, wanted.options or {}),
    messages = messages,
  }, on_text, on_done)
end

--- Send `request` to the current provider and stream the answer (`run` in stream.lua has the callbacks and
--- the handle). A request that cannot be sent (no key, no program) ends in `info.error` as well.
--- `request`: { system, messages = { { role, content } }, max_tokens, ollama = { keep_alive, options } }.
function M.chat(request, on_text, on_done)
  -- (a model's reasoning, when it writes that into its answer, is not part of it)
  local function answer(text) return (text:gsub("<think>.-</think>", "")) end
  local sent, handle = pcall(
    send,
    request,
    function(text) on_text(answer(text)) end,
    function(text, info) on_done(answer(text), info) end
  )
  if sent then return handle end
  local cancelled = false
  vim.schedule(function()
    if not cancelled then on_done("", { error = tostring(handle) }) end
  end)
  return { cancel = function() cancelled = true end }
end

return M
