-- The chat of the AI chosen in <Leader>As: the CodeCompanion adapter and the rules it gets, and <Leader>AC,
-- which opens Claude Code itself or the CodeCompanion chat. (One request of an action is `chat` in init.lua.)
local M = {}

local keys = require "user.ai.keys"
local providers = require "user.ai.providers"
local state = require "user.ai.state"

M.bridge = "claude-agent-acp" -- what the CodeCompanion chat talks to Claude Code through (a Mason package)

--- The chat bridge's executable, or nil when it is not installed. (Mason only puts its bin directory on $PATH
--- once it has loaded, which is after the first file is opened: look there directly too.)
function M.bridge_path()
  if vim.fn.executable(M.bridge) == 1 then return vim.fn.exepath(M.bridge) end
  local path = vim.fn.stdpath "data" .. "/mason/bin/" .. M.bridge
  return vim.fn.executable(path) == 1 and path or nil
end

--- The CodeCompanion adapter for the chat with the current choice, and why when it is not what was chosen.
function M.chat_adapter()
  local s = state.load()
  if s.provider == "ollama" then return "ollama" end
  local provider = providers.list[s.provider]
  if provider then
    if keys.key(s.provider) then return provider.chat end
    return "ollama", ("the chat stays local: no %s API key (<Leader>As, Set up provider)"):format(provider.name)
  end
  if s.route == "api" then
    if keys.api_key() then return "anthropic" end
    return "ollama", "the chat stays local: no Anthropic API key (<Leader>As, Set up provider)"
  end
  if M.bridge_path() then return "claude_code" end
  -- (<Leader>AC is Claude Code itself with the login: only the other ways into a chat miss the bridge)
  local unbridged = "the chat bridge is not installed (<Leader>As, Set up provider)"
  if keys.api_key() then
    return "anthropic", "CodeCompanion chats use the Anthropic API key, billed per token: " .. unbridged
  end
  return "ollama",
    "CodeCompanion chats (:CodeCompanionChat, a selection added with <Leader>Aa) stay local: " .. unbridged
end

--- Tell CodeCompanion the adapter for the chats opened from now on. Returns why, when it is not the one chosen.
function M.apply_to_chat()
  -- (plugins/codecompanion.lua, when the chat's sandbox could not be put in place: the chat then stays as it
  -- was started, local and without tools)
  if vim.g.ai_chat_locked then return "the chat stays local and without tools: its sandbox is not in place" end
  local adapter, why = M.chat_adapter()
  if package.loaded["codecompanion"] then require("codecompanion.config").interactions.chat.adapter = adapter end
  return why
end

--- The adapter a chat opened now gets: what CodeCompanion was told last (when it loaded, or by <Leader>As).
--- `M.chat_adapter()` can be ahead of that, e.g. once the chat bridge got installed in this session.
function M.current_chat_adapter()
  if package.loaded["codecompanion"] then
    local ok, config = pcall(require, "codecompanion.config")
    local adapter = ok and vim.tbl_get(config, "interactions", "chat", "adapter")
    if type(adapter) == "table" then adapter = adapter.name end
    if type(adapter) == "string" then return adapter end
  end
  return (M.chat_adapter())
end

--- Show the CodeCompanion chat in place of the current buffer, or hide it and bring that buffer back. (Not
--- `CodeCompanionChat Toggle` with the "buffer" layout: that switches whatever window the cursor is in.)
local function toggle_chat()
  local codecompanion = require "codecompanion"
  local as_buffer = { layout = "buffer" }
  local chat = codecompanion.last_chat()
  local here = vim.api.nvim_get_current_win()
  if chat and vim.api.nvim_win_get_buf(here) == chat.bufnr then
    -- (one that has a window of its own, as `:CodeCompanionChat` gives it: that window closes)
    local own = chat.ui.window_opts and chat.ui.window_opts.layout
      or require("codecompanion.config").display.chat.window.layout
    if own ~= "buffer" then return chat.ui:hide() end
    -- hide it: what the window showed before, else the buffer before this one, else an empty one
    chat.ui:hide { keep_window = true }
    local back = vim.w[here].ai_chat_before
    if not (type(back) == "number" and vim.api.nvim_buf_is_valid(back) and back ~= chat.bufnr) then
      back = vim.fn.bufnr "#"
    end
    if back > 0 and back ~= chat.bufnr and vim.api.nvim_buf_is_valid(back) then
      vim.api.nvim_win_set_buf(here, back)
    else
      -- (not :enew, which keeps the buffer the window has when that one is empty and has no name)
      vim.api.nvim_win_set_buf(here, vim.api.nvim_create_buf(true, false))
    end
    vim.w[here].ai_chat_before = nil
    return
  end
  if chat then
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(win) == chat.bufnr then return vim.api.nvim_set_current_win(win) end
    end
  end
  local win, created = require("user.ai.claude_code").window()
  local before = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_set_current_win(win)
  vim.w[win].ai_chat_before = before
  --- Whether the chat is in `win` now. (CodeCompanion returns no chat when it could not make one.)
  local function show()
    if not chat then return codecompanion.chat { window_opts = as_buffer } ~= nil end
    -- (the buffer it will speak of as #{buffer}: the one it takes the place of)
    local known, context = pcall(function() return require("codecompanion.utils.context").get(before) end)
    if known and context then chat.buffer_context = context end
    chat.ui:show_in_win { winnr = win, toggled = true, window_opts = as_buffer }
    return true
  end
  local ran, shown = pcall(show)
  if ran and shown then return end
  -- (as `launch` in claude_code.lua: a window that was made for the chat goes when there is none)
  if created then pcall(vim.api.nvim_win_close, win, true) end
  if not ran then error(shown, 0) end
end

--- <Leader>AC: Claude Code itself with Claude through the login (it needs `claude`, not the chat bridge). With
--- anything else the CodeCompanion chat: also with Claude by API key, which Claude Code would not be billed to.
function M.open_chat()
  local s = state.load()
  if s.provider == "claude" and s.route ~= "api" then return require("user.ai.claude_code").open() end
  toggle_chat()
end

-- The instructions that go along with every chat, in two optional files: the local model's 8k context only has
-- room for a few lines. They are the rule groups of the same names in lua/plugins/codecompanion.lua.
M.rules_files = {
  editor_local = vim.fn.stdpath "config" .. "/ai-rules-local.md",
  editor_cloud = vim.fn.stdpath "config" .. "/ai-rules-cloud.md",
}

--- The rule group for a chat opened now: it follows the model the chat really talks to, so a chat that stays
--- local while a provider is chosen (no bridge, no key) gets the short local rules.
function M.rules_group() return M.current_chat_adapter() == "ollama" and "editor_local" or "editor_cloud" end

return M
