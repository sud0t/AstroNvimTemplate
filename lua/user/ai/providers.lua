-- The providers besides Ollama and Claude. Each is reached with an API key and speaks OpenAI's chat-completions
-- protocol: lua/user/ai/openai.lua sends the editor's AI actions to `url`, the CodeCompanion adapter named in
-- `chat` runs the chat. <Leader>As, "Set up provider...", connects one: the key is checked with the provider,
-- stored in the system keyring, and then a model is chosen.
-- To add one: an entry here and its name in M.order; a deny for its key variables in srt-ai.json (the chat's
-- commands must not see keys); its adapter in plugins/codecompanion.lua, with the adapter's server-side tools
-- switched off there and in `locked_down()` (they run without the sandbox and without asking).
local M = {}

-- the order they are listed in
M.order = { "openai", "gemini", "openrouter" }

-- name        as shown
-- notice      where code goes, said when the provider is switched to
-- env         the variables a key is taken from, in this order, before the keyring
-- account     the key's entry in the keyring (service nvim-ai)
-- url         the API, up to and without /chat/completions
-- verify      a GET below `url` that answers 200 to a working key only
-- max_tokens  the request field that limits the length of the answer
-- chat        the CodeCompanion adapter for the chat
-- default     the model used until one is chosen
-- models      the ones offered (ids as on the providers' model pages in November 2026); any other id can be
--             typed in ("Other..."). `body`: request fields for this model, here to make it think only
--             briefly before a short answer. A typed id gets none: not every model accepts every field.
M.list = {
  openai = {
    name = "OpenAI",
    notice = "Code you run them on is sent to OpenAI.",
    env = { "OPENAI_API_KEY" },
    account = "openai-api-key",
    url = "https://api.openai.com/v1",
    verify = "/models",
    max_tokens = "max_completion_tokens",
    chat = "openai",
    default = "gpt-6.2-sol",
    models = {
      { id = "gpt-6.2-astra", name = "GPT-6.2 Astra", note = "most capable", body = { reasoning_effort = "low" } },
      { id = "gpt-6.2-sol", name = "GPT-6.2 Sol", note = "everyday work", body = { reasoning_effort = "low" } },
      { id = "gpt-6-luna", name = "GPT-6 Luna", note = "fastest", body = { reasoning_effort = "low" } },
    },
  },
  gemini = {
    name = "Gemini",
    notice = "Code you run them on is sent to Google. With a key that has no billing set up, Google uses it to "
      .. "improve its products and people there may read it.",
    env = { "GEMINI_API_KEY", "GOOGLE_API_KEY" },
    account = "gemini-api-key",
    url = "https://generativelanguage.googleapis.com/v1beta/openai",
    verify = "/models",
    max_tokens = "max_tokens",
    chat = "gemini",
    default = "gemini-4-hydrogen",
    models = {
      { id = "gemini-4-carbon", name = "Gemini 4 Carbon", note = "most capable", body = { reasoning_effort = "low" } },
      {
        id = "gemini-4-hydrogen",
        name = "Gemini 4 Hydrogen",
        note = "everyday work",
        body = { reasoning_effort = "low" },
      },
      { id = "gemini-3.8-flash", name = "Gemini 3.8 Flash", note = "fastest", body = { reasoning_effort = "low" } },
    },
  },
  openrouter = {
    name = "OpenRouter",
    notice = "Code you run them on is sent to OpenRouter and to the provider it routes the request to; each has "
      .. "its own rules for what it keeps.",
    env = { "OPENROUTER_API_KEY" },
    account = "openrouter-api-key",
    url = "https://openrouter.ai/api/v1",
    verify = "/key", -- (its model list may be open to anyone: it would not tell a wrong key)
    max_tokens = "max_tokens",
    chat = "openrouter",
    default = "openai/gpt-6.2-sol",
    models = {
      { id = "openai/gpt-6.2-sol", name = "GPT-6.2 Sol", note = "OpenAI", body = { reasoning = { effort = "low" } } },
      {
        id = "anthropic/claude-sonnet-5.5",
        name = "Claude Sonnet 5.5",
        note = "Anthropic",
        body = { reasoning = { effort = "low" } },
      },
      {
        id = "google/gemini-4-carbon",
        name = "Gemini 4 Carbon",
        note = "Google",
        body = { reasoning = { effort = "low" } },
      },
      { id = "qwen/qwen4-max", name = "Qwen4 Max", note = "Alibaba" },
    },
  },
}

--- Can `key` be an API key? 8 to 512 characters, none of them a space, a quote or a line break: a key goes
--- into curl's options (on stdin), where those would start another option.
function M.valid_key(key)
  return type(key) == "string" and #key >= 8 and #key <= 512 and key:find "[^%w%._~+/=:%-]" == nil
end

--- Can `id` be a model id? It is sent as it is and stored in the state file.
function M.valid_model_id(id) return type(id) == "string" and #id <= 200 and id:match "^%w[%w%._:/@+%-]*$" ~= nil end

--- The entry of model `id` in `provider`'s list, or nil for one that was typed in.
function M.model(provider, id)
  for _, model in ipairs(M.list[provider].models) do
    if model.id == id then return model end
  end
end

--- What to call model `id` of `provider`: its name in the list, or the id itself.
function M.model_name(provider, id)
  local model = M.model(provider, id)
  return model and model.name or id
end

return M
