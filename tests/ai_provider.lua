-- Tests for <Leader>As and what is behind it in lua/user/ai/: provider_menu.lua (the windows), state.lua (the
-- state file), keys.lua, chat.lua (the chat a choice gets), providers.lua, openai.lua, claude.lua, ollama.lua
-- and stream.lua (what is sent, how an answer is read), what <Leader>Ai, <Leader>Ac and <Leader>AR do around a
-- request, where <Leader>AS opens a file, and the chat adapters in lua/plugins/codecompanion.lua.
--   tests/run.sh ai_provider
-- prints what failed and exits with 1, or "ok". Nothing is sent anywhere: `claude`, `curl`, `secret-tool`, `git`
-- and the pickers are stand-ins, and the state lives in a directory of its own.
-- What this cannot show is what the providers really answer. By hand, for each one you use: connect it in
-- <Leader>As, run <Leader>Ai on a line, and open a chat (<Leader>AC) and ask it which model it is. For Claude
-- through the login, <Leader>AC is Claude Code itself (tests/claude_code.lua) and the chat here is
-- `:CodeCompanionChat`: choose each model in turn and ask a new chat the same.
local uv = vim.uv

local harness = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/harness.lua")
local ok = harness.ok

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

local function has(text, piece) return type(text) == "string" and text:find(piece, 1, true) ~= nil end

---------------------------------------------------------------------------------------------------- stand-ins

local state_file = vim.fn.stdpath "state" .. "/ai_provider.json"
local key_vars = { "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY", "OPENROUTER_API_KEY" }

-- what is installed, logged in and stored: { cli, login, plan, bridge, keyring = { [account] = key } or false,
-- curl = function(url, call) -> { code, stdout, chunks }, git = function(line) -> stdout }
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

--- `claude`, `secret-tool`, `curl` and `git`. Every call but `claude auth status` is recorded in `ran`, a curl
--- call with its url and the request it was given (in a file, or on stdin as Ollama gets it).
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
        if file == "-" then
          call.body = vim.json.decode(opts.stdin)
        elseif file then
          call.body = vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))
        end
      end
      res = vim.tbl_extend("force", res, world.curl and world.curl(call.url, call) or {})
    elseif cmd[1] == "git" then
      res.stdout = world.git and world.git(call.line) or ""
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
--- The row a window starts on, as the picker is told (lua/user/ai/windows.lua); nil: the first.
local function cursor(window)
  local row
  local on_show = vim.tbl_get(window, "opts", "snacks", "on_show")
  if on_show then on_show { list = { view = function(_, r) row = r end } } end
  return row
end

---------------------------------------------------------------------------------------------------- state

local ai = session(nil)
ok("no state: local", ai.is_local() and ai.label() == require("user.ai.ollama").model, ai.label())
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
  shown[1].opts.prompt == "AI provider (now: " .. require("user.ai.ollama").model .. ")",
  shown[1].opts.prompt
)

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
require("user.ai.provider_menu").setup = function(on_done)
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
  "without the bridge the note says which chats stay local",
  has(notes[1], "Note: CodeCompanion chats (:CodeCompanionChat, a selection added with <Leader>Aa) stay local")
    and has(notes[1], "Set up provider"),
  notes[1]
)
-- with a key and no bridge those chats are billed: said, not found out from the invoice
ai = session(nil, { cli = true, login = true }, { ANTHROPIC_API_KEY = "sk-ant-test-key" })
swap(ai, { "Claude Code login", "Opus" })
ok(
  "the login without the bridge, with a key: the note says those chats are billed",
  vim.deep_equal({ (ai.chat_adapter()) }, { "anthropic" })
    and has(notes[1], "Note: CodeCompanion chats use the Anthropic API key, billed per token")
    and has(notes[1], "the chat bridge is not installed"),
  notes[1]
)
ai = session({ provider = "claude", route = "api", model = "opus" }, {})
local stays, why_local = ai.chat_adapter()
ok(
  "Claude by API key without a key: the chat stays local, and says why",
  stays == "ollama" and has(why_local, "no Anthropic API key (<Leader>As, Set up provider)"),
  vim.inspect { stays, why_local }
)

