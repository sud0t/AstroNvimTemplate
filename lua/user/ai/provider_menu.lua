-- <Leader>As: the windows that swap the AI and connect a provider. Claude is connected by a wizard (login,
-- chat bridge, API key), the others with a key that is checked with the provider.
local M = {}

local chat = require "user.ai.chat"
local claude = require "user.ai.claude"
local keys = require "user.ai.keys"
local providers = require "user.ai.providers"
local state = require "user.ai.state"
local windows = require "user.ai.windows"

local function notify(msg, level) vim.notify(msg, level or vim.log.levels.INFO, { title = "AI provider" }) end

---------------------------------------------------------------------------------------------------- status

--- What is set up: `on_status(found)` on the main loop. `found`: { cli, login, plan, bridge } for Claude Code,
--- `key` (there is an Anthropic API key), `keys` = { [provider] = where its key comes from }.
local function status(on_status)
  local found = {
    cli = vim.fn.executable "claude" == 1,
    login = false,
    bridge = chat.bridge_path() ~= nil,
    keys = {},
  }
  local waiting = 2
  local function done()
    waiting = waiting - 1
    if waiting > 0 then return end
    found.key = keys.known_key "claude" ~= nil
    for _, id in ipairs(providers.order) do
      found.keys[id] = select(2, keys.known_key(id))
    end
    on_status(found)
  end
  keys.lookup_keys(done)
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

---------------------------------------------------------------------------------------------------- wizard

local function ask(prompt, options, on_choice)
  windows.options(prompt, options, nil, function(choice)
    if choice ~= nil then on_choice(choice) end -- <Esc> leaves the wizard
  end)
end

local switch

--- Step 3: an API key, optional when the login works. One from the environment is not asked about.
local function wizard_key(found, on_done)
  local function enter()
    keys.enter_key("claude", function(connected)
      if not connected then return wizard_key(found, on_done) end
      found.key = true
      on_done()
    end)
  end
  if found.key then
    local source = select(2, keys.known_key "claude") or "this session"
    if source:sub(1, 1) == "$" then return on_done() end
    return ask(("Anthropic API key (in %s)"):format(source == "keyring" and "the system keyring" or source), {
      { "Keep it", "keep" },
      { "Replace it", "replace" },
      { "Remove it", "remove" },
    }, function(choice)
      if choice == "keep" then return on_done() end
      if choice == "replace" then return enter() end
      keys.remove_key("claude", function(removed)
        if removed then
          found.key = false
          notify "The Anthropic API key is removed."
          local s = state.load()
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
    {
      "Enter an API key" .. (keys.can_store() and " (stored in the system keyring)" or " (for this session)"),
      "enter",
    },
  }, function(choice)
    if choice == "skip" then return on_done() end
    enter()
  end)
end

--- Step 2: the bridge a CodeCompanion chat needs to use the Claude Code login.
local function wizard_bridge(found, on_done)
  local function next_step() wizard_key(found, on_done) end
  if not found.login or found.bridge then return next_step() end
  ask("CodeCompanion chats need a bridge to use the Claude Code login (" .. chat.bridge .. ", a Mason package)", {
    { "Install it with Mason", "install" },
    { "Skip: those chats stay local (<Leader>AC and the other AI actions do not need it)", "skip" },
  }, function(choice)
    if choice == "skip" then return next_step() end
    notify("Installing " .. chat.bridge .. "...")
    local ok, err = pcall(vim.cmd.MasonInstall, chat.bridge)
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
        local installed = chat.bridge_path() ~= nil
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
      on_done(found)
    end)
  end)
end

---------------------------------------------------------------------------------------------------- swap

local routes = { login = "Claude Code login", api = "API key" }

local function short(model) return (claude.models[model].name:gsub("^Claude ", "")) end

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
    state.save { provider = id }
  elseif id == "claude" then
    state.save { provider = id, route = route, model = model }
  else
    state.save { provider = id, models = { [id] = model } }
  end
  local why = chat.apply_to_chat()
  local note = why and ("\nNote: " .. why) or ""
  if id == "ollama" then
    return notify(
      ("AI actions use the local model (%s): nothing leaves this machine.%s"):format(
        require("user.ai.ollama").model,
        note
      )
    )
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

--- Claude's wizard, then the provider window with what it found. (Through the module's table: a test puts a
--- stand-in for the wizard there.)
local function setup_claude() M.setup(menu) end

--- The models of the Claude connection `route`. `back()` reopens the window this one was opened from.
local function claude_models(route, back)
  local s = state.load()
  local active = s.provider == "claude" and s.route == route
  local row = 1
  for i, model in ipairs(claude.order) do
    if model == s.model then row = i end
  end
  windows.choose(
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
  local active, chosen = state.load().provider == id, state.model_id(id)
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
  windows.choose(
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
    keys.enter_key(id, function(connected)
      if not connected then return back() end
      found.keys[id] = select(2, keys.known_key(id))
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
  windows.options(("%s (%s)"):format(provider.name, describe(source)), options, nil, function(choice)
    if not choice then return back() end
    if choice == "models" then return to_models() end
    if choice == "replace" then return connect() end
    keys.remove_key(id, function(removed)
      if removed then
        found.keys[id] = nil
        notify(("The %s key is removed."):format(provider.name))
        if state.load().provider == id then switch "ollama" end
      end
      back()
    end)
  end)
end

--- "Set up provider...": every provider, connected or not. `back()` reopens the provider window.
local function setup_list(found, back, row)
  local login = found.login and ("✓ Claude Code login" .. (found.plan and (" (" .. found.plan .. ")") or ""))
    or (found.cli and "Claude Code: not logged in" or "Claude Code: not installed")
  local key = found.key and ("✓ " .. describe(select(2, keys.known_key "claude") or "this session"))
    or "API key: not set"
  local items = { { id = "claude", name = "Claude", detail = login .. " · " .. key } }
  for _, id in ipairs(providers.order) do
    local source = found.keys[id]
    items[#items + 1] =
      { id = id, name = providers.list[id].name, detail = source and ("✓ " .. describe(source)) or "not set up" }
  end
  windows.choose(
    items,
    {
      prompt = "Set up provider",
      format_item = function(item) return ("%-12s %s"):format(item.name, item.detail) end,
    },
    row,
    function(item, index)
      if not item then return back() end
      if item.id == "claude" then return setup_claude() end
      provider_setup(item.id, found, function() setup_list(found, back, index) end)
    end
  )
end

--- <Leader>As: Local, the connections that are set up (`found`, from `status`), and the setup. The cursor
--- starts on `row`.
function menu(found, row)
  local s = state.load()
  local items = {
    {
      name = "Local",
      detail = require("user.ai.ollama").model .. " · nothing leaves this machine",
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
    local detail = providers.model_name(id, state.model_id(id)) .. " · API key"
    connection({ name = providers.list[id].name, detail = detail, provider = id }, found.keys[id] ~= nil)
  end
  items[#items + 1] = { name = "Set up provider...", detail = "connect a provider, change a key", setup = true }

  local now = state.label()
  if s.provider == "claude" then now = now .. " · " .. routes[s.route] end
  windows.choose(
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
        if not item.connected then return setup_claude() end
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
