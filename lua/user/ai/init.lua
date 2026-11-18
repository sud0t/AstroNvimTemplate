-- Which AI the editor's AI actions use, and <Leader>As to swap it:
--   Local    Ollama (nothing leaves the machine)
--   Claude   through the Claude Code login (subscription) or with an Anthropic API key
--   others   with an API key: the providers in lua/user/ai/providers.lua (OpenAI, Gemini, OpenRouter)
-- <Leader>As lists Local and one row per connection that is set up; a connection opens its models in a window
-- of their own (<Esc> goes back). "Set up provider..." connects one: for Claude the setup wizard (login, chat
-- bridge, API key), for the others a key, which is checked with the provider and stored in the system keyring.
-- The swap applies to the inline prompt (<Leader>Ai), the review (<Leader>AR), the commit message (<Leader>Ac)
-- and the chat (<Leader>AC: Claude Code in a buffer of its own with Claude through the login, see `open_chat`;
-- else the CodeCompanion chat, for chats opened after the swap). Ghost-text completion (<Leader>Aq) always
-- stays local. The choice is remembered across sessions; every action names the model it is using.
-- Keys: an environment variable wins, then the system keyring (`secret-tool`, service nvim-ai). A key is never
-- written to a file or put on a command line here. (CodeCompanion's chat hands it to curl in a file of
-- Neovim's temporary directory: see plugins/codecompanion.lua.) The commands the chat's tools run under srt see
-- neither the variables nor the keyring nor that directory (srt-ai.json). The Claude Code chat runs under its
-- own settings (~/.claude/settings.json) and gets the other providers' key variables empty.
-- <Leader>AS (lua/user/ai/settings.lua) has the settings of the provider that is active: its chat rules, the
-- local model, how detailed commit messages are.
local M = {}

local claude = require "user.ai.claude"
local providers = require "user.ai.providers"
local bridge = "claude-agent-acp" -- what the CodeCompanion chat talks to Claude Code through (a Mason package)

local function notify(msg, level) vim.notify(msg, level or vim.log.levels.INFO, { title = "AI provider" }) end

--- The chat bridge's executable, or nil when it is not installed. (Mason only puts its bin directory on $PATH
--- once it has loaded, which is after the first file is opened: look there directly too.)
function M.bridge_path()
  if vim.fn.executable(bridge) == 1 then return vim.fn.exepath(bridge) end
  local path = vim.fn.stdpath "data" .. "/mason/bin/" .. bridge
  return vim.fn.executable(path) == 1 and path or nil
end

---------------------------------------------------------------------------------------------------- state