-- a choice that cannot be stored (here: a directory where the state file belongs)
ai = session(nil, { cli = true, login = true, bridge = true })
vim.fn.delete(state_file)
vim.fn.mkdir(state_file, "p")
swap(ai, { "Claude Code login", "Sonnet" })
ok(
  "a choice that cannot be stored: said, with the file's name",
  said("Could not write " .. state_file) and said "holds until Neovim closes",
  all_notes()
)
ok("and it holds for the session", ai.label() == "Claude Sonnet 5.5" and not ai.is_local(), ai.label())
ok("nothing is left beside the file", #vim.fn.glob(state_file .. ".*", true, true) == 0)
vim.fn.delete(state_file, "d")

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
ok("which gets 20 seconds to answer", has(check.line, "--max-time 20"), check.line)
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
ok("the cursor starts on the default", cursor(shown[3] or none) == 2, cursor(shown[3] or none))
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
  (shown[4] or none).opts.prompt == "Set up provider" and cursor(shown[4] or none) == 2
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
local sent = curls()
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
ok(
  "and the API version, as Anthropic's own header and not a bearer token",
  has(call.opts.stdin, 'header = "anthropic-version: 2026-10-21"') and not has(call.opts.stdin, "Authorization"),
  call.opts.stdin
)
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
ok("gives a long answer ten minutes", has(call.line, "--max-time 600"), call.line)
ai = session({ provider = "claude", route = "api", model = "haiku" }, {}, { ANTHROPIC_API_KEY = "sk-ant-test-key" })
_, call = ask(ai)
ok(
  "Haiku has no fallback: neither asked for nor its header sent",
  call.body.model == "claude-haiku-5-5" and call.body.fallbacks == nil and not has(call.opts.stdin, "anthropic-beta"),
  call.opts.stdin
)
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
  "OpenAI: ten minutes for an answer, and no redirect is followed with the key",
  has(call.line, "--max-time 600") and not vim.list_contains(call.cmd, "-L") and not has(call.line, "--location"),
  call.line
)
ok(
  "OpenAI: the key on stdin only",
  not has(call.line, "sk-env-key-1") and has(call.opts.stdin, 'header = "Authorization: Bearer sk-env-key-1"'),
  call.line
)
body = call.body or {}
ok(
  "OpenAI: nothing of Anthropic's goes along",
  not has(call.opts.stdin, "anthropic") and not has(call.opts.stdin, "x-api-key") and body.fallbacks == nil,
  call.opts.stdin
)
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
local reported = false
ai.chat(request, function() end, function() reported = true end).cancel()
vim.wait(50)
ok("a request that could not be sent is cancelled like any other: nothing is reported after it", not reported)

