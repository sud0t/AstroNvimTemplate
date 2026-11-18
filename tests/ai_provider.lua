-- Tests for <Leader>As and the providers behind it: lua/user/ai/init.lua (the windows, the state file, the
-- keys), lua/user/ai/providers.lua, lua/user/ai/openai.lua and lua/user/ai/claude.lua (what is sent, how an
-- answer is read), and the chat adapters in lua/plugins/codecompanion.lua.
--   nvim --clean -i NONE -l ~/.config/nvim/tests/ai_provider.lua
-- prints what failed and exits with 1, or "ok". Nothing is sent anywhere: `claude`, `curl`, `secret-tool` and
-- the pickers are stand-ins, and the state lives in a directory of its own.
-- What this cannot show is what the providers really answer. By hand, for each one you use: connect it in
-- <Leader>As, run <Leader>Ai on a line, and open a chat (<Leader>AC) and ask it which model it is. For Claude
-- through the login: choose each model in turn and ask a new chat the same.
local uv = vim.uv

local repo = vim.fs.dirname(vim.fs.dirname(assert(uv.fs_realpath(debug.getinfo(1, "S").source:sub(2)))))
local plugins = vim.fn.stdpath "data" .. "/lazy"

local base = assert(uv.fs_realpath(assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/ai-provider-test.XXXXXX"))))
vim.env.XDG_CONFIG_HOME = base .. "/config"
vim.env.XDG_DATA_HOME = base .. "/data"
vim.env.XDG_STATE_HOME = base .. "/state"
vim.env.XDG_CACHE_HOME = base .. "/cache"
vim.opt.rtp:prepend(repo)
for _, name in ipairs { "codecompanion.nvim", "plenary.nvim", "astrocore" } do
  vim.opt.rtp:append(plugins .. "/" .. name)
end

local failures, count = {}, 0
local function ok(name, cond, detail)
  count = count + 1
  if not cond then failures[#failures + 1] = name .. (detail ~= nil and ("\n      " .. tostring(detail)) or "") end
end
local function has(text, piece) return type(text) == "string" and text:find(piece, 1, true) ~= nil end

---------------------------------------------------------------------------------------------------- stand-ins

local state_file = vim.fn.stdpath "state" .. "/ai_provider.json"
local key_vars = { "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY", "OPENROUTER_API_KEY" }

-- what is installed, logged in and stored: { cli, login, plan, bridge, keyring = { [account] = key } or false,
-- curl = function(url, call) -> { code, stdout, chunks } }
local world = {}
local shown, picks, typed, secrets, notes, ran = {}, {}, {}, {}, {}, {}

vim.notify = function(msg) notes[#notes + 1] = msg end
-- time, which the tests can let pass: `later(ms)`
local hrtime, uv_now, ahead = vim.uv.hrtime, vim.uv.now, 0
vim.uv.hrtime = function() return hrtime() + ahead * 1e6 end
vim.uv.now = function() return uv_now() + ahead end
local function later(ms) ahead = ahead + ms end
vim.fn.executable = function(name)
  if name == "claude" then return world.cli and 1 or 0 end
  if name == "claude-agent-acp" then return world.bridge and 1 or 0 end
  if name == "secret-tool" then return world.keyring and 1 or 0 end
  return 0
end
vim.fn.exepath = function(name) return "/bin/" .. name end
vim.fn.inputsecret = function() return table.remove(secrets, 1) or "" end
vim.ui.input = function(_, on_confirm) on_confirm(table.remove(typed, 1)) end

--- `claude`, `secret-tool` and `curl`. Every call but `claude auth status` is recorded in `ran`, a curl call
--- with its url and the request it was given.
vim.system = function(cmd, opts, on_exit)
  opts = opts or {}
  local res = { code = 0, signal = 0, stdout = "", stderr = "" }
  local call = { cmd = cmd, opts = opts, line = table.concat(cmd, " ") }
  if cmd[1] == "claude" and cmd[2] == "auth" then
    res.stdout = vim.json.encode { loggedIn = world.login == true, subscriptionType = world.plan }
  elseif cmd[1] == "secret-tool" then
    ran[#ran + 1] = call
    local account = cmd[#cmd]
    if world.keyring_hangs then
      res.code, res.signal = 124, 15
    elseif cmd[2] == "lookup" and world.keyring_locked then
      -- locked, and the question to unlock it is closed after this long: "no such key"
      later(world.keyring_locked)
      res.code = 1
    elseif cmd[2] == "lookup" then
      -- (locked, and unlocked after this long: from then on it answers at once)
      later(world.keyring_unlocks or 0)
      world.keyring_unlocks = nil
      res.stdout = world.keyring[account] or ""
      res.code = world.keyring[account] and 0 or 1
    elseif cmd[2] == "store" then
      world.keyring[account] = opts.stdin
    elseif cmd[2] == "clear" then
      world.keyring[account] = nil
    end
  else
    ran[#ran + 1] = call
    if cmd[1] == "curl" then
      for _, arg in ipairs(cmd) do
        if arg:find "^https?://" then call.url = arg end
        local file = arg:match "^@(.+)$"
        if file then call.body = vim.json.decode(table.concat(vim.fn.readfile(file), "\n")) end
      end
      res = vim.tbl_extend("force", res, world.curl and world.curl(call.url, call) or {})
    end
  end
  for _, chunk in ipairs(res.chunks or {}) do
    opts.stdout(nil, chunk)
  end
  if opts.stdout and res.stdout ~= "" then opts.stdout(nil, res.stdout) end
  if on_exit then on_exit(res) end
  return { wait = function() return res end, kill = function() end }
end

--- The picker: shows what it was given and answers with the next of `picks`: a row number, a piece of the
--- row's text, or false for <Esc>.
vim.ui.select = function(items, opts, on_choice)
  local window = { items = items, opts = opts, text = vim.tbl_map(opts.format_item, items) }
  shown[#shown + 1] = window
  local pick = table.remove(picks, 1)
  local index = type(pick) == "number" and pick or nil
  if type(pick) == "string" then
    for i, text in ipairs(window.text) do
      if not index and has(text, pick) then index = i end
    end
    assert(index, ("no row with %q in:\n%s"):format(pick, table.concat(window.text, "\n")))
  end
  on_choice(index and items[index] or nil, index)
end

--- Wait until nothing happens any more.
local function settle()
  local last
  for _ = 1, 200 do
    vim.wait(15)
    local now = #shown + #notes + #ran
    if now == last then return end
    last = now
  end
end

--- A new session: `saved` is the state file (nil: none), `set_up` the world, `env` the key variables.
local function session(saved, set_up, env)
  for name in pairs(package.loaded) do
    if name:find "^user%.ai" then package.loaded[name] = nil end
  end
  world = set_up or {}
  for _, name in ipairs(key_vars) do
    vim.env[name] = env and env[name] or nil
  end
  vim.fn.mkdir(vim.fs.dirname(state_file), "p")
  vim.fn.delete(state_file)
  if saved then vim.fn.writefile({ type(saved) == "string" and saved or vim.json.encode(saved) }, state_file) end
  shown, picks, typed, secrets, notes, ran = {}, {}, {}, {}, {}, {}
  return require "user.ai"
end
--- <Leader>As with these answers
local function swap(ai, answers, more)
  shown, notes, ran = {}, {}, {}
  picks, typed, secrets = answers, more and more.typed or {}, more and more.secrets or {}
  ai.select()
  settle()
end
local function stored() return vim.json.decode(table.concat(vim.fn.readfile(state_file), "\n")) end
local function rows(window) return window and table.concat(window.text, "\n") or "(no window)" end
local function marked(window)
  local found = {}
  for i, text in ipairs(window and window.text or {}) do
    if has(text, "●") then found[#found + 1] = i end
  end
  return found
end
local none = { opts = { prompt = "" }, items = {}, text = {} }
local function said(piece)
  for _, note in ipairs(notes) do
    if has(note, piece) then return true end
  end
  return false
end
local function all_notes() return table.concat(notes, "\n") end
local function curls()
  return vim.tbl_filter(function(c) return c.cmd[1] == "curl" end, ran)
end
--- The row a window starts on, as the picker is told (lua/user/ai/settings.lua); nil: the first.
local function cursor(window)
  local row
  local on_show = vim.tbl_get(window, "opts", "snacks", "on_show")
  if on_show then on_show { list = { view = function(_, r) row = r end } } end
  return row
end

---------------------------------------------------------------------------------------------------- state

local ai = session(nil)
ok("no state: local", ai.is_local() and ai.label() == ai.local_model(), ai.label())
ai = session { provider = "claude", route = "login", model = "opus" }
ok("an earlier state file", ai.label() == "Claude Opus 5.5" and ai.claude_model() == "opus", ai.label())
ai = session { provider = "claude", route = "api", model = "fable" }
ok(
  "fable",
  ai.label() == "Claude Fable 5.2" and ai.claude_model_id() == "claude-fable-5-2" and ai.claude_model() == "fable"
)
ai = session { provider = "claude", route = "login", model = "gpt-9" }
ok("a Claude model that is not known", ai.claude_model() == "opus", ai.claude_model())
ai = session "{ not json"
ok("a state file that does not parse", ai.is_local())
ai = session { provider = "openai", models = { openai = "gpt-6-luna", gemini = "x y", nope = "m" } }
ok("another provider", not ai.is_local() and ai.label() == "GPT-6 Luna (OpenAI)", ai.label())
ok(
  "a model id that cannot be one falls back to the default",
  ai.model_id "gemini" == "gemini-4-hydrogen",
  ai.model_id "gemini"
)
ai = session { provider = "openai", models = { openai = "ft:custom-model" } }
ok("a model that was typed in is called by its id", ai.label() == "ft:custom-model (OpenAI)", ai.label())
ai = session { provider = "mistral" }
ok("a provider that is not known: local", ai.is_local())

local claude = require "user.ai.claude"
local providers = require "user.ai.providers"
ok("Claude's models", vim.deep_equal(claude.order, { "fable", "opus", "sonnet", "haiku" }))
for _, model in ipairs(claude.order) do
  ok(
    "listed model has an entry: " .. model,
    claude.models[model] and claude.models[model].id and claude.models[model].name
  )
end
ok("every entry is listed", vim.tbl_count(claude.models) == #claude.order)
for _, id in ipairs(providers.order) do
  local p = providers.list[id]
  ok("provider entry: " .. id, p and p.name and p.notice and p.account and p.chat and p.max_tokens and p.verify)
  ok("https: " .. id, p.url:find "^https://[%w%.%-]+/[%w/%.%-]*$" ~= nil and not p.url:find "/$", p.url)
  ok("its default is listed: " .. id, providers.model(id, p.default) ~= nil)
  for _, model in ipairs(p.models) do
    ok("model id: " .. model.id, providers.valid_model_id(model.id))
  end
  for _, name in ipairs(p.env) do
    ok(
      "the chat's commands do not see $" .. name,
      has(table.concat(vim.fn.readfile(repo .. "/srt-ai.json"), "\n"), ('"name": "%s", "mode": "deny"'):format(name))
    )
  end
end
ok("every provider is listed", vim.tbl_count(providers.list) == #providers.order)

for _, key in ipairs { "sk-ant-api03-abc_DEF-123", "AIzaSyA1234567", "sk-or-v1-0123abcd", "a.b+c/d=e:f~g" } do
  ok("a key: " .. key, providers.valid_key(key))
end
for _, key in ipairs {
  "",
  "short",
  'sk-"quoted"',
  "sk two words",
  "sk-line\nurl = x",
  "sk-tab\tx",
  ("k"):rep(600),
  12345678,
  "sk-ünïcode",
} do
  ok("not a key: " .. vim.inspect(key):sub(1, 30), not providers.valid_key(key))
end
for _, id in ipairs {
  "gpt-6.2-sol",
  "deepseek/deepseek-v4:free",
  "ft:gpt-6:org::abc",
  "anthropic/claude-sonnet-5.5",
  "a@b+c_d",
} do
  ok("a model id: " .. id, providers.valid_model_id(id))
end
for _, id in ipairs { "", " x", "a b", 'a"b', "-x", "a\nb", ("m"):rep(201), 7, "a;b", "$(x)" } do
  ok("not a model id: " .. vim.inspect(id):sub(1, 30), not providers.valid_model_id(id))
end

---------------------------------------------------------------------------------------------------- the provider window

ai = session(nil, {})
swap(ai, { false })
ok("nothing set up: one window, no wizard", #shown == 1, #shown)
ok(
  "nothing set up: Local and the setup",
  #shown[1].items == 2 and has(shown[1].text[1], "Local") and has(shown[1].text[2], "Set up provider..."),
  rows(shown[1])
)
ok("nothing set up: Local is marked", vim.deep_equal(marked(shown[1]), { 1 }), rows(shown[1]))
ok(
  "the prompt names what is in use",
  shown[1].opts.prompt == "AI provider (now: " .. ai.local_model() .. ")",
  shown[1].opts.prompt
)
ok("no text says Set up Claude", not has(rows(shown[1]), "Set up Claude"))

ai = session(nil, { cli = true, login = true, plan = "max" })
swap(ai, { false })
ok("login: three rows", #shown[1].items == 3, rows(shown[1]))
ok(
  "login: one Claude row, with the model and the connection",
  shown[1].text[2]:find "Claude%s+Opus 5%.5 · Claude Code login" ~= nil,
  shown[1].text[2]
)
ok("login: models are not listed here", not has(rows(shown[1]), "Sonnet") and not has(rows(shown[1]), "Haiku"))

ai = session(
  { provider = "claude", route = "api", model = "sonnet" },
  { cli = true, login = true },
  { ANTHROPIC_API_KEY = "sk-ant-test-key" }
)
swap(ai, { false })
ok("login and key: four rows", #shown[1].items == 4, rows(shown[1]))
ok(
  "login and key: the connection in use is marked",
  vim.deep_equal(marked(shown[1]), { 3 }) and has(shown[1].text[3], "Sonnet 5.5 · API key"),
  rows(shown[1])
)
ok(
  "the prompt names model and connection",
  shown[1].opts.prompt == "AI provider (now: Claude Sonnet 5.5 · API key)",
  shown[1].opts.prompt
)

ai = session({ provider = "claude", route = "api", model = "fable" }, { cli = true, login = true })
swap(ai, { false })
ok(
  "the connection in use has a row when it is gone",
  #shown[1].items == 4 and has(shown[1].text[3], "API key (not connected"),
  rows(shown[1])
)
ok("and is the one marked", vim.deep_equal(marked(shown[1]), { 3 }), rows(shown[1]))
local wizard = 0
ai.setup = function(on_done)
  wizard = wizard + 1
  on_done { cli = true, login = true, key = true, keys = {} }
end
swap(ai, { "not connected", false })
ok("selecting it runs Claude's setup", wizard == 1 and #shown == 2, ("%d %d"):format(wizard, #shown))
ok("and comes back with what is set up now", not has(rows(shown[2]), "not connected"), rows(shown[2]))

swap(ai, { "Set up provider...", false, false })
local list = shown[2] or none
ok("Set up provider... lists every provider", list.opts.prompt == "Set up provider" and #list.items == 4, rows(list))
ok(
  "with what is set up",
  has(list.text[1], "✓ Claude Code login")
    and has(list.text[1], "API key: not set")
    and has(list.text[2], "not set up"),
  rows(list)
)
ok("<Esc> there goes back", #shown == 3 and (shown[3] or none).opts.prompt:find "^AI provider" ~= nil, #shown)
swap(ai, { "Set up provider...", "Claude", false })
ok(
  "Claude there runs its setup and comes back",
  wizard == 2 and #shown == 3 and shown[3].opts.prompt:find "^AI provider" ~= nil
)

---------------------------------------------------------------------------------------------------- Claude's models

ai = session(
  { provider = "claude", route = "login", model = "opus" },
  { cli = true, login = true },
  { ANTHROPIC_API_KEY = "sk-ant-test-key" }
)
swap(ai, { "Claude Code login", "Fable" })
local models = shown[2] or none
ok("a connection opens its models", vim.deep_equal(models.items, claude.order), rows(models))
ok("the window says whose models", models.opts.prompt == "Claude models · Claude Code login", models.opts.prompt)
ok(
  "in order, with the model in use marked",
  has(models.text[1], "Fable 5.2") and vim.deep_equal(marked(models), { 2 }),
  rows(models)
)
ok("the cursor starts on the model in use", cursor(models) == 2, cursor(models))
ok("no price on the login", not has(rows(models), "price"))
ok(
  "choosing Fable stores it",
  vim.deep_equal(stored(), { provider = "claude", route = "login", model = "fable" }),
  vim.inspect(stored())
)
ok("the state file is whole, with nothing left beside it", #vim.fn.glob(state_file .. ".*", true, true) == 0)
ok(
  "and says where code goes",
  #notes == 1 and has(notes[1], "Claude Fable 5.2 through the Claude Code login") and has(notes[1], "sent to Anthropic"),
  notes[1]
)
ok("without a price note on the login", not has(notes[1], "price"))
ok("the session follows", ai.label() == "Claude Fable 5.2" and ai.claude_model() == "fable" and not ai.is_local())

swap(ai, { "· API key", false, false })
ok(
  "another connection's models: none marked",
  #marked(shown[2]) == 0 and (shown[2] or none).opts.prompt == "Claude models · API key",
  rows(shown[2])
)
ok("the API key's models say what Fable costs", has((shown[2] or none).text[1], "twice Opus's price"), rows(shown[2]))
local again = shown[3] or none
ok("<Esc> there goes back to the providers", #shown == 3 and again.opts.prompt:find "^AI provider" ~= nil, #shown)
ok("on the row it came from", cursor(again) == 3 and has(again.text[3], "· API key"), cursor(again))
ok("with the same rows", #again.items == #shown[1].items)
ok("and changes nothing", stored().route == "login" and stored().model == "fable" and #notes == 0)

swap(ai, { "· API key", "Fable" })
ok("the API key with Fable", vim.deep_equal(stored(), { provider = "claude", route = "api", model = "fable" }))
ok(
  "says it is billed, and Fable's price",
  has(notes[1], "the API key (billed per token)") and has(notes[1], "twice Opus's price"),
  notes[1]
)
swap(ai, { "· API key", "Haiku" })
ok("no price note for the others", stored().model == "haiku" and not has(notes[1], "price"), notes[1])

swap(ai, { "Local" })
ok("Local switches at once", #shown == 1 and stored().provider == "ollama" and ai.is_local())
ok("and keeps the Claude choice for next time", stored().route == "api" and stored().model == "haiku")
ok("and says nothing leaves", has(notes[1], "nothing leaves this machine"), notes[1])

ai = session(nil, { cli = true, login = true })
swap(ai, { "Claude Code login", "Opus" })
ok(
  "without the bridge the note says the chat stays local",
  has(notes[1], "Note: the chat stays local") and has(notes[1], "Set up provider"),
  notes[1]
)

---------------------------------------------------------------------------------------------------- keys

ai = session(nil, {}, { OPENAI_API_KEY = "sk-env-key-1" })
ok(
  "a key from the environment",
  vim.deep_equal({ ai.key "openai" }, { "sk-env-key-1", "$OPENAI_API_KEY" }),
  vim.inspect { ai.key "openai" }
)
ok("the keyring is not asked for it", #ran == 0)
ok("no key for the others", ai.key "gemini" == nil and ai.api_key() == nil)

ai = session(
  nil,
  { keyring = { ["gemini-api-key"] = "AIza-ring-key", ["anthropic-api-key"] = "sk-ant-ring-key" } },
  { GOOGLE_API_KEY = "AIza-env-key" }
)
ok(
  "the second variable of a provider",
  vim.deep_equal({ ai.key "gemini" }, { "AIza-env-key", "$GOOGLE_API_KEY" }),
  vim.inspect { ai.key "gemini" }
)
vim.env.GOOGLE_API_KEY = nil
ok(
  "then the keyring",
  vim.deep_equal({ ai.key "gemini" }, { "AIza-ring-key", "keyring" }),
  vim.inspect { ai.key "gemini" }
)
ok("the Anthropic key", ai.api_key() == "sk-ant-ring-key")
ok(
  "asked by account, the key nowhere in the command",
  ran[1].line == "secret-tool lookup service nvim-ai account gemini-api-key",
  ran[1].line
)
local lookups = #ran
ai.key "gemini"
ai.key "openai"
ai.key "openai"
ok("each key is looked up once, also when there is none", #ran == lookups + 1, #ran - lookups)

ai = session(nil, { keyring = { ["openai-api-key"] = 'sk-"bad" key' } }, { OPENROUTER_API_KEY = "sk or key" })
ok("a variable that cannot be a key is not used", ai.key "openrouter" == nil)
ok(
  "the warning names the variable, not the value",
  said "$OPENROUTER_API_KEY is not used" and not has(all_notes(), "sk or key"),
  all_notes()
)
ok(
  "a keyring entry that cannot be a key is not used",
  ai.key "openai" == nil and said "OpenAI key in the system keyring is not used"
)
ok("nor is its value shown", not has(all_notes(), "bad"))

ai = session(nil, { keyring = {}, keyring_hangs = true })
ok("a keyring that does not answer: no key", ai.key "openai" == nil)
ok(
  "and a warning that says so, once",
  said "keyring did not answer" and ai.key "gemini" == nil and #notes == 1,
  all_notes()
)
ok(
  "it is asked once, not once per key and per call",
  ai.key "openai" == nil and ai.api_key() == nil and ai.key "openrouter" == nil and #ran == 1,
  #ran
)
swap(ai, { false })
ok("<Leader>As asks it once, not once per provider", #ran == 1 and #shown == 1 and #shown[1].items == 2, #ran)
world.keyring_hangs = false
world.keyring["openai-api-key"] = "sk-late-key-1"
ran = {}
ok("then it is left alone for a minute", ai.key "openai" == nil and #ran == 0, #ran)
later(61000)
ok("and asked again after that", ai.key "openai" == "sk-late-key-1" and #ran == 1, #ran)
ai = session(nil, { keyring = {}, keyring_hangs = true })
ai.key "openai"
world.keyring_hangs = false
world.keyring["openai-api-key"] = "sk-late-key-1"
swap(ai, { false })
ok(
  "<Leader>As does not wait for the minute",
  ai.known_key "openai" == "sk-late-key-1" and #shown[1].items == 3,
  rows(shown[1])
)

-- a key that is stored later (by another Neovim): <Leader>As finds it
ai = session(nil, { keyring = {} })
swap(ai, { false })
world.keyring["openai-api-key"] = "sk-late-key-2"
ran = {}
ok("a key the keyring did not have is not asked for by every action", ai.key "openai" == nil and #ran == 0, #ran)
swap(ai, { false })
ok(
  "<Leader>As asks again, and finds a key stored since",
  ai.key "openai" == "sk-late-key-2" and #shown[1].items == 3 and has(shown[1].text[2], "OpenAI"),
  rows(shown[1])
)

-- a locked keyring that asks to be unlocked, where the question is closed: `secret-tool` then says "no such
-- key", after the time a person takes
ai = session(nil, { keyring = { ["openai-api-key"] = "sk-ring-key-1" }, keyring_locked = 4000 })
ok("a keyring that stays locked: no key", ai.key "openai" == nil and #notes == 0, all_notes())
ok("it is not asked again at once", ai.key "openai" == nil and ai.key "gemini" == nil and #ran == 1, #ran)
swap(ai, { false })
ok("<Leader>As: it asks to be unlocked twice at most", #ran == 2 and #shown[1].items == 2, #ran)
world.keyring_locked = nil
swap(ai, { false })
ok(
  "its silence was not taken for an answer: unlocked, the key is there",
  ai.known_key "openai" == "sk-ring-key-1" and #shown[1].items == 3,
  rows(shown[1])
)
-- a keyring that is slow to say no (one that is only just starting) has answered all the same
ai = session(nil, { keyring = { ["openrouter-api-key"] = "sk-or-ring-key" }, keyring_unlocks = 1000 })
ok(
  "a keyring that takes a second to say no has answered: the next key is asked for",
  ai.key "openai" == nil and ai.key "openrouter" == "sk-or-ring-key" and #ran == 2,
  #ran
)
ai = session(nil, { keyring = { ["openrouter-api-key"] = "sk-or-ring-key" }, keyring_unlocks = 4000 })
swap(ai, { false })
ok(
  "a keyring that is unlocked on the way: every key is asked for, the first one again",
  #ran == 5 and #shown[1].items == 3 and has(shown[1].text[2], "OpenRouter"),
  #ran .. "\n" .. rows(shown[1])
)
ran = {}
ok("and what it does not have is remembered", ai.api_key() == nil and ai.key "gemini" == nil and #ran == 0, #ran)
ok(
  "a key that is known is had without asking",
  ai.known_key "openrouter" == "sk-or-ring-key" and ai.known_key "openai" == nil
)

-- <Leader>As asks for all of them at once
ai = session(nil, { keyring = { ["openrouter-api-key"] = "sk-or-ring-key" } }, { OPENAI_API_KEY = "sk-env-key-1" })
swap(ai, { false })
ok(
  "the window: a row per connected provider",
  #shown[1].items == 4 and has(shown[1].text[2], "OpenAI") and has(shown[1].text[3], "OpenRouter"),
  rows(shown[1])
)
ok(
  "with the model each would use",
  has(shown[1].text[2], "GPT-6.2 Sol · API key") and has(shown[1].text[3], "GPT-6.2 Sol · API key"),
  rows(shown[1])
)
local asked = vim.tbl_map(function(call) return call.cmd[#call.cmd] end, ran)
table.sort(asked)
ok(
  "the keyring is asked for the keys that are not in the environment",
  vim.deep_equal(asked, { "anthropic-api-key", "gemini-api-key", "openrouter-api-key" }),
  vim.inspect(asked)
)

---------------------------------------------------------------------------------------------------- connecting a provider

local function answers(by_url)
  return function(url)
    for piece, answer in pairs(by_url) do
      if has(url, piece) then return answer end
    end
    return { code = 7 }
  end
end

ai = session(
  nil,
  { keyring = {}, curl = answers { ["api.openai.com/v1/models"] = { stdout = '{"object":"list","data":[]}\n200' } } }
)
swap(ai, { "Set up provider...", "OpenAI", "Astra" }, { secrets = { "sk-new-openai-key" } })
local check = ran[#ran - 1] or { line = "", opts = {} }
ok("the key is checked with the provider", check.url == "https://api.openai.com/v1/models", check.url)
ok(
  "it goes in on stdin, not on the command line",
  not has(check.line, "sk-new-openai-key")
    and has(check.opts.stdin, 'header = "Authorization: Bearer sk-new-openai-key"'),
  check.line
)
ok(
  "and is stored in the keyring, again on stdin",
  world.keyring["openai-api-key"] == "sk-new-openai-key" and not has(ran[#ran].line, "sk-new-openai-key"),
  ran[#ran].line
)
ok("under a label that says what it is", has(ran[#ran].line, "--label=OpenAI API key (Neovim AI)"), ran[#ran].line)
ok("then its models open", (shown[3] or none).opts.prompt == "OpenAI models", (shown[3] or none).opts.prompt)
ok(
  "the ones listed, and Other...",
  #(shown[3] or none).items == #providers.list.openai.models + 1 and has(rows(shown[3]), "Other..."),
  rows(shown[3])
)
ok("the cursor starts on the default", (shown[3] or none).opts.snacks ~= nil)
ok(
  "choosing one stores provider and model",
  vim.deep_equal(stored(), { provider = "openai", models = { openai = "gpt-6.2-astra" } }),
  vim.inspect(stored())
)
ok(
  "and says where code goes",
  said "AI actions use GPT-6.2 Astra with your OpenAI API key (billed per token). Code you run them on is sent to OpenAI.",
  all_notes()
)
ok("the key is in no message", not has(all_notes(), "sk-new-openai-key"))
ok("the session follows", ai.label() == "GPT-6.2 Astra (OpenAI)" and ai.key "openai" == "sk-new-openai-key")

swap(ai, { false })
ok(
  "the provider now has a row, marked",
  vim.deep_equal(marked(shown[1]), { 2 }) and has(shown[1].text[2], "GPT-6.2 Astra · API key"),
  rows(shown[1])
)
ok("the prompt names it", shown[1].opts.prompt == "AI provider (now: GPT-6.2 Astra (OpenAI))", shown[1].opts.prompt)
swap(ai, { "OpenAI", "Other...", false }, { typed = { "ft:gpt-6:mine" } })
ok(
  "a model id can be typed in",
  stored().models.openai == "ft:gpt-6:mine" and ai.label() == "ft:gpt-6:mine (OpenAI)",
  vim.inspect(stored())
)
swap(ai, { "OpenAI", false, false })
ok(
  "the typed model is listed from then on",
  has(rows(shown[2]), "ft:gpt-6:mine") and has(rows(shown[2]), "typed in") and vim.deep_equal(marked(shown[2]), { 4 }),
  rows(shown[2])
)
swap(ai, { "OpenAI", "Other...", false, false }, { typed = { "not a model; rm -rf" } })
ok(
  "an id that cannot be one is refused",
  stored().models.openai == "ft:gpt-6:mine"
    and said "cannot be a model id"
    and (shown[3] or none).opts.prompt == "OpenAI models",
  all_notes()
)
swap(ai, { "OpenAI", "Other...", false, false }, { typed = {} })
ok(
  "<Esc> in the input goes back to the models",
  (shown[3] or none).opts.prompt == "OpenAI models" and stored().models.openai == "ft:gpt-6:mine"
)

-- the choices of another Neovim, and keys this version does not know, survive a save
vim.fn.writefile({
  vim.json.encode {
    provider = "openai",
    models = { openai = "ft:gpt-6:mine", gemini = "gemini-3.8-flash" },
    later = { 1 },
  },
}, state_file)
swap(ai, { "OpenAI", "Luna" })
ok(
  "a save keeps what else is in the file",
  vim.deep_equal(
    stored(),
    { provider = "openai", models = { openai = "gpt-6-luna", gemini = "gemini-3.8-flash" }, later = { 1 } }
  ),
  vim.inspect(stored())
)

-- replace and remove
swap(ai, { "Set up provider...", "OpenAI", false, false, false })
ok(
  "a connected provider says where its key is",
  has((shown[2] or none).text[2], "✓ key in the system keyring"),
  rows(shown[2])
)
ok(
  "and offers model, replace, remove",
  #(shown[3] or none).items == 3 and (shown[3] or none).opts.prompt == "OpenAI (key in the system keyring)",
  rows(shown[3])
)
ok(
  "<Esc> goes back to the list, on its row",
  (shown[4] or none).opts.prompt == "Set up provider" and (shown[4] or none).opts.snacks ~= nil
)
swap(ai, { "Set up provider...", "OpenAI", "Remove the key", false, false })
ok(
  "removing clears the keyring",
  world.keyring["openai-api-key"] == nil
    and has(ran[#ran].line, "secret-tool clear service nvim-ai account openai-api-key"),
  ran[#ran].line
)
ok(
  "and goes back to local when it was in use",
  stored().provider == "ollama"
    and ai.is_local()
    and said "The OpenAI key is removed"
    and said "nothing leaves this machine",
  all_notes()
)
ok("the list says so", has((shown[4] or none).text[2], "not set up"), rows(shown[4]))
ok("the model chosen for it is kept", stored().models.openai == "gpt-6-luna")

-- a key that is not accepted, or cannot be one
ai = session(nil, {
  keyring = {},
  curl = answers {
    ["openrouter.ai/api/v1/key"] = {
      stdout = '{"error":{"code":401,"message":"No auth credentials found: sk-or-wrong-key-1"}}\n401',
    },
  },
})
swap(ai, { "Set up provider...", "OpenRouter", false, false }, { secrets = { "sk-or-wrong-key-1" } })
local sent = vim.tbl_filter(function(c) return c.cmd[1] == "curl" end, ran)
ok(
  "OpenRouter's key is checked where only a key gets through",
  #sent == 1 and sent[1].url == "https://openrouter.ai/api/v1/key",
  sent[1] and sent[1].url
)
ok(
  "a key that is not accepted is not kept",
  world.keyring["openrouter-api-key"] == nil and ai.key "openrouter" == nil and said "The key was not accepted"
)
ok(
  "the provider's message is shown without the key",
  said "No auth credentials found: ***" and not has(all_notes(), "sk-or-wrong-key-1"),
  all_notes()
)
ok("and the list is back", (shown[3] or none).opts.prompt == "Set up provider")
swap(ai, { "Set up provider...", "Gemini", false, false }, { secrets = { 'AIza"\nurl = "https://evil.example' } })
ok(
  "a key that would add curl options is refused before anything is sent",
  #curls() == 0 and said "cannot be an API key" and not has(all_notes(), "evil"),
  all_notes()
)
world.curl = answers {}
swap(ai, { "Set up provider...", "Gemini", false, false }, { secrets = { "AIza-some-key-1" } })
ok(
  "a provider that cannot be reached",
  said "could not reach generativelanguage.googleapis.com" and ai.key "gemini" == nil,
  all_notes()
)

-- no secret-tool: for this session
ai = session(nil, { curl = answers { ["googleapis.com"] = { stdout = '{"object":"list"}\n200' } } })
swap(ai, { "Set up provider...", "Gemini", "Hydrogen" }, { secrets = { "AIza-session-key" } })
ok(
  "without secret-tool the key holds for the session",
  ai.key "gemini" == "AIza-session-key" and said "for this session. Set GEMINI_API_KEY",
  all_notes()
)
ok("Gemini's notice", said "sent to Google" and said "no billing set up", all_notes())
swap(ai, { "Set up provider...", false, false })
ok("the list says it is for this session", has((shown[2] or none).text[3], "✓ key for this session"), rows(shown[2]))

-- from the environment: nothing to replace or remove here
ai = session(nil, { keyring = {} }, { OPENROUTER_API_KEY = "sk-or-env-key-1" })
swap(ai, { "Set up provider...", "OpenRouter", "Qwen" })
ok(
  "a key from the environment: straight to the models",
  (shown[3] or none).opts.prompt == "OpenRouter models" and said "comes from $OPENROUTER_API_KEY",
  all_notes()
)
ok("OpenRouter's notice", said "sent to OpenRouter and to the provider it routes the request to", all_notes())
ok(
  "stored by its full id",
  stored().models.openrouter == "qwen/qwen4-max" and ai.label() == "Qwen4 Max (OpenRouter)",
  ai.label()
)

---------------------------------------------------------------------------------------------------- what is sent

local request = { system = "sys", messages = { { role = "user", content = "hello" } }, max_tokens = 16000 }
local function ask(module)
  ran = {}
  local got = {}
  module.chat(request, function(text) got.partial = text end, function(text, info)
    got.text, got.info = text, info
  end)
  settle()
  return got, ran[#ran] or { line = "", opts = {} }
end

ai = session({ provider = "claude", route = "login", model = "fable" }, { cli = true, login = true })
local _, call = ask(ai)
local at = vim.fn.index(call.cmd or {}, "--model")
ok(
  "the login runs claude with Fable's id",
  call.cmd[1] == "claude" and at >= 0 and call.cmd[at + 2] == "claude-fable-5-2",
  call.line
)

ai = session({ provider = "claude", route = "api", model = "fable" }, {}, { ANTHROPIC_API_KEY = "sk-ant-test-key" })
_, call = ask(ai)
ok("the API key runs curl", call.cmd[1] == "curl" and call.url == "https://api.anthropic.com/v1/messages", call.line)
ok("the key is not on the command line", not has(call.line, "sk-ant-test-key"))
ok("the key goes in on stdin", has(call.opts.stdin, "x-api-key: sk-ant-test-key"))
ok("with the fallback header", has(call.opts.stdin, "anthropic-beta: server-side-fallback-2026-07-01"), call.opts.stdin)
local body = call.body or {}
ok("the request names Fable", body.model == "claude-fable-5-2", vim.inspect(body))
ok(
  "asks for the fallback and low effort",
  body.fallbacks == "default" and vim.tbl_get(body, "output_config", "effort") == "low"
)
ok(
  "sends no sampling or thinking settings (Fable answers 400 to them)",
  body.temperature == nil and body.top_p == nil and body.top_k == nil and body.thinking == nil
)
ok("has room for thinking and an answer", body.max_tokens == 16000)
ai = session({ provider = "claude", route = "api", model = "fable" }, {})
local got = ask(ai)
ok(
  "without a key: an error that says what to do",
  has(got.info and got.info.error, "no Anthropic API key (<Leader>As, Set up provider)"),
  vim.inspect(got)
)

--- A stream as the provider sends it: `events` are the `data:` payloads (tables are encoded), other strings
--- are sent as they are.
local function sse(events, status)
  local lines = {}
  for _, event in ipairs(events) do
    if type(event) == "table" then
      lines[#lines + 1] = "data: " .. vim.json.encode(event)
    else
      lines[#lines + 1] = event
    end
    lines[#lines + 1] = ""
  end
  local text = table.concat(lines, "\n") .. "\n" .. (status or "200")
  -- in pieces that do not end where the lines do
  return { chunks = { text:sub(1, 37), text:sub(38, 90), text:sub(91) } }
end
local function delta(content, finish)
  return {
    object = "chat.completion.chunk",
    choices = { { index = 0, delta = { content = content }, finish_reason = finish or vim.NIL } },
  }
end
local openai_stream = {
  {
    object = "chat.completion.chunk",
    choices = { { index = 0, delta = { role = "assistant", content = "" }, finish_reason = vim.NIL } },
    obfuscation = "r4N7vQ2m",
  },
  delta "Hel",
  delta "lo",
  { object = "chat.completion.chunk", choices = { { index = 0, delta = vim.empty_dict(), finish_reason = "stop" } } },
  "data: [DONE]",
}

ai = session(
  { provider = "openai", models = { openai = "gpt-6.2-sol" } },
  { curl = function() return sse(openai_stream) end },
  { OPENAI_API_KEY = "sk-env-key-1" }
)
got, call = ask(ai)
ok(
  "OpenAI: the answer",
  got.text == "Hello" and got.partial == "Hello" and got.info.error == nil and got.info.done_reason == nil,
  vim.inspect(got)
)
ok("OpenAI: where it goes", call.url == "https://api.openai.com/v1/chat/completions", call.url)
ok(
  "OpenAI: the key on stdin only",
  not has(call.line, "sk-env-key-1") and has(call.opts.stdin, 'header = "Authorization: Bearer sk-env-key-1"'),
  call.line
)
body = call.body or {}
ok(
  "OpenAI: the request",
  body.model == "gpt-6.2-sol" and body.stream == true and body.max_completion_tokens == 16000 and body.max_tokens == nil,
  vim.inspect(body)
)
ok(
  "OpenAI: the system prompt first",
  vim.deep_equal(body.messages, { { role = "system", content = "sys" }, { role = "user", content = "hello" } }),
  vim.inspect(body.messages)
)
ok("OpenAI: a listed model thinks briefly", body.reasoning_effort == "low")
ok("OpenAI: no sampling settings", body.temperature == nil and body.top_p == nil)

ai = session(
  { provider = "openai", models = { openai = "ft:typed" } },
  { curl = function() return sse(openai_stream) end },
  { OPENAI_API_KEY = "sk-env-key-1" }
)
got, call = ask(ai)
ok(
  "a typed model gets no extra fields",
  call.body.model == "ft:typed" and call.body.reasoning_effort == nil and got.text == "Hello",
  vim.inspect(call.body)
)

ai = session(
  { provider = "gemini" },
  { curl = function() return sse(openai_stream) end },
  { GEMINI_API_KEY = "AIza-env-key" }
)
got, call = ask(ai)
ok(
  "Gemini: where it goes, and its limit field",
  call.url == "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
    and call.body.max_tokens == 16000
    and call.body.model == "gemini-4-hydrogen",
  call.url
)

-- OpenRouter: comments while it waits, a last chunk with the usage that repeats the finish reason
local openrouter_stream = {
  ": OPENROUTER PROCESSING",
  ": OPENROUTER PROCESSING",
  delta "Hi ",
  delta("there", "stop"),
  {
    object = "chat.completion.chunk",
    choices = { { index = 0, delta = { content = "" }, finish_reason = "stop", native_finish_reason = "stop" } },
    usage = { total_tokens = 9 },
  },
  "data: [DONE]",
}
local function openrouter(stream_or_answer)
  return session(
    { provider = "openrouter", models = { openrouter = "anthropic/claude-sonnet-5.5" } },
    { curl = function() return stream_or_answer end },
    { OPENROUTER_API_KEY = "sk-or.env+key-1" }
  )
end
ai = openrouter(sse(openrouter_stream))
got, call = ask(ai)
ok("OpenRouter: the answer, past its comments", got.text == "Hi there" and got.info.error == nil, vim.inspect(got))
ok(
  "OpenRouter: the request",
  call.url == "https://openrouter.ai/api/v1/chat/completions"
    and call.body.model == "anthropic/claude-sonnet-5.5"
    and vim.deep_equal(call.body.reasoning, { effort = "low" }),
  vim.inspect(call.body)
)

-- an error in the middle of a stream, with the status still 200 (the example in OpenRouter's documentation)
ai = openrouter(sse {
  delta "Half an ans",
  {
    id = "gen-abc123",
    object = "chat.completion.chunk",
    created = 1234567890,
    model = "openai/gpt-4o",
    provider = "OpenAI",
    error = { code = 429, message = "Rate limit exceeded", metadata = { error_type = "rate_limit_exceeded" } },
    choices = { { index = 0, delta = { content = "" }, finish_reason = "error" } },
  },
})
got = ask(ai)
ok(
  "an error in the middle of the stream is an error",
  got.info.error == "Rate limit exceeded" and got.text == "Half an ans",
  vim.inspect(got)
)
ai = openrouter(sse { delta "Half", delta("", "error") })
got = ask(ai)
ok(
  "so is a finish reason that is not stop or length",
  has(got.info.error, "OpenRouter ended the answer early (error)"),
  vim.inspect(got)
)
ai = openrouter(sse { delta "Half", delta(" more", "content_filter"), "data: [DONE]" })
got = ask(ai)
ok("a filtered answer", has(got.info.error, "(content_filter)"), vim.inspect(got))
ai = openrouter(sse { delta "Cut ", delta("off", "length"), "data: [DONE]" })
got = ask(ai)
ok(
  "the length limit is reported as such",
  got.info.error == nil and got.info.done_reason == "length" and got.text == "Cut off",
  vim.inspect(got)
)
ai = openrouter(sse { "event: message", "id: 7", "retry: 3000", delta "Hi", delta(" there", "stop"), "data: [DONE]" })
got = ask(ai)
ok(
  "the other fields of an event stream are passed over",
  got.text == "Hi there" and got.info.error == nil,
  vim.inspect(got)
)
ai = openrouter(sse { delta "Half", 'data: [{"error":{"code":503,"message":"The model is overloaded."}}]' })
got = ask(ai)
ok("an error in a list inside the stream", got.info.error == "The model is overloaded.", vim.inspect(got))
ai = openrouter(sse { delta "Half an", delta " answer" })
got = ask(ai)
ok(
  "a stream that just ends is an error",
  has(got.info.error, "ended the answer before it was finished") and got.text == "Half an answer",
  vim.inspect(got)
)
ai = openrouter(vim.tbl_extend("force", sse { delta "Half" }, { code = 28 }))
got = ask(ai)
ok(
  "curl giving up is an error, also after some text",
  has(got.info.error, "no answer from OpenRouter (curl exit code 28)"),
  vim.inspect(got)
)
-- an error instead of a stream
ai = openrouter { stdout = '{"error":{"code":400,"message":"Invalid model specified"}}\n400' }
got = ask(ai)
ok(
  "an HTTP error: the provider's message",
  got.info.error == "Invalid model specified" and got.text == "",
  vim.inspect(got)
)
ai = openrouter {
  stdout = '{\n  "error": {\n    "message": "Incorrect API key provided: sk-or.env+key-1.",\n    "type": "invalid_request_error",\n    "code": "invalid_api_key"\n  }\n}\n401',
}
got = ask(ai)
ok(
  "an error over several lines, and the key taken out of it",
  got.info.error == "Incorrect API key provided: ***.",
  vim.inspect(got)
)
ai = openrouter {
  stdout = '[{"error":{"code":400,"message":"Request contains an invalid argument.","status":"INVALID_ARGUMENT"}}]\n400',
}
got = ask(ai)
ok("an error in a list (seen from Gemini)", got.info.error == "Request contains an invalid argument.", vim.inspect(got))
ai = openrouter { stdout = "<html>Bad gateway</html>\n502" }
got = ask(ai)
ok("an error that is not JSON: the status", has(got.info.error, "OpenRouter answered HTTP 502"), vim.inspect(got))
ai = openrouter { stdout = '{"error":{"code":402,"message":"Insufficient credits"}}\n200' }
got = ask(ai)
ok("an error body with status 200", got.info.error == "Insufficient credits", vim.inspect(got))
ai = session({ provider = "openrouter" }, {})
got = ask(ai)
ok(
  "without a key: an error that says what to do",
  has(got.info.error, "no OpenRouter API key (<Leader>As, Set up provider)") and #ran == 0,
  vim.inspect(got)
)

---------------------------------------------------------------------------------------------------- Claude's setup

local anthropic_ok = answers { ["api.anthropic.com/v1/models"] = { stdout = '{"data":[]}\n200' } }
local ring = "anthropic-api-key"
ai = session(
  { provider = "claude", route = "api", model = "sonnet" },
  { cli = true, login = true, plan = "max", bridge = true, keyring = { [ring] = "sk-ant-ring-key-1" } }
)
swap(ai, { "Set up provider...", "Claude", "Keep it", false })
ok(
  "a stored Anthropic key: the setup asks what to do with it",
  (shown[3] or none).opts.prompt == "Anthropic API key (in the system keyring)" and #shown[3].items == 3,
  (shown[3] or none).opts.prompt
)
ok(
  "keeping it changes nothing",
  world.keyring[ring] == "sk-ant-ring-key-1" and stored().route == "api" and said "the Claude Code login and an API key",
  all_notes()
)
ok("and the providers are back", #shown == 4 and shown[4].opts.prompt:find "^AI provider" ~= nil, #shown)
world.curl = anthropic_ok
swap(ai, { "Set up provider...", "Claude", "Replace it", false }, { secrets = { "sk-ant-new-key-2" } })
ok(
  "replacing it: the new key is checked and stored",
  world.keyring[ring] == "sk-ant-new-key-2" and ai.api_key() == "sk-ant-new-key-2" and #curls() == 1,
  all_notes()
)
ok("and is not shown", not has(all_notes(), "sk-ant-new-key-2"))
swap(ai, { "Set up provider...", "Claude", "Remove it", false })
ok(
  "removing it: gone from the keyring and from the session",
  world.keyring[ring] == nil and ai.api_key() == nil and said "The Anthropic API key is removed"
)
ok(
  "the actions go on through the login, with the same model",
  vim.deep_equal(stored(), { provider = "claude", route = "login", model = "sonnet" })
    and said "through the Claude Code login",
  vim.inspect(stored())
)
ok(
  "and the providers no longer list the key",
  not has(rows(shown[#shown]), "· API key") and said "Claude is set up with the Claude Code login.",
  rows(shown[#shown])
)
ai = session({ provider = "claude", route = "api", model = "opus" }, { keyring = { [ring] = "sk-ant-ring-key-1" } })
swap(ai, { "Set up provider...", "Claude", "Use an API key", "Remove it", false })
ok(
  "removing the key without a login: back to the local model",
  world.keyring[ring] == nil and stored().provider == "ollama" and said "nothing leaves this machine",
  all_notes()
)
ai = session(nil, { cli = true, login = true, bridge = true, keyring = {} }, { ANTHROPIC_API_KEY = "sk-ant-test-key" })
swap(ai, { "Set up provider...", "Claude", false })
ok(
  "a key from the environment is not asked about",
  #shown == 3 and shown[3].opts.prompt:find "^AI provider" ~= nil,
  #shown
)

-- logging in fails, then a key is entered: the setup reports the key (the login runs in a terminal, which
-- is a new buffer here)
ai = session(nil, { cli = true, login = false, keyring = {}, curl = anthropic_ok })
local vim_cmd, terminal = vim.cmd, nil
vim.cmd = setmetatable({ startinsert = function() end }, {
  __call = function(_, text)
    terminal = text
    vim_cmd "enew"
  end,
})
shown, notes, ran = {}, {}, {}
picks = { "Set up provider...", "Claude", "Log in now", "Use an API key", "Enter an API key", false }
secrets = { "sk-ant-new-key-3" }
ai.select()
settle()
vim.cmd = vim_cmd
ok("logging in runs `claude auth login` in a terminal", has(terminal or "", "terminal claude auth login"), terminal)
vim.api.nvim_exec_autocmds("TermClose", { buffer = vim.api.nvim_get_current_buf(), data = { status = 1 } })
settle()
ok("a login that did not happen is said", said "Still not logged in", all_notes())
ok(
  "the key entered after it is what the setup reports",
  world.keyring[ring] == "sk-ant-new-key-3" and said "Claude is set up with an API key.",
  all_notes()
)
ok(
  "and the providers list it",
  has(rows(shown[#shown]), "· API key") and shown[#shown].opts.prompt:find "^AI provider" ~= nil,
  rows(shown[#shown])
)

-- a request that is cancelled: the file with the request does not stay behind
for _, case in ipairs {
  { "OpenAI", { provider = "openai" }, { OPENAI_API_KEY = "sk-env-key-1" } },
  { "Claude", { provider = "claude", route = "api", model = "opus" }, { ANTHROPIC_API_KEY = "sk-ant-test-key" } },
} do
  ai = session(case[2], {}, case[3])
  local system, file = vim.system, nil
  vim.system = function(cmd, _, on_exit)
    for _, arg in ipairs(cmd) do
      file = arg:match "^@(.+)$" or file
    end
    return { kill = function() on_exit { code = 143, signal = 15, stdout = "", stderr = "" } end }
  end
  local answered = false
  local handle = ai.chat(request, function() end, function() answered = true end)
  vim.system = system
  ok(case[1] .. ": the request is in a file while it runs", file ~= nil and vim.uv.fs_stat(file) ~= nil, file)
  handle.cancel()
  vim.wait(50)
  ok(case[1] .. ": cancelled, the file is gone", file ~= nil and vim.uv.fs_stat(file) == nil, file)
  ok(case[1] .. ": and nothing is reported as an answer", answered == false)
  -- curl is not installed: the request does not start, and its file does not stay either
  file = nil
  vim.system = function(cmd)
    for _, arg in ipairs(cmd) do
      file = arg:match "^@(.+)$" or file
    end
    error "ENOENT: no such file or directory (cmd): 'curl'"
  end
  local ran_it, why = pcall(ai.chat, request, function() end, function() end)
  vim.system = system
  ok(
    case[1] .. ": a request that cannot start says why and leaves no file",
    not ran_it and has(tostring(why), "ENOENT") and file ~= nil and vim.uv.fs_stat(file) == nil,
    tostring(why)
  )
end

---------------------------------------------------------------------------------------------------- the chats

local function options() return dofile(repo .. "/lua/plugins/codecompanion.lua").opts(nil, {}) end
local function tools_off(adapter)
  for name, tool in pairs(adapter.available_tools or {}) do
    if tool.enabled ~= false then return false, name end
  end
  return true
end

ai = session({ provider = "claude", route = "login", model = "fable" }, { cli = true, login = true, bridge = true })
local opts = options()
ok(
  "Claude through the login: the chat goes through Claude Code",
  opts.interactions.chat.adapter == "claude_code",
  opts.interactions.chat.adapter
)

--- What the chat bridge offers a session (the shape of its `buildModelConfigOption`)
local function connection(values, current)
  local choices = {}
  for _, value in ipairs(values) do
    choices[#choices + 1] = { value = value, name = value:sub(1, 1):upper() .. value:sub(2) }
  end
  local wanted = {}
  return {
    get_config_options = function()
      return {
        {
          id = "model",
          name = "Model",
          category = "model",
          type = "select",
          currentValue = current,
          options = choices,
        },
      }
    end,
    set_config_option = function(_, id, value) wanted[#wanted + 1] = { id, value } end,
  },
    wanted
end
local apply = require("codecompanion.interactions.chat.acp.defaults").apply
local offered = { "default", "fable", "opus", "sonnet", "haiku" }
local adapter = opts.adapters.acp.claude_code()
local conn, wanted = connection(offered, "default")
apply(adapter, conn)
ok(
  "a new Claude Code chat asks for the chosen model",
  vim.deep_equal(wanted, { { "model", "fable" } }),
  vim.inspect(wanted)
)
conn, wanted = connection(offered, "fable")
apply(adapter, conn)
ok("and for nothing when the session has it already", #wanted == 0, vim.inspect(wanted))
-- the choice changes while CodeCompanion is loaded: asked for when the session starts, not when the adapter
-- was built
swap(ai, { "Claude Code login", "Sonnet" })
conn, wanted = connection(offered, "default")
apply(adapter, conn)
ok("and for the one chosen since", vim.deep_equal(wanted, { { "model", "sonnet" } }), vim.inspect(wanted))
conn, wanted = connection({ "default", "opus", "haiku" }, "default")
require("codecompanion.utils.log").warn = function() end -- (it says so in its log)
apply(adapter, conn)
ok("a model Claude Code does not offer is not asked for", #wanted == 0, vim.inspect(wanted))

-- <Leader>As moves the chat for the chats opened after it, unless the chat is held local because its sandbox
-- is not in place (plugins/codecompanion.lua)
local chat_config = require("codecompanion.config").interactions.chat
local loaded_before = package.loaded["codecompanion"]
package.loaded["codecompanion"] = loaded_before or true
chat_config.adapter = "ollama"
swap(ai, { "Claude Code login", "Opus" })
ok("the chat follows the choice", chat_config.adapter == "claude_code" and not said "Note:", all_notes())
swap(ai, { "Local" })
ok("and back", chat_config.adapter == "ollama")
vim.g.ai_chat_locked = true
swap(ai, { "Claude Code login", "Opus" })
ok("a chat that is held local stays there", chat_config.adapter == "ollama", chat_config.adapter)
ok(
  "and the note says why",
  said "Note: the chat stays local and without tools: its sandbox is not in place",
  all_notes()
)
ok("the other AI actions follow all the same", ai.label() == "Claude Opus 5.5")
vim.g.ai_chat_locked = nil
package.loaded["codecompanion"] = loaded_before

-- Claude with the API key: what the models can do comes from the API, with the key on stdin
local model_list = vim.json.encode {
  data = {
    {
      id = "claude-fable-5-2",
      display_name = "Claude Fable 5.2",
      max_input_tokens = 1000000,
      max_tokens = 128000,
      capabilities = {
        image_input = { supported = true },
        structured_outputs = { supported = true },
        thinking = { supported = true, types = { enabled = { supported = false }, adaptive = { supported = true } } },
        effort = { supported = true, low = { supported = true }, max = { supported = true } },
        context_management = { compact_20260112 = { supported = true } },
      },
    },
  },
  has_more = false,
}
ai = session(
  { provider = "claude", route = "api", model = "fable" },
  { curl = answers { ["api.anthropic.com/v1/models"] = { stdout = model_list } } },
  { ANTHROPIC_API_KEY = "sk-ant-test-key" }
)
opts = options()
ok(
  "Claude with the API key: the chat's adapter",
  opts.interactions.chat.adapter == "anthropic",
  opts.interactions.chat.adapter
)
ran = {}
adapter = opts.adapters.http.anthropic()
ok("with Fable", adapter.schema.model.default == "claude-fable-5-2")
ok("its server-side tools are off", tools_off(adapter) and next(adapter.available_tools) ~= nil)
ok("the models are asked for before a chat takes its settings from them", #ran == 1, #ran)
-- (CodeCompanion asks without `async = false` when a chat is created)
local choices = adapter.schema.model.choices(adapter)
local fable = choices["claude-fable-5-2"] or {}
ok(
  "the models come from the API",
  fable.formatted_name == "Claude Fable 5.2" and vim.tbl_get(fable, "meta", "max_tokens") == 128000,
  vim.inspect(fable)
)
ok(
  "with what they can do",
  vim.tbl_get(fable, "opts", "can_manage_context") == true
    and vim.tbl_get(fable, "opts", "can_reason") == true
    and vim.tbl_get(fable, "opts", "legacy_reasoning") == nil,
  vim.inspect(fable.opts)
)
ok(
  "asked once, with the key on stdin",
  #ran == 1 and not has(ran[1].line, "sk-ant-test-key") and has(ran[1].opts.stdin, "x-api-key: sk-ant-test-key"),
  ran[1] and ran[1].line
)
adapter.schema.model.choices(adapter)
adapter.schema.model.choices(adapter, { async = false })
ok("and not again", #ran == 1, #ran)
ai = session(
  { provider = "claude", route = "api", model = "fable" },
  { curl = answers {} },
  { ANTHROPIC_API_KEY = "sk-ant-test-key" }
)
ran = {}
adapter = options().adapters.http.anthropic()
choices = adapter.schema.model.choices(adapter, { async = false })
ok(
  "when the API cannot be reached the chat knows the four models",
  vim.tbl_count(choices) == 4
    and vim.tbl_get(choices, "claude-fable-5-2", "meta", "max_tokens") == 64000
    and vim.tbl_get(choices, "claude-haiku-5-5", "opts", "can_reason") == true,
  vim.inspect(choices)
)
adapter.schema.model.choices(adapter, { async = false })
options().adapters.http.anthropic()
ok("and does not ask again right away", #ran == 1, #ran)
later(61000)
options().adapters.http.anthropic()
ok("but a minute later", #ran == 2, #ran)
ok(
  "no redirect is followed with the key",
  vim.deep_equal(adapter.raw, { "--max-redirs", "0" }),
  vim.inspect(adapter.raw)
)
-- CodeCompanion asks for the choices several times per chat: that never waits for a keyring
ai = session({ provider = "claude", route = "api", model = "opus" }, { keyring = {}, keyring_hangs = true })
adapter = options().adapters.http.anthropic()
ok("a keyring that does not answer is asked once for the chat", #ran == 1, #ran)
for _ = 1, 5 do
  adapter.schema.model.choices(adapter)
end
ok("and the model list does not ask it at all", #ran == 1, #ran)

-- the other providers
for _, id in ipairs(providers.order) do
  local provider = providers.list[id]
  ai = session({ provider = id }, {}, { [provider.env[1]] = "key-for-" .. id })
  opts = options()
  ok(id .. ": the chat's adapter", opts.interactions.chat.adapter == provider.chat, opts.interactions.chat.adapter)
  adapter = opts.adapters.http[provider.chat]()
  ok(id .. ": its key", adapter.env.api_key() == "key-for-" .. id)
  ok(id .. ": no redirect is followed with it", vim.deep_equal(adapter.raw, { "--max-redirs", "0" }))
  ok(id .. ": its model", adapter.schema.model.default == provider.default, adapter.schema.model.default)
  ok(
    id .. ": it has server-side tools, all off",
    next(adapter.available_tools or {}) ~= nil and tools_off(adapter),
    vim.inspect(adapter.available_tools)
  )
  ok(
    id .. ": the rules for the providers' models",
    ai.rules_group() == "editor_cloud"
      and opts.rules.editor_cloud ~= nil
      and has(opts.rules.editor_cloud.files[1], "ai-rules-cloud.md")
  )
  ai = session({ provider = id }, {})
  local chosen, why = ai.chat_adapter()
  ok(
    id .. ": without a key the chat stays local, and says why",
    chosen == "ollama" and has(why, ("no %s API key"):format(provider.name)),
    why
  )
end

-- no adapter of this CodeCompanion keeps a server-side tool
ai = session(nil, {})
opts = options()
for _, file in ipairs(vim.fn.glob(plugins .. "/codecompanion.nvim/lua/codecompanion/adapters/http/*.lua", false, true)) do
  local name = vim.fn.fnamemodify(file, ":t:r")
  local loaded, plain = pcall(require, "codecompanion.adapters.http." .. name)
  if loaded and type(plain) == "table" and next(plain.available_tools or {}) then
    local ours = opts.adapters.http[name]
    ok(
      "an adapter with server-side tools has them switched off: " .. name,
      type(ours) == "function" and tools_off(ours()),
      name
    )
  end
end

---------------------------------------------------------------------------------------------------- result

vim.fn.delete(base, "rf")
if #failures > 0 then
  print(("%d of %d checks failed:"):format(#failures, count))
  for _, failure in ipairs(failures) do
    print("  - " .. failure)
  end
  os.exit(1)
end
print(("ok: %d checks"):format(count))