local state_file = vim.fn.stdpath "state" .. "/ai_provider.json"
-- { provider = "ollama" | "claude" | a name in providers.list,
--   route = "login" | "api", model = a name in claude.models   (Claude's connection and model, chosen last),
--   models = { [provider] = model id }                         (the other providers' models, chosen last) }
local state

--- What the state file holds, as it is (a table; empty when there is no file or it does not parse).
local function stored()
  local ok, lines = pcall(vim.fn.readfile, state_file)
  local decoded, saved = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
  return decoded and type(saved) == "table" and saved or {}
end

local function load()
  if state then return state end
  state = { provider = "ollama", route = "login", model = "opus", models = {} }
  local saved = stored()
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
local function save(changes)
  local s, file = load(), stored()
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
  pcall(function()
    vim.fn.mkdir(vim.fs.dirname(state_file), "p")
    -- written beside the file and moved over it: another Neovim never reads half of it
    local beside = ("%s.%d.tmp"):format(state_file, vim.uv.os_getpid())
    vim.fn.writefile({ vim.json.encode(file) }, beside)
    if not vim.uv.fs_rename(beside, state_file) then vim.uv.fs_unlink(beside) end
  end)
end

function M.is_local() return load().provider == "ollama" end

--- the Ollama model the local actions and the local chat use (<Leader>AS, Local model)
function M.local_model() return require("user.ai.settings").get "local_model" end

--- the model id in use with `provider` (a name in providers.list): the one chosen last, or its default
function M.model_id(provider) return load().models[provider] or providers.list[provider].default end

--- the model in use, for messages: "qwen3:4b-instruct", "Claude Opus 5.5", "GPT-6.2 Sol (OpenAI)"
function M.label()
  local s = load()
  if s.provider == "ollama" then return M.local_model() end
  if s.provider == "claude" then return claude.models[s.model].name end
  return ("%s (%s)"):format(providers.model_name(s.provider, M.model_id(s.provider)), providers.list[s.provider].name)
end

--- the API id of the Claude model chosen last, for the CodeCompanion chat with the API key
function M.claude_model_id() return claude.models[load().model].id end

--- its short name ("fable", "opus", ...), which is what Claude Code calls it: for the chat through the login
function M.claude_model() return load().model end

---------------------------------------------------------------------------------------------------- keys

-- where a provider's key comes from; "claude" stands for the Anthropic API key
local key_spec = { claude = { name = "Anthropic", env = { "ANTHROPIC_API_KEY" }, account = "anthropic-api-key" } }
for id, provider in pairs(providers.list) do
  key_spec[id] = provider
end

local keys = {} -- provider -> { key, source } once found; false once the keyring said it has none
local told = {}
-- A keyring that gave no answer is left alone until then (vim.uv.now()): an action asks for its key several
-- times, and each question would wait again. <Leader>As asks all the same.
local quiet_until = 0
-- a "no such key" that took this long (ms) was a person's doing: see `took`. (A keyring answers within a few
-- hundredths of a second, also one that is just starting. Not lower: an answer that counts as a person's
-- keeps every key from being asked for during the ten seconds after it.)
local slow = 2000

local function can_store() return vim.fn.executable "secret-tool" == 1 end

--- A `secret-tool` command for the key of `id`.
local function keyring(action, id, label)
  local cmd = { "secret-tool", action }
  if label then cmd[#cmd + 1] = "--label=" .. label end
  return vim.list_extend(cmd, { "service", "nvim-ai", "account", key_spec[id].account })
end

--- The key of `id` from the environment, and the variable it is in ("$OPENAI_API_KEY"). A value that cannot
--- be a key is passed over, with a warning that names the variable and never the value.
local function env_key(id)
  for _, name in ipairs(key_spec[id].env) do
    local value = vim.env[name]
    if value and value ~= "" then
      if providers.valid_key(value) then return value, "$" .. name end
      if not told[name] then
        told[name] = true
        notify(
          ("$%s is not used: its value cannot be an API key (a space, a quote or another character keys do not have)."):format(
            name
          ),
          vim.log.levels.WARN
        )
      end
    end
  end
end

--- What `secret-tool lookup` said about the key of `id`, after `waited` ms: "found", "none", or that the
--- question is still open: "unsure" or "silent". Only an answer is remembered.
--- `secret-tool` says "no such key" in the same way (exit code 1 and not a word) when a locked keyring asked
--- to be unlocked and the question was closed. A keyring answers at once and a person does not, so a "none"
--- that took its time is "unsure": not remembered, and the keyring is left alone for a moment.
local function took(id, res, waited)
  local key = vim.trim(res.stdout or "")
  if res.code == 0 and key ~= "" then
    if providers.valid_key(key) then
      keys[id] = { key = key, source = "keyring" }
      return "found"
    end
    keys[id] = false
    if not told[id] then
      told[id] = true
      notify(
        ("The %s key in the system keyring is not used: it cannot be an API key. Replace it with <Leader>As, Set up provider."):format(
          key_spec[id].name
        ),
        vim.log.levels.WARN
      )
    end
    return "none"
  elseif res.signal == 0 and res.code ~= 124 and vim.trim(res.stderr or "") == "" then
    if waited >= slow then
      quiet_until = vim.uv.now() + 10000
      return "unsure"
    end
    keys[id] = false
    return "none"
  end
  quiet_until = vim.uv.now() + 60000
  if not told.keyring then
    told.keyring = true
    notify(
      "The system keyring did not answer (is it locked?): the keys stored in it are not used until it does.",
      vim.log.levels.WARN
    )
  end
  return "silent"
end

local function ms_since(started) return (vim.uv.hrtime() - started) / 1e6 end

--- The key of `id` and where it comes from, as far as that is known without asking the keyring.
local function known_key(id)
  local key, source = env_key(id)
  if key then return key, source end
  if keys[id] then return keys[id].key, keys[id].source end
end

--- The key of `id` if it is known already: never asks the keyring, never waits.
function M.known_key(id) return (known_key(id)) end

--- The API key of `id` ("claude": the Anthropic key; otherwise a name in providers.list) and where it comes
--- from ("$NAME", "keyring", "this session"), or nil. Asks the keyring the first time, which can take a moment
--- (up to 5 seconds when it does not answer; then it is not asked again for a minute).
function M.key(id)
  if keys[id] == nil and not env_key(id) and can_store() and vim.uv.now() >= quiet_until then
    local started = vim.uv.hrtime()
    took(id, vim.system(keyring("lookup", id), { text = true }):wait(5000), ms_since(started))
  end
  return known_key(id)
end

--- The Anthropic API key: $ANTHROPIC_API_KEY, or the one stored in the system keyring.
function M.api_key() return (M.key "claude") end

--- Ask the keyring for every key there is none of yet, without blocking and one after the other: a locked
--- keyring that is then unlocked asks once. A key the keyring said it does not have is asked for again: it
--- may have been stored since, or the keyring was locked then. A keyring that does not answer is not asked
--- for the rest; an "unsure" (see `took`: the question to unlock it was closed) is passed over once and asked
--- again at the end, by when the keyring is unlocked, and a second one ends the round: two questions at most.
--- (A question that is closed within two seconds looks like an answer, and the next key asks again.)
--- `on_done()` on the main loop.
local function lookup_keys(on_done)
  local ids = {}
  if can_store() then
    for id in pairs(key_spec) do
      if not keys[id] and not env_key(id) then ids[#ids + 1] = id end
    end
  end
  table.sort(ids)
  local unsure
  local function lookup(i)
    local id = ids[i]
    if not id then return on_done() end
    local started = vim.uv.hrtime()
    vim.system(
      keyring("lookup", id),
      { text = true, timeout = 15000 },
      vim.schedule_wrap(function(res)
        local answer = took(id, res, ms_since(started))
        if answer == "silent" or (answer == "unsure" and unsure) then return on_done() end
        if answer == "unsure" then
          unsure = true
          ids[#ids + 1] = id
        end
        lookup(i + 1)
      end)
    )
  end
  lookup(1)
end

--- Ask for the key of `id`, check it with the provider and keep it: in the keyring, or for this session when
--- there is no `secret-tool`. `on_done(connected)`.
local function enter_key(id, on_done)
  local spec = key_spec[id]
  local key = vim.trim(vim.fn.inputsecret(spec.name .. " API key: "))
  if key == "" then return on_done(false) end
  if not providers.valid_key(key) then
    notify(
      "That cannot be an API key: it has a space, a quote or another character keys do not have.",
      vim.log.levels.ERROR
    )
    return on_done(false)
  end
  notify "Checking the key..."
  local function checked(ok, message)
    if not ok then
      notify("The key was not accepted: " .. message, vim.log.levels.ERROR)
      return on_done(false)
    end
    if not can_store() then
      keys[id] = { key = key, source = "this session" }
      notify(("Key accepted, for this session. Set %s to keep it (no `secret-tool` here)."):format(spec.env[1]))
      return on_done(true)
    end
    vim.system(
      keyring("store", id, spec.name .. " API key (Neovim AI)"),
      { stdin = key, text = true },
      vim.schedule_wrap(function(res)
        local kept = res.code == 0
        keys[id] = { key = key, source = kept and "keyring" or "this session" }
        if kept then
          notify "Key accepted and stored in the system keyring."
        else
          notify(
            "Key accepted for this session, but storing it failed: " .. vim.trim(res.stderr or ""),
            vim.log.levels.WARN
          )
        end
        on_done(true)
      end)
    )
  end
  if id == "claude" then return claude.verify_key(key, checked) end
  require("user.ai.openai").verify(providers.list[id], key, checked)
end

--- Forget the key of `id`, in the keyring too. `on_done(removed)`.
local function remove_key(id, on_done)
  local entry = keys[id]
  if not entry or entry.source ~= "keyring" then
    keys[id] = false
    return on_done(true)
  end
  vim.system(
    keyring("clear", id),
    { text = true },
    vim.schedule_wrap(function(res)
      if res.code ~= 0 then
        notify("The key could not be removed from the keyring: " .. vim.trim(res.stderr or ""), vim.log.levels.ERROR)
        return on_done(false)
      end
      keys[id] = false
      on_done(true)
    end)
  )
end

---------------------------------------------------------------------------------------------------- status

--- What is set up: `on_status(found)` on the main loop. `found`: { cli, login, plan, bridge } for Claude Code,
--- `key` (there is an Anthropic API key), `keys` = { [provider] = where its key comes from }.
local function status(on_status)
  local found = {
    cli = vim.fn.executable "claude" == 1,
    login = false,
    bridge = M.bridge_path() ~= nil,
    keys = {},
  }
  local waiting = 2
  local function done()
    waiting = waiting - 1
    if waiting > 0 then return end
    found.key = known_key "claude" ~= nil
    for _, id in ipairs(providers.order) do
      found.keys[id] = select(2, known_key(id))
    end
    on_status(found)
  end
  lookup_keys(done)
  if not found.cli then return done() end
  vim.system(
    { "claude", "auth", "status" },
    { text = true, timeout = 15000 },
    vim.schedule_wrap(function(res)
      local ok, data = pcall(vim.json.decode, res.stdout or "")
      if ok and type(data) == "table" then
        found.login = data.loggedIn == true
        found.plan = data.subscriptionType
      end
      done()
    end)
  )
end

---------------------------------------------------------------------------------------------------- chat

--- The CodeCompanion adapter for the chat with the current choice, and why when it is not the chosen provider.
function M.chat_adapter()
  local s = load()
  if s.provider == "ollama" then return "ollama" end
  local provider = providers.list[s.provider]
  if provider then
    if M.key(s.provider) then return provider.chat end
    return "ollama", ("the chat stays local: no %s API key (<Leader>As, Set up provider)"):format(provider.name)
  end
  if s.route == "api" then return "anthropic" end
  if M.bridge_path() then return "claude_code" end
  if M.api_key() then return "anthropic" end
  return "ollama", "the chat stays local: the chat bridge is not installed (<Leader>As, Set up provider)"
end

local function apply_to_chat()
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

--- The CodeCompanion chat in a window like a file, and gone again: shown where the cursor is, in place of the
--- buffer that is there, which comes back when it is hidden. Only this chat: the one <Leader>Ac opens for a
--- commit message keeps its split. (Not `CodeCompanionChat Toggle` with the "buffer" layout: that hides the
--- chat by switching whatever window the cursor is in to its alternate buffer, wherever the chat is.)
local function toggle_chat()
  local codecompanion = require "codecompanion"
  local as_buffer = { layout = "buffer" }
  local chat = codecompanion.last_chat()
  local here = vim.api.nvim_get_current_win()
  if chat and vim.api.nvim_win_get_buf(here) == chat.bufnr then
    -- (one that has a window of its own, as the commit message's: that window closes)
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
    -- in another window of this tab: go there
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(win) == chat.bufnr then return vim.api.nvim_set_current_win(win) end
    end
  end
  local win = require("user.ai.claude_code").window()
  local before = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_set_current_win(win)
  vim.w[win].ai_chat_before = before
  if chat then
    -- (the buffer it will speak of as #{buffer}: the one it takes the place of)
    local known, context = pcall(function() return require("codecompanion.utils.context").get(before) end)
    if known and context then chat.buffer_context = context end
    chat.ui:show_in_win { winnr = win, toggled = true, window_opts = as_buffer }
  else
    codecompanion.chat { window_opts = as_buffer }
  end
end

--- <Leader>AC: the chat of the current choice, as a buffer in the current window. With Claude through the
--- Claude Code login that is Claude Code itself, in a terminal buffer with its history beside it
--- (lua/user/ai/claude_code.lua; it needs `claude`, not the chat bridge). With anything else (the local model,
--- a provider's key, Claude by API key, which Claude Code would not be billed to) it is the CodeCompanion
--- chat, shown and hidden in turn.
function M.open_chat()
  local s = load()
  if s.provider == "claude" and s.route ~= "api" then return require("user.ai.claude_code").open() end
  toggle_chat()
end

---------------------------------------------------------------------------------------------------- rules

-- The instructions that go along with every chat, in two files (both optional): the local model's 8k context
-- only has room for a few lines, the providers' models take far more. They are the rule groups of the same
-- names in plugins/codecompanion.lua, which also attach the project's .nvim-ai.md; <Leader>AS opens the one in
-- use.
M.rules_files = {
  editor_local = vim.fn.stdpath "config" .. "/ai-rules-local.md",
  editor_cloud = vim.fn.stdpath "config" .. "/ai-rules-cloud.md",
}

--- The rule group for a chat opened now: it follows the model the chat really talks to, so a chat that stays
--- local while a provider is chosen (no bridge, no key) gets the short local rules.
function M.rules_group() return M.current_chat_adapter() == "ollama" and "editor_local" or "editor_cloud" end

--- Send a request to the current provider and stream the answer; see lua/user/ai/stream.lua for the callbacks.
--- `request`: { system, messages = { { role, content } }, max_tokens, ollama = { keep_alive, options } }; the
--- `ollama` part only applies to the local model.
function M.chat(request, on_text, on_done)
  local s = load()
  local function no_key(name)
    local message = ("no %s API key (<Leader>As, Set up provider)"):format(name)
    vim.schedule(function() on_done("", { error = message }) end)
    return { cancel = function() end }
  end
  if s.provider == "claude" then
    if s.route ~= "api" then return claude.cli(request, s.model, on_text, on_done) end
    local key = M.api_key()
    if not key then return no_key "Anthropic" end
    return claude.api(request, s.model, key, on_text, on_done)
  end
  local provider = providers.list[s.provider]
  if provider then
    local key = M.key(s.provider)
    if not key then return no_key(provider.name) end
    local id = M.model_id(s.provider)
    local model = providers.model(s.provider, id) or { id = id }
    return require("user.ai.openai").chat(request, provider, model, key, on_text, on_done)
  end
  local ollama = request.ollama or {}
  local messages = { { role = "system", content = request.system } }
  vim.list_extend(messages, request.messages)
  return require("user.ai.stream").chat({
    model = M.local_model(),
    think = false, -- the tag is the non-thinking variant, but Ollama lists the capability
    keep_alive = ollama.keep_alive or "5m",
    options = vim.tbl_extend("force", { num_predict = request.max_tokens }, ollama.options or {}),
    messages = messages,
  }, on_text, on_done)
end

---------------------------------------------------------------------------------------------------- wizard

local function ask(prompt, options, on_choice)
  vim.ui.select(options, { prompt = prompt, format_item = function(option) return option[1] end }, function(option)
    if option then on_choice(option[2]) end -- <Esc> leaves the wizard
  end)
end

local switch

--- Step 3: an API key, optional when the login works. One that is there can be replaced or removed, unless it
--- comes from the environment.
local function wizard_key(found, on_done)
  local function enter()
    enter_key("claude", function(connected)
      if not connected then return wizard_key(found, on_done) end
      found.key = true
      on_done()
    end)
  end
  if found.key then
    local source = select(2, known_key "claude") or "this session"
    if source:sub(1, 1) == "$" then return on_done() end
    return ask(("Anthropic API key (in %s)"):format(source == "keyring" and "the system keyring" or source), {
      { "Keep it", "keep" },
      { "Replace it", "replace" },
      { "Remove it", "remove" },
    }, function(choice)
      if choice == "keep" then return on_done() end
      if choice == "replace" then return enter() end
      remove_key("claude", function(removed)
        if removed then
          found.key = false
          notify "The Anthropic API key is removed."
          local s = load()
          if s.provider == "claude" and s.route == "api" then
            if found.login then
              switch("claude", "login", s.model)
            else
              switch "ollama"
            end
          end
        end
        on_done()
      end)
    end)
  end
  local skip = found.login and "Skip: the Claude Code login is enough" or "Skip"
  ask("Anthropic API key (billed per token, separate from a subscription)", {
    { skip, "skip" },
    { "Enter an API key" .. (can_store() and " (stored in the system keyring)" or " (for this session)"), "enter" },
  }, function(choice)
    if choice == "skip" then return on_done() end
    enter()
  end)
end

--- Step 2: the bridge the CodeCompanion chat needs to use the Claude Code login.
local function wizard_bridge(found, on_done)
  local function next_step() wizard_key(found, on_done) end
  if not found.login or found.bridge then return next_step() end
  ask("The chat needs a bridge to use the Claude Code login (" .. bridge .. ", a Mason package)", {
    { "Install it with Mason", "install" },
    { "Skip: the chat stays local (inline prompt, review and commit message do not need it)", "skip" },
  }, function(choice)
    if choice == "skip" then return next_step() end
    notify("Installing " .. bridge .. "...")
    local ok, err = pcall(vim.cmd.MasonInstall, bridge)
    if not ok then
      notify("Mason could not start the install: " .. tostring(err), vim.log.levels.ERROR)
      return next_step()
    end
    local deadline = vim.uv.now() + 180000
    local timer = assert(vim.uv.new_timer())
    timer:start(
      1000,
      1000,
      vim.schedule_wrap(function()
        local installed = M.bridge_path() ~= nil
        if not installed and vim.uv.now() < deadline then return end
        timer:stop()
        timer:close()
        found.bridge = installed
        if installed then
          notify "Chat bridge installed."
        else
          notify("The chat bridge is not installed yet: see :Mason", vim.log.levels.WARN)
        end
        next_step()
      end)
    )
  end)
end

--- Step 1: the `claude` command and its login.
local function wizard_login(found, on_done)
  local function next_step() wizard_bridge(found, on_done) end
  if found.login then
    notify("Claude Code is logged in" .. (found.plan and (" (" .. found.plan .. " plan)") or "") .. ".")
    return next_step()
  end
  if not found.cli then
    return ask("Claude Code (the `claude` command) is not installed", {
      { "Use an API key instead", "skip" },
      { "Show how to install it", "install" },
    }, function(choice)
      if choice == "skip" then return next_step() end
      notify "Install Claude Code (https://code.claude.com/docs/en/setup), log in with `claude`, then press <Leader>As."
    end)
  end
  ask("Claude Code is installed but not logged in", {
    { "Log in now (opens a terminal)", "login" },
    { "Use an API key instead", "skip" },
  }, function(choice)
    if choice == "skip" then return next_step() end
    vim.cmd "botright 15split | terminal claude auth login"
    local term = vim.api.nvim_get_current_buf()
    vim.cmd.startinsert()
    vim.api.nvim_create_autocmd("TermClose", {
      buffer = term,
      once = true,
      callback = vim.schedule_wrap(function()
        if vim.api.nvim_buf_is_valid(term) then vim.api.nvim_buf_delete(term, { force = true }) end
        status(function(now)
          -- (`found` itself goes on: what the next steps find out is what M.setup reports)
          found.login, found.plan, found.cli = now.login, now.plan, true
          if not found.login then notify("Still not logged in.", vim.log.levels.WARN) end
          wizard_login(found, on_done)
        end)
      end),
    })
  end)
end

--- Claude's setup wizard: Claude Code login, chat bridge, API key. `on_done(found)` when it is through.
function M.setup(on_done)
  status(function(found)
    wizard_login(found, function()
      local ready = {}
      if found.login then ready[#ready + 1] = "the Claude Code login" end
      if found.key then ready[#ready + 1] = "an API key" end
      if #ready == 0 then
        notify("Claude is not set up: the AI actions stay as they are.", vim.log.levels.WARN)
      else
        notify("Claude is set up with " .. table.concat(ready, " and ") .. ".")
      end
      if on_done then on_done(found) end
    end)
  end)
end

---------------------------------------------------------------------------------------------------- swap

local routes = { login = "Claude Code login", api = "API key" }

local function short(model) return (claude.models[model].name:gsub("^Claude ", "")) end

--- vim.ui.select with the cursor on `row` (lua/user/ai/settings.lua)
local function choose(items, opts, row, on_choice) require("user.ai.settings").choose(items, opts, row, on_choice) end

--- Where a key comes from, in words.
local function describe(source)
  if source == "keyring" then return "key in the system keyring" end
  if source == "this session" then return "key for this session" end
  return "key from " .. source
end

--- Use `id` from now on ("ollama"; "claude" through `route` with `model`; a name in providers.list with the
--- model id `model`), and say where code goes from here on.
function switch(id, route, model)
  if id == "ollama" then
    save { provider = id }
  elseif id == "claude" then
    save { provider = id, route = route, model = model }
  else
    save { provider = id, models = { [id] = model } }
  end
  local why = apply_to_chat()
  local note = why and ("\nNote: " .. why) or ""
  if id == "ollama" then
    return notify(("AI actions use the local model (%s): nothing leaves this machine.%s"):format(M.local_model(), note))
  end
  if id == "claude" then
    local entry = claude.models[model]
    return notify(
      ("AI actions use %s through %s. Code you run them on is sent to Anthropic.%s%s"):format(
        entry.name,
        route == "api" and "the API key (billed per token)" or "the Claude Code login",
        route == "api" and entry.api_note and ("\n" .. short(model) .. " is " .. entry.api_note .. ".") or "",
        note
      )
    )
  end
  local provider = providers.list[id]
  notify(
    ("AI actions use %s with your %s API key (billed per token). %s%s"):format(
      providers.model_name(id, model),
      provider.name,
      provider.notice,
      note
    )
  )
end

local menu

--- The models of the Claude connection `route`. `back()` reopens the window this one was opened from.
local function claude_models(route, back)
  local s = load()
  local active = s.provider == "claude" and s.route == route
  local row = 1
  for i, model in ipairs(claude.order) do
    if model == s.model then row = i end
  end
  choose(
    claude.order,
    {
      prompt = "Claude models · " .. routes[route],
      format_item = function(model)
        local entry = claude.models[model]
        local note = entry.note or ""
        if route == "api" and entry.api_note then note = note .. " · " .. entry.api_note end
        return ("%s %-11s %s"):format(active and model == s.model and "●" or " ", short(model), note)
      end,
    },
    row,
    function(model)
      if not model then return back() end
      switch("claude", route, model)
    end
  )
end

--- The models of `id` (a name in providers.list): the ones listed for it, the one typed in last, and "Other...".
local function provider_models(id, back)
  local provider = providers.list[id]
  local active, chosen = load().provider == id, M.model_id(id)
  local items, row = {}, 1
  for i, model in ipairs(provider.models) do
    items[i] = model
    if model.id == chosen then row = i end
  end
  if not providers.model(id, chosen) then
    items[#items + 1] = { id = chosen, name = chosen, note = "typed in" }
    row = #items
  end
  items[#items + 1] = { other = true }
  choose(
    items,
    {
      prompt = provider.name .. " models",
      format_item = function(model)
        if model.other then return "  Other...           type a model id" end
        return ("%s %-18s %s"):format(active and model.id == chosen and "●" or " ", model.name, model.note or "")
      end,
    },
    row,
    function(model)
      if not model then return back() end
      if not model.other then return switch(id, nil, model.id) end
      vim.ui.input({ prompt = provider.name .. " model id: " }, function(typed)
        typed = vim.trim(typed or "")
        if typed == "" then return provider_models(id, back) end
        if not providers.valid_model_id(typed) then
          notify("That cannot be a model id (letters, digits and . _ : / @ + - only).", vim.log.levels.ERROR)
          return provider_models(id, back)
        end
        switch(id, nil, typed)
      end)
    end
  )
end

--- Connect `id` (a name in providers.list), or change how it is connected. `found` is updated in place.
local function provider_setup(id, found, back)
  local provider = providers.list[id]
  local function to_models() provider_models(id, back) end
  local function connect()
    enter_key(id, function(connected)
      if not connected then return back() end
      found.keys[id] = select(2, known_key(id))
      to_models()
    end)
  end
  local source = found.keys[id]
  if not source then return connect() end
  if source:sub(1, 1) == "$" then
    notify(("The %s key comes from %s in your environment."):format(provider.name, source))
    return to_models()
  end
  local options = { { "Choose a model", "models" }, { "Replace the key", "replace" }, { "Remove the key", "remove" } }
  choose(
    options,
    {
      prompt = ("%s (%s)"):format(provider.name, describe(source)),
      format_item = function(option) return option[1] end,
    },
    nil,
    function(option)
      if not option then return back() end
      if option[2] == "models" then return to_models() end
      if option[2] == "replace" then return connect() end
      remove_key(id, function(removed)
        if removed then
          found.keys[id] = nil
          notify(("The %s key is removed."):format(provider.name))
          if load().provider == id then switch "ollama" end
        end
        back()
      end)
    end
  )
end

--- "Set up provider...": every provider, connected or not. `back()` reopens the provider window.
local function setup_list(found, back, row)
  local login = found.login and ("✓ Claude Code login" .. (found.plan and (" (" .. found.plan .. ")") or ""))
    or (found.cli and "Claude Code: not logged in" or "Claude Code: not installed")
  local key = found.key and ("✓ " .. describe(select(2, known_key "claude") or "this session")) or "API key: not set"
  local items = { { id = "claude", name = "Claude", detail = login .. " · " .. key } }
  for _, id in ipairs(providers.order) do
    local source = found.keys[id]
    items[#items + 1] =
      { id = id, name = providers.list[id].name, detail = source and ("✓ " .. describe(source)) or "not set up" }
  end
  choose(
    items,
    {
      prompt = "Set up provider",
      format_item = function(item) return ("%-12s %s"):format(item.name, item.detail) end,
    },
    row,
    function(item, index)
      if not item then return back() end
      if item.id == "claude" then return M.setup(menu) end
      provider_setup(item.id, found, function() setup_list(found, back, index) end)
    end
  )
end

--- <Leader>As: Local, the connections that are set up (`found`, from `status`), and the setup. The cursor
--- starts on `row`.
function menu(found, row)
  local s = load()
  local items = {
    {
      name = "Local",
      detail = M.local_model() .. " · nothing leaves this machine",
      provider = "ollama",
      active = s.provider == "ollama",
    },
  }
  local function connection(item, connected)
    item.active = s.provider == item.provider and (item.provider ~= "claude" or s.route == item.route)
    -- the connection in use has a row even when it is gone, so that the ● is always somewhere
    if not connected and not item.active then return end
    item.connected = connected
    if not connected then item.detail = item.detail .. " (not connected: select to set up)" end
    items[#items + 1] = item
  end
  for _, route in ipairs { "login", "api" } do
    local item =
      { name = "Claude", detail = short(s.model) .. " · " .. routes[route], provider = "claude", route = route }
    connection(item, route == "login" and found.login or route == "api" and found.key)
  end
  for _, id in ipairs(providers.order) do
    local detail = providers.model_name(id, M.model_id(id)) .. " · API key"
    connection({ name = providers.list[id].name, detail = detail, provider = id }, found.keys[id] ~= nil)
  end
  items[#items + 1] = { name = "Set up provider...", detail = "connect a provider, change a key", setup = true }

  local now = M.label()
  if s.provider == "claude" then now = now .. " · " .. routes[s.route] end
  choose(
    items,
    {
      prompt = "AI provider (now: " .. now .. ")",
      format_item = function(item)
        return ("%s %-19s %s%s"):format(
          item.active and "●" or " ",
          item.name,
          item.detail,
          item.connected and "  ›" or ""
        )
      end,
    },
    row,
    function(item, index)
      if not item then return end
      local function back() menu(found, index) end
      if item.provider == "ollama" then return switch "ollama" end
      if item.setup then return setup_list(found, back) end
      if item.provider == "claude" then
        if not item.connected then return M.setup(menu) end
        return claude_models(item.route, back)
      end
      if not item.connected then return provider_setup(item.provider, found, back) end
      provider_models(item.provider, back)
    end
  )
end

--- <Leader>As
function M.select() status(menu) end

return M
