-- The providers' API keys. An environment variable wins over the system keyring (`secret-tool`, service
-- nvim-ai). Here a key only reaches curl and secret-tool on stdin: never a command line, never a file.
-- (CodeCompanion's chat hands it to curl in a file: lua/plugins/codecompanion.lua.)
local M = {}

local claude = require "user.ai.claude"
local providers = require "user.ai.providers"

local function notify(msg, level) vim.notify(msg, level or vim.log.levels.INFO, { title = "AI provider" }) end

-- where a provider's key comes from; "claude" stands for the Anthropic API key
local key_spec = { claude = { name = "Anthropic", env = { "ANTHROPIC_API_KEY" }, account = "anthropic-api-key" } }
for id, provider in pairs(providers.list) do
  key_spec[id] = provider
end

local keys = {} -- provider -> { key, source } once found; false once the keyring said it has none
local told = {}
-- Until then (vim.uv.now()) the keyring is left alone: one action asks for its key several times, and each
-- question would wait again. <Leader>As asks all the same.
local quiet_until = 0
-- A "no such key" slower than this (ms) was a dismissed unlock dialog, not an answer: see `took`. A keyring
-- answers within hundredths of a second. Not lower: an "unsure" leaves every key unasked for ten seconds.
local slow = 2000

function M.can_store() return vim.fn.executable "secret-tool" == 1 end

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

--- What `secret-tool lookup` said about the key of `id`, after `waited` ms: "found" or "none", which are
--- remembered, or that the question is still open: "silent", or "unsure" for a "none" that came slowly. A
--- dismissed unlock dialog says "no such key" as well (exit code 1, not a word): only the time tells them apart.
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
function M.known_key(id)
  local key, source = env_key(id)
  if key then return key, source end
  if keys[id] then return keys[id].key, keys[id].source end
end

--- The API key of `id` ("claude": the Anthropic key; otherwise a name in providers.list) and where it comes
--- from ("$NAME", "keyring", "this session"), or nil. Asks the keyring the first time, for up to 5 seconds.
function M.key(id)
  if keys[id] == nil and not env_key(id) and M.can_store() and vim.uv.now() >= quiet_until then
    local started = vim.uv.hrtime()
    took(id, vim.system(keyring("lookup", id), { text = true }):wait(5000), ms_since(started))
  end
  return M.known_key(id)
end

--- The Anthropic API key: $ANTHROPIC_API_KEY, or the one stored in the system keyring.
function M.api_key() return (M.key "claude") end

--- Ask the keyring for every key not known yet, one after the other and without blocking (also for keys it
--- said it does not have: one may have been stored since). Stops at a keyring that does not answer and at a
--- second "unsure"; the first is asked for once more at the end. `on_done()` on the main loop.
function M.lookup_keys(on_done)
  local ids = {}
  if M.can_store() then
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
function M.enter_key(id, on_done)
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
    if not M.can_store() then
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
function M.remove_key(id, on_done)
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

return M
