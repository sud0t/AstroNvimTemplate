-- Which AI the editor's AI actions use, and <Leader>As to swap it:
--   Local    Ollama (nothing leaves the machine)
--   Claude   through the Claude Code login (subscription) or with an Anthropic API key
-- The swap applies to the inline prompt (<Leader>Ai), the review (<Leader>AR), the commit message (<Leader>Ac)
-- and the CodeCompanion chat (<Leader>AC, for chats opened after it). Ghost-text completion (<Leader>Aq) always
-- stays local. The choice is remembered across sessions; every action names the model it is using.
-- <Leader>As runs the setup wizard first when Claude is not set up yet (no login and no API key); the menu has
-- an entry to run it again.
local M = {}

local claude = require "user.claude"
local local_model = "qwen3:4b-instruct"
local bridge = "claude-agent-acp" -- what the CodeCompanion chat talks to Claude Code through (a Mason package)
local keyring = { "service", "nvim-ai", "account", "anthropic-api-key" } -- where `secret-tool` keeps the API key

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
local state -- { provider = "ollama" | "claude", route = "login" | "api", model = "opus" | "sonnet" | "haiku" }

local function load()
  if state then return state end
  state = { provider = "ollama", route = "login", model = "opus" }
  local ok, lines = pcall(vim.fn.readfile, state_file)
  local decoded, saved = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
  if decoded and type(saved) == "table" then
    if saved.provider == "claude" then state.provider = "claude" end
    if saved.route == "api" then state.route = "api" end
    if claude.models[saved.model] then state.model = saved.model end
  end
  return state
end

local function save() pcall(vim.fn.writefile, { vim.json.encode(state) }, state_file) end

function M.is_local() return load().provider == "ollama" end

--- the model in use, for messages: "qwen3:4b-instruct", "Claude Opus 5.5"
function M.label() return M.is_local() and local_model or claude.models[load().model].name end

--- the API id of the Claude model chosen last, for the CodeCompanion chat
function M.claude_model_id() return claude.models[load().model].id end

---------------------------------------------------------------------------------------------------- API key

local api_key -- cached for the session; false: looked up, there is none

--- The Anthropic API key: $ANTHROPIC_API_KEY, or the one the wizard stored in the system keyring.
function M.api_key()
  if api_key == nil then
    api_key = false
    local env = vim.env.ANTHROPIC_API_KEY
    if env and env ~= "" then
      api_key = env
    elseif vim.fn.executable "secret-tool" == 1 then
      local res = vim.system(vim.list_extend({ "secret-tool", "lookup" }, keyring), { text = true }):wait(5000)
      local key = vim.trim(res.stdout or "")
      if res.code == 0 and key ~= "" then api_key = key end
    end
  end
  return api_key or nil
end

---------------------------------------------------------------------------------------------------- status

--- What is set up: `on_status { cli, login, plan, bridge, key }` on the main loop.
local function status(on_status)
  local found = {
    cli = vim.fn.executable "claude" == 1,
    login = false,
    bridge = M.bridge_path() ~= nil,
    key = M.api_key() ~= nil,
  }
  if not found.cli then return on_status(found) end
  vim.system(
    { "claude", "auth", "status" },
    { text = true, timeout = 15000 },
    vim.schedule_wrap(function(res)
      local ok, data = pcall(vim.json.decode, res.stdout or "")
      if ok and type(data) == "table" then
        found.login = data.loggedIn == true
        found.plan = data.subscriptionType
      end
      on_status(found)
    end)
  )
end

---------------------------------------------------------------------------------------------------- chat

--- The CodeCompanion adapter for the chat with the current choice, and why when it is not the chosen provider.
function M.chat_adapter()
  local s = load()
  if s.provider == "ollama" then return "ollama" end
  if s.route == "api" then return "anthropic" end
  if M.bridge_path() then return "claude_code" end
  if M.api_key() then return "anthropic" end
  return "ollama", "the chat stays local: the chat bridge is not installed (<Leader>As, Set up Claude)"
end

local function apply_to_chat()
  local adapter, why = M.chat_adapter()
  if package.loaded["codecompanion"] then require("codecompanion.config").interactions.chat.adapter = adapter end
  return why
end

--- Send a request to the current provider and stream the answer; see lua/user/claude.lua for the callbacks.
--- `request`: { system, messages = { { role, content } }, max_tokens, ollama = { keep_alive, options } }; the
--- `ollama` part only applies to the local model.
function M.chat(request, on_text, on_done)
  local s = load()
  if s.provider == "claude" then
    if s.route == "api" then
      local key = M.api_key()
      if key then return claude.api(request, s.model, key, on_text, on_done) end
      vim.schedule(function() on_done("", { error = "no Anthropic API key (<Leader>As, Set up Claude)" }) end)
      return { cancel = function() end }
    end
    return claude.cli(request, s.model, on_text, on_done)
  end
  local ollama = request.ollama or {}
  local messages = { { role = "system", content = request.system } }
  vim.list_extend(messages, request.messages)
  return require("user.ai_stream").chat({
    model = local_model,
    think = false, -- the tag is the non-thinking variant, but Ollama lists the capability
    keep_alive = ollama.keep_alive or "5m",
    options = vim.tbl_extend("force", { num_predict = request.max_tokens }, ollama.options or {}),
    messages = messages,
  }, on_text, on_done)
end

---------------------------------------------------------------------------------------------------- wizard