-- which error is the one reported: the first of the stream, then curl's, then the status
local rate_limit = { error = { code = 429, message = "Rate limit exceeded" } }
ai = openrouter(sse { delta "Half", rate_limit, { error = { code = 500, message = "Later trouble" } } })
got = ask(ai)
ok("of two errors in a stream the first is reported", got.info.error == "Rate limit exceeded", vim.inspect(got))
ai = openrouter(vim.tbl_extend("force", sse { delta "Half", rate_limit }, { code = 18 }))
got = ask(ai)
ok("an error in the stream comes before curl's exit code", got.info.error == "Rate limit exceeded", vim.inspect(got))
ai = openrouter { stdout = '{"error":{"code":500,"message":"Upstream is down"}}\n500', code = 22 }
got = ask(ai)
ok("curl's exit code comes before the status", has(got.info.error, "curl exit code 22"), vim.inspect(got))
ai = openrouter(sse { delta "Half", "data: [DONE]" })
got = ask(ai)
ok(
  "[DONE] without a finish reason does not make an answer whole",
  has(got.info.error, "ended the answer before it was finished"),
  vim.inspect(got)
)
-- the key is put into curl's options where it is sent: only one that cannot add options gets that far
ran = {}
local sent_it, refusal = pcall(
  require("user.ai.openai").chat,
  request,
  providers.list.openai,
  { id = "gpt-6.2-sol" },
  'sk-"\nurl = "https://evil.example',
  function() end,
  function() end
)
ok(
  "a key that would add curl options is not sent, whoever hands it over",
  not sent_it and #ran == 0 and not has(tostring(refusal), "evil"),
  tostring(refusal)
)
sent_it, refusal = pcall(
  require("user.ai.openai").verify,
  providers.list.openai,
  'sk-"\nurl = "https://evil.example',
  function() end
)
ok("nor checked with the provider", not sent_it and #ran == 0 and not has(tostring(refusal), "evil"), tostring(refusal))

---------------------------------------------------------------------------------------------------- Claude's API

--- A stream as the Anthropic API sends it: every event under a line with its name.
local function claude_sse(events, status)
  local lines = {}
  for i, event in ipairs(events) do
    lines[i] = type(event) == "table" and ("event: %s\ndata: %s"):format(event.type, vim.json.encode(event)) or event
  end
  return sse(lines, status)
end
local function text_delta(text)
  return { type = "content_block_delta", index = 0, delta = { type = "text_delta", text = text } }
end
local function stopped(reason)
  return { type = "message_delta", delta = { stop_reason = reason }, usage = { output_tokens = 3 } }
end
local message_stop = { type = "message_stop" }
local overloaded = { type = "error", error = { type = "overloaded_error", message = "Overloaded" } }
local function anthropic(answer)
  return session(
    { provider = "claude", route = "api", model = "opus" },
    { curl = function() return answer end },
    { ANTHROPIC_API_KEY = "sk-ant-test-key" }
  )
end

ai = anthropic(claude_sse {
  { type = "message_start", message = { id = "msg_1", role = "assistant", content = {} } },
  { type = "content_block_start", index = 0, content_block = { type = "text", text = "" } },
  { type = "ping" },
  text_delta "Hel",
  text_delta "lo",
  { type = "content_block_stop", index = 0 },
  stopped "end_turn",
  message_stop,
})
got = ask(ai)
ok(
  "Claude: the answer",
  got.text == "Hello" and got.partial == "Hello" and got.info.error == nil and got.info.done_reason == nil,
  vim.inspect(got)
)
-- a gateway ($ANTHROPIC_BASE_URL) may end lines with CR LF and keep the connection open with comments
local behind_gateway = table.concat({
  ": keep-alive",
  "",
  "event: content_block_delta",
  "id: 7",
  "retry: 3000",
  "data: " .. vim.json.encode(text_delta "Hi"),
  "",
  ": keep-alive",
  "event: message_stop",
  "data: " .. vim.json.encode(message_stop),
  "",
  "",
}, "\r\n") .. "\n200"
ai = anthropic { stdout = behind_gateway }
got = ask(ai)
ok(
  "Claude: comments, the other fields of an event and CR LF are passed over",
  got.text == "Hi" and got.info.error == nil,
  vim.inspect(got)
)
ai = anthropic(claude_sse {
  text_delta "Hel",
  { type = "content_block_delta", index = 0, delta = vim.NIL },
  { type = "message_delta", delta = vim.NIL },
  text_delta "lo",
  stopped "end_turn",
  message_stop,
})
got = ask(ai)
ok(
  "Claude: an event whose delta is null is passed over",
  got.text == "Hello" and got.info.error == nil,
  vim.inspect(got)
)
ai = anthropic(claude_sse { text_delta "Cut ", text_delta "off", stopped "max_tokens", message_stop })
got = ask(ai)
ok(
  "Claude: the length limit is reported as such",
  got.text == "Cut off" and got.info.error == nil and got.info.done_reason == "length",
  vim.inspect(got)
)
ai = anthropic(claude_sse { text_delta "Half an ans" })
got = ask(ai)
ok(
  "Claude: a stream that just ends is an error, with what came before it",
  has(got.info.error, "the Anthropic API ended the answer before it was finished") and got.text == "Half an ans",
  vim.inspect(got)
)
ai = anthropic(claude_sse { text_delta "Half", overloaded })
got = ask(ai)
ok(
  "Claude: an error in the middle of the stream",
  got.info.error == "Overloaded" and got.text == "Half",
  vim.inspect(got)
)
ai = anthropic(claude_sse { text_delta "I can", stopped "refusal", message_stop })
got = ask(ai)
ok("Claude: a request it declines", got.info.error == "Claude declined this request", vim.inspect(got))
ai = anthropic(claude_sse { stopped "refusal", overloaded, message_stop })
got = ask(ai)
ok("Claude: the first error is the one reported", got.info.error == "Claude declined this request", vim.inspect(got))
ai = anthropic(vim.tbl_extend("force", claude_sse { text_delta "Half" }, { code = 28 }))
got = ask(ai)
ok(
  "Claude: curl giving up is an error",
  has(got.info.error, "no answer from the Anthropic API (curl exit code 28)"),
  vim.inspect(got)
)
-- an error instead of a stream
ai = anthropic { stdout = "<html>Bad gateway</html>\n502" }
got = ask(ai)
ok(
  "Claude: an error that is not JSON is the status",
  has(got.info.error, "the Anthropic API answered HTTP 502") and got.text == "",
  vim.inspect(got)
)
ai = anthropic {
  stdout = '{\n  "type": "error",\n  "error": {\n    "type": "authentication_error",\n    "message": "invalid x-api-key: sk-ant-test-key"\n  }\n}\n401',
}
got = ask(ai)
ok(
  "Claude: an error over several lines, and the key taken out of it",
  got.info.error == "invalid x-api-key: ***",
  vim.inspect(got)
)
ai = anthropic { stdout = '{"type":"error","error":{"type":"rate_limit_error"}}\n429' }
got = ask(ai)
ok("Claude: an error without a message is its type", got.info.error == "rate_limit_error", vim.inspect(got))

---------------------------------------------------------------------------------------------------- the local model

local ollama_answer = {
  '{"message":{"role":"assistant","content":"<think>one line"}}',
  '{"message":{"role":"assistant","content":" will do</think>Hel"}}',
  '{"message":{"role":"assistant","content":"lo"},"done":true,"done_reason":"stop"}',
}
local in_memory = {
  models = {
    { name = "qwen3:4b-instruct", size = 10, size_vram = 4 },
    { name = "pushed-out:1b", size = 10, size_vram = 4 },
    { name = "on-the-gpu:1b", size = 10, size_vram = 10 },
  },
}
--- Ollama: `answer` are the lines of /api/chat (or what curl ends with).
local function ollama(answer)
  return session(nil, {
    curl = function(url)
      if has(url, "/api/chat") then return answer.code and answer or { stdout = table.concat(answer, "\n") .. "\n" } end
      if has(url, "/api/ps") then return { stdout = vim.json.encode(in_memory) } end
    end,
  })
end
local function called(path)
  return vim.tbl_filter(function(c) return has(c.url, "http://localhost:11434" .. path) end, curls())
end
ai = ollama(ollama_answer)
got = ask(ai)
ok(
  "local: the answer, without the model's thinking",
  got.text == "Hello" and got.info.error == nil and got.info.done_reason == "stop",
  vim.inspect(got)
)
call = called("/api/chat")[1] or { line = "", opts = {}, body = {} }
ok(
  "local: the request goes to Ollama on stdin, with no key and no options for curl",
  vim.deep_equal(call.body, vim.json.decode(call.opts.stdin)) and not has(call.line, "--config"),
  call.line
)
ok(
  "local: the model answers at once, as a stream, and stays loaded for the next action",
  call.body.model == require("user.ai.ollama").model
    and call.body.stream == true
    and call.body.think == false
    and call.body.keep_alive == "5m"
    and call.body.options.num_predict == 16000,
  vim.inspect(call.body)
)
local unloaded = vim.tbl_map(function(c) return vim.json.decode(c.cmd[#c.cmd]) end, called "/api/generate")
ok(
  "local: after the answer, a model that was pushed off the GPU is unloaded; the one in use and one that fits stay",
  vim.deep_equal(unloaded, { { model = "pushed-out:1b", keep_alive = 0 } }),
  vim.inspect(unloaded)
)
ai = ollama { '{"message":{"content":"Half"}}', '{"error":"model requires more system memory"}' }
got = ask(ai)
ok(
  "local: an error in the stream",
  got.info.error == "model requires more system memory" and got.text == "Half",
  vim.inspect(got)
)
ai = ollama { '{"message":{"content":"All of it"}}' }
got = ask(ai)
ok(
  "local: Ollama's answer is over when its stream is: nothing has to say so",
  got.text == "All of it" and got.info.error == nil,
  vim.inspect(got)
)
ai = ollama { code = 7 }
got = ask(ai)
ok("local: Ollama is not running", got.info.error == "no answer from Ollama (is it running?)", vim.inspect(got))

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
world.curl = answers {
  ["api.anthropic.com/v1/models"] = {
    stdout = '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key: sk-ant-wrong-key-9"}}\n401',
  },
}
swap(ai, { "Set up provider...", "Claude", "Replace it", false }, { secrets = { "sk-ant-wrong-key-9" } })
ok(
  "an Anthropic key that is not accepted: the stored one stays",
  world.keyring[ring] == "sk-ant-ring-key-1" and said "The key was not accepted",
  all_notes()
)
ok(
  "Anthropic's message is shown without the key",
  said "invalid x-api-key: ***" and not has(all_notes(), "sk-ant-wrong-key-9"),
  all_notes()
)
ok(
  "the check gets 20 seconds, and the key went in on stdin",
  #curls() == 1 and has(curls()[1].line, "--max-time 20") and not has(curls()[1].line, "sk-ant-wrong-key-9"),
  curls()[1] and curls()[1].line
)
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
  local why
  local ran_it, stand_in = pcall(ai.chat, request, function() end, function(_, info) why = info.error end)
  vim.system = system
  ok(case[1] .. ": a request that cannot start does not raise", ran_it and type(stand_in.cancel) == "function")
  ok(case[1] .. ": nor answer before the caller has its handle", why == nil, why)
  vim.wait(50)
  ok(
    case[1] .. ": it fails as any request does, says why and leaves no file",
    has(why, "ENOENT") and file ~= nil and vim.uv.fs_stat(file) == nil,
    tostring(why)
  )
end

---------------------------------------------------------------------------------------------------- the actions

local function floats()
  return vim.tbl_filter(
    function(win) return vim.api.nvim_win_get_config(win).relative ~= "" end,
    vim.api.nvim_list_wins()
  )
end
--- A new buffer with these lines, in the window.
local function buffer(lines)
  vim.cmd.enew()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  return vim.api.nvim_get_current_buf()
end
local function gits()
  return vim.tbl_filter(function(c) return c.cmd[1] == "git" end, ran)
end
local openai = { provider = "openai", models = { openai = "gpt-6.2-sol" } }
local openai_key = { OPENAI_API_KEY = "sk-env-key-1" }

-- the selection of <Leader>Ai and <Leader>AR
local stream = require "user.ai.stream"
buffer { "one", "two", "three" }
ok("no selection: none", stream.selection() == nil)
vim.cmd "normal! GVgg"
local from, to = stream.selection()
ok(
  "a selection made upwards is first to last all the same, and visual mode is left",
  from == 0 and to == 2 and vim.fn.mode() == "n",
  vim.inspect { from, to, vim.fn.mode() }
)

-- <Leader>Ai
ai = session(openai, {}, openai_key)
buffer { ("x"):rep(150001), "the rest" }
vim.cmd "normal! ggV"
typed = { "shorten it" }
require("user.ai.inline").run()
settle()
ok(
  "inline: a selection that is too long names who it is too long for",
  said(("The selection is too long for %s (150001 characters)"):format(ai.label()))
    and not said "the local model"
    and #curls() == 0,
  all_notes()
)

-- <Leader>AR
local fix = table.concat({
  "**`<module>`**: divides by zero when nothing was counted",
  "> `mean = total / count`",
  "````",
  "total = 10",
  "mean = count > 0 and total / count or 0",
  "print(mean)",
  "````",
}, "\n")
local code = { "total = 10", "mean = total / count", "print(mean)" }
ai = session(openai, { curl = function() return sse { delta(fix), delta("", "stop") } end }, openai_key)
local review = require "user.ai.review"
local closed = buffer(code)
review.run()
ok("review: the answer is shown in a corner window while it is written", #floats() == 1, #floats())
local second = buffer(code) -- (the reviewed buffer leaves the window before the answer is there)
settle()
ok(
  "review: fixes for a buffer that is not on screen wait for it",
  said "1 fixes ready, shown when you return to" and #floats() == 0,
  all_notes()
)
vim.cmd.bdelete { closed, bang = true }
notes = {}
review.run()
ok(
  "review: fixes that waited in a buffer closed since do not block the next review",
  said "Reviewing buffer" and not said "Finish the fixes on screen first",
  all_notes()
)
buffer { "elsewhere" }
settle()
notes = {}
vim.cmd.buffer(closed)
settle()
ok("review: the closed buffer, opened again, does not start the other review's fixes", not said "Fix 1/1", all_notes())
vim.cmd.bwipeout { closed, bang = true }
vim.cmd.bwipeout { second, bang = true }

ai = session(openai, { curl = function() return sse { delta(fix), delta("", "stop") } end }, openai_key)
closed = buffer(code)
require("user.ai.review").run()
second = buffer(code)
vim.cmd.bdelete { closed, bang = true } -- (before the answer is there)
settle()
ok(
  "review: the answer for a buffer that was closed meanwhile is dropped",
  #floats() == 0 and said "Reviewing buffer" and not said "fixes ready",
  all_notes()
)
vim.cmd.bwipeout { closed, bang = true }
vim.cmd.bwipeout { second, bang = true }

ai = session(openai, {}, openai_key)
buffer(code)
local system = vim.system
vim.system = function() error "ENOENT: no such file or directory (cmd): 'curl'" end
local reviewing = pcall(require("user.ai.review").run)
vim.system = system
settle()
ok(
  "review: a request that cannot start is reported, and its window does not stay",
  reviewing and #floats() == 0 and said "Request failed:" and said "ENOENT",
  all_notes()
)
for _, win in ipairs(floats()) do
  vim.api.nvim_win_close(win, true)
end

-- <Leader>Ac
local work = base .. "/work"
vim.fn.mkdir(work .. "/.git", "p")
local staged = true
local patch, subjects = "diff --git a/mean.lua b/mean.lua\n-mean = total / count\n+mean = 0", "Add the mean"
local function git(line)
  if has(line, "rev-parse --show-toplevel") then return work end
  if has(line, "--stat") then return staged and " mean.lua | 2 +-\n 1 file changed" or "" end
  if has(line, "--numstat") then return "1\t1\tmean.lua" end
  if has(line, "--patch") then return patch end
  if has(line, "log -8") then return subjects end
  return ""
end
local subject = sse { delta "Guard the mean against an empty list", delta("", "stop") }
ai = session(openai, { curl = function() return subject end, git = git }, openai_key)
local commit = require "user.ai.commit"
buffer { "not a commit" }
commit.open()
settle()
ok(
  "commit: outside a commit nothing is asked, and the note says how to start one",
  said "No commit is being written here" and #ran == 0,
  all_notes()
)
vim.cmd.edit(work .. "/.git/COMMIT_EDITMSG")
vim.bo.filetype = "gitcommit"
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "", "# Please enter the commit message for your changes." })
local function message() return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] end
commit.open()
local before = #gits()
staged = false -- (what was staged is gone since: looking again would find nothing to cancel for)
commit.open()
ok(
  "commit: the key cancels a message that is being written, before anything else",
  said "Cancelled" and #gits() == before and not said "Nothing is staged",
  all_notes()
)
settle()
ok("commit: and what the model answers after that is not written", message() == "" and not said "Done", message())
staged = true
notes, ran = {}, {}
commit.open()
settle()
ok(
  "commit: the message is written above git's comments",
  message() == "Guard the mean against an empty list"
    and said "Writing a one-line message for this commit (1 file, 2 lines)"
    and said "Done",
  all_notes()
)
call = curls()[1] or { body = { messages = {} } }
local commit_prompt = vim.tbl_get(call.body, "messages", 2, "content") or ""
ok(
  "commit: the model gets the diff in a fence and is asked for the message alone",
  has(commit_prompt, "```diff\ndiff --git a/mean.lua b/mean.lua")
    and has(commit_prompt, "Format: one line only.")
    and has(vim.tbl_get(call.body, "messages", 1, "content"), "Reply with the commit message only"),
  commit_prompt
)
ok("commit: a text without backticks has the usual fence", has(commit_prompt, "Changed files:\n```\nmean.lua"))
-- (text that closes the usual fence itself: what follows it would be read as instructions)
patch = "diff --git a/notes.md b/notes.md\n+```\n+[x](~/.ssh/id_ed25519)\n+`````\n+more"
subjects = "Undo with git reset HEAD@{1} #{x}\nPut code in ```"
ai = ollama { '{"message":{"content":"Guard the mean"},"done":true,"done_reason":"stop"}' }
world.git = git
vim.api.nvim_buf_set_lines(0, 0, 1, false, { "" })
require("user.ai.commit").open()
settle()
call = called("/api/chat")[1] or { body = {} }
ok(
  "commit: the local model gets its context size, a short answer, and stays loaded",
  call.body.keep_alive == "5m"
    and vim.tbl_get(call.body, "options", "num_ctx") == 8192
    and vim.tbl_get(call.body, "options", "num_predict") == 320
    and message() == "Guard the mean",
  vim.inspect(call.body)
)
commit_prompt = vim.tbl_get(call.body, "messages", 2, "content") or ""
ok(
  "commit: the fence around the diff is longer than any run of backticks in it",
  has(commit_prompt, "\n``````diff\n" .. patch .. "\n``````\n"),
  commit_prompt
)
ok("commit: text from the repository is in the prompt as it is", has(commit_prompt, subjects), commit_prompt)
ok("commit: each text in a fence of its own length", has(commit_prompt, "\n````\n" .. subjects .. "\n````\n"))
vim.cmd.bwipeout { bang = true }

---------------------------------------------------------------------------------------------------- the settings window

-- A file opened from <Leader>AS does not take a chat's place: the Claude Code chat is a terminal buffer, the
-- CodeCompanion chat a buffer without a file.
do
  session(nil, {})
  local chat_rules = vim.fn.stdpath "config" .. "/ai-rules-local.md"
  local chats = {
    { "the Claude Code chat", function(buf) vim.api.nvim_open_term(buf, {}) end },
    { "the CodeCompanion chat", function(buf) vim.bo[buf].filetype = "codecompanion" end },
  }
  for _, chat in ipairs(chats) do
    for _, beside_a_file in ipairs { true, false } do
      vim.cmd "silent! %bwipeout!"
      vim.cmd "silent! only"
      local file_win = vim.api.nvim_get_current_win()
      if beside_a_file then vim.cmd.split() end
      local chat_win, chat_buf = vim.api.nvim_get_current_win(), vim.api.nvim_create_buf(false, true)
      vim.api.nvim_win_set_buf(chat_win, chat_buf)
      chat[2](chat_buf)
      picks = { "Chat rules" }
      require("user.ai.settings").open()
      local here = vim.api.nvim_get_current_win()
      ok(
        ("settings: a file opened from %s %s"):format(
          chat[1],
          beside_a_file and "goes to the window that shows a file"
            or "gets a window of its own when no other shows a file"
        ),
        vim.api.nvim_buf_get_name(0) == chat_rules
          and vim.api.nvim_win_is_valid(chat_win)
          and vim.api.nvim_win_get_buf(chat_win) == chat_buf
          and here ~= chat_win
          and (here == file_win) == beside_a_file,
        vim.inspect { vim.api.nvim_buf_get_name(0), here, chat_win, file_win }
      )
    end
  end
  vim.cmd "silent! %bwipeout!"
  vim.cmd "silent! only"
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

-- the providers' key variables are named in several files: each one in every place
local started_without = table
  .concat(vim.fn.readfile(repo .. "/lua/user/ai/claude_code.lua"), "\n")
  :match "\nlocal not_passed = (%b{})" or ""
ok("Claude Code is started without the Anthropic key", has(started_without, '"ANTHROPIC_API_KEY"'), started_without)
for _, id in ipairs(providers.order) do
  for _, name in ipairs(providers.list[id].env) do
    ok("a session of this test starts without $" .. name, vim.list_contains(key_vars, name))
    ok("Claude Code is started without $" .. name, has(started_without, ('"%s"'):format(name)), started_without)
    local for_bridge = adapter.env[name]
    ok("the Claude Code chat gets $" .. name .. " empty", type(for_bridge) == "function" and for_bridge() == "")
  end
end
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
  { curl = answers { ["api.anthropic.com/v1/models"] = { stdout = model_list .. "\n200" } } },
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
-- curl is not installed, and then it is
ai = session(
  { provider = "claude", route = "api", model = "fable" },
  { curl = answers { ["api.anthropic.com/v1/models"] = { stdout = model_list .. "\n200" } } },
  { ANTHROPIC_API_KEY = "sk-ant-test-key" }
)
local chat_models = require("user.ai.claude").chat_models
system = vim.system
vim.system = function() error "ENOENT: no such file or directory (cmd): 'curl'" end
local started, no_curl = pcall(chat_models, "sk-ant-test-key", { async = false })
vim.system = system
ok("a request for the models that cannot start says why", not started and has(no_curl, "ENOENT"), tostring(no_curl))
ran = {}
choices = chat_models("sk-ant-test-key", { async = false })
ok(
  "and the next one is made, not waited for in vain",
  #ran == 1 and vim.tbl_get(choices, "claude-fable-5-2", "meta", "max_tokens") == 128000,
  vim.inspect { #ran, choices }
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
harness.report()