local function choose(prompt, options, on_choice)
  vim.ui.select(options, { prompt = prompt, format_item = function(option) return option[1] end }, function(option)
    if option then on_choice(option[2]) end -- <Esc> leaves the wizard
  end)
end

--- Step 3: an API key, optional when the login works.
local function wizard_key(found, on_done)
  if found.key then return on_done() end
  local skip = found.login and "Skip: the Claude Code login is enough" or "Skip"
  local can_store = vim.fn.executable "secret-tool" == 1
  choose("Anthropic API key (billed per token, separate from a subscription)", {
    { skip, "skip" },
    { "Enter an API key" .. (can_store and " (stored in the system keyring)" or " (for this session)"), "enter" },
  }, function(choice)
    if choice == "skip" then return on_done() end
    local key = vim.trim(vim.fn.inputsecret "Anthropic API key: ")
    if key == "" then return on_done() end
    notify "Checking the key..."
    claude.verify_key(key, function(ok, message)
      if not ok then
        notify("The key was not accepted: " .. message, vim.log.levels.ERROR)
        return wizard_key(found, on_done)
      end
      api_key, found.key = key, true
      if not can_store then
        notify "Key accepted, for this session. Set ANTHROPIC_API_KEY to keep it (no `secret-tool` here)."
        return on_done()
      end
      local store = { "secret-tool", "store", "--label=Anthropic API key (Neovim AI)" }
      vim.system(
        vim.list_extend(store, keyring),
        { stdin = key, text = true },
        vim.schedule_wrap(function(res)
          if res.code == 0 then
            notify "Key accepted and stored in the system keyring."
          else
            notify("Key accepted, but storing it failed: " .. vim.trim(res.stderr or ""), vim.log.levels.WARN)
          end
          on_done()
        end)
      )
    end)
  end)
end

--- Step 2: the bridge the CodeCompanion chat needs to use the Claude Code login.
local function wizard_bridge(found, on_done)
  local function next_step() wizard_key(found, on_done) end
  if not found.login or found.bridge then return next_step() end
  choose("The chat needs a bridge to use the Claude Code login (" .. bridge .. ", a Mason package)", {
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
    return choose("Claude Code (the `claude` command) is not installed", {
      { "Use an API key instead", "skip" },
      { "Show how to install it", "install" },
    }, function(choice)
      if choice == "skip" then return next_step() end
      notify "Install Claude Code (https://code.claude.com/docs/en/setup), log in with `claude`, then press <Leader>As."
    end)
  end
  choose("Claude Code is installed but not logged in", {
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
          found.login, found.plan = now.login, now.plan
          if not found.login then notify("Still not logged in.", vim.log.levels.WARN) end
          wizard_login(found.login and found or vim.tbl_extend("force", found, { cli = true }), on_done)
        end)
      end),
    })
  end)
end

--- The setup wizard: Claude Code login, chat bridge, API key. `on_done(found)` when it is through.
function M.setup(on_done)
  status(function(found)
    wizard_login(found, function()
      local ready = {}
      if found.login then ready[#ready + 1] = "the Claude Code login" end
      if found.key then ready[#ready + 1] = "an API key" end
      if #ready == 0 then
        notify("Claude is not set up: the AI actions stay local.", vim.log.levels.WARN)
      else
        notify("Claude is set up with " .. table.concat(ready, " and ") .. ".")
      end
      if on_done then on_done(found) end
    end)
  end)
end

---------------------------------------------------------------------------------------------------- swap

local function menu(found)
  local s = load()
  local entries =
    { { label = "Local   Ollama (" .. local_model .. "), nothing leaves this machine", provider = "ollama" } }
  local function add(route, how)
    for _, model in ipairs { "opus", "sonnet", "haiku" } do
      entries[#entries + 1] = {
        label = ("Claude  %s, %s"):format(claude.models[model].name:gsub("^Claude ", ""), how),
        provider = "claude",
        route = route,
        model = model,
      }
    end
  end
  if found.login then add("login", "Claude Code login") end
  if found.key then add("api", "API key") end
  entries[#entries + 1] = { label = "Set up Claude... (login, chat bridge, API key)", setup = true }

  local function current(entry)
    if entry.setup or entry.provider ~= s.provider then return false end
    return entry.provider == "ollama" or (entry.route == s.route and entry.model == s.model)
  end
  vim.ui.select(entries, {
    prompt = "AI provider (now: " .. M.label() .. ")",
    format_item = function(entry) return (current(entry) and "● " or "  ") .. entry.label end,
  }, function(entry)
    if not entry then return end
    if entry.setup then return M.setup(menu) end
    s.provider = entry.provider
    if entry.provider == "claude" then
      s.route, s.model = entry.route, entry.model
    end
    save()
    local why = apply_to_chat()
    if entry.provider == "ollama" then
      notify("AI actions use the local model (" .. local_model .. ").")
    else
      notify(
        ("AI actions use %s through %s. Code you run them on is sent to Anthropic.%s"):format(
          claude.models[s.model].name,
          s.route == "api" and "the API key" or "the Claude Code login",
          why and ("\nNote: " .. why) or ""
        )
      )
    end
  end)
end

--- <Leader>As
function M.select()
  status(function(found)
    if found.login or found.key then return menu(found) end
    notify "Claude is not set up yet: starting the setup."
    M.setup(function(now)
      if now.login or now.key then menu(now) end
    end)
  end)
end

return M
