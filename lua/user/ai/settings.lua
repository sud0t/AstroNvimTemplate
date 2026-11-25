-- <Leader>AS: the AI settings (chat rules, project rules, tags in a message, tool sandbox), and their store.
-- Values live in stdpath("state")/ai_settings.json, not in the configuration: they are per machine. Only
-- values that differ from the defaults are stored, unknown keys are kept for other checkouts, and every value
-- is validated when read, so a damaged file only means the defaults.
-- The local model, context size, temperature and length limits are not settings: they were measured per action.
local M = {}

local json_file = require "user.ai.json_file"
local project_rules = require "user.ai.project_rules"
local windows = require "user.ai.windows"

M.file = vim.fn.stdpath "state" .. "/ai_settings.json"

local schema = {
  -- ask: a tag in a chat message (@{tool}, #{context}) that is new to the chat gives it something only after
  -- a question; off: it counts as typed (lua/user/ai/sandbox/tags.lua)
  tag_question = {
    default = "ask",
    valid = function(v) return v == "ask" or v == "off" end,
  },
}

---------------------------------------------------------------------------------------------------- store

local raw -- the file as it was read last, with the keys this version does not know
local unsaved = {} -- the values a write failed for: they hold until Neovim closes and go along with the next write

--- The value of a setting: the stored one when it is valid, the default otherwise (nil for a key that is not
--- a setting). Never fails.
function M.get(key)
  local spec = schema[key]
  if not spec then return nil end
  raw = raw or json_file.read(M.file)
  local value = unsaved[key]
  if value == nil then value = raw[key] end
  if value == nil or not spec.valid(value) then return spec.default end
  return value
end

--- Change a setting and store it. Returns false and the reason when the value is not valid. A value that
--- could not be written still holds until Neovim closes.
function M.set(key, value)
  local spec = schema[key]
  if not spec then return false, "unknown setting: " .. tostring(key) end
  if not spec.valid(value) then return false, ("not a valid value for %s: %s"):format(key, vim.inspect(value)) end
  raw = json_file.read(M.file) -- what another Neovim stored meanwhile stays
  unsaved[key] = value
  for k, v in pairs(unsaved) do
    raw[k] = v ~= schema[k].default and v or nil
  end
  if json_file.write(M.file, raw) then
    unsaved = {}
  else
    windows.notify("Could not write " .. M.file .. ": the setting holds until Neovim closes", vim.log.levels.WARN)
  end
  return true
end

---------------------------------------------------------------------------------------------------- window

local short = windows.short

--- How much of a chat's context a rules file takes (about 4 characters per token of prose)
local function size_of(path)
  local bytes = vim.fn.getfsize(path)
  if bytes < 0 then return "not created yet" end
  return ("~%d tokens"):format(math.ceil(bytes / 4))
end

local tag_questions = {
  { "ask", "a tag that is new to a chat (@{tool}, #{context}) gives it something only after a question" },
  { "off", "tags count as typed, also in text that a command put into the message or that was pasted" },
}

local function pick_tag_question(back)
  local current = M.get "tag_question"
  windows.choose(
    tag_questions,
    {
      prompt = "Tags in a chat message",
      format_item = function(option)
        return ("%s %-4s %s"):format(option[1] == current and "●" or " ", option[1], option[2])
      end,
    },
    current == "off" and 2 or 1,
    function(option)
      if option then M.set("tag_question", option[1]) end
      back()
    end
  )
end

--- <Leader>AS. `row`: the row to put the cursor on (the one that was just changed).
function M.open(row)
  raw = json_file.read(M.file) -- what was edited by hand or stored by another Neovim applies from here on
  local ai = require "user.ai"
  local adapter = ai.current_chat_adapter()
  local chat_is_local = adapter == "ollama"
  local rows = {}
  --- `action(back)`: `back()` opens this window again, on the row it was started from
  local function add(name, value, action)
    local at = #rows + 1
    rows[at] = {
      name = name,
      value = value,
      action = function()
        action(function() M.open(at) end)
      end,
    }
  end

  add("Provider", ai.label() .. "  (<Leader>As swaps it)", function() ai.select() end)

  local rules = ai.rules_files[ai.rules_group()]
  local stays_local = chat_is_local and not ai.is_local()
  add(
    chat_is_local and "Chat rules (local)" or "Chat rules (cloud)",
    ("%s  (%s)%s"):format(short(rules), size_of(rules), stays_local and "  the chat stays local: see <Leader>As" or ""),
    function()
      local whom = chat_is_local and "the local model. Keep it to a few lines: its context is 8k tokens."
        or "a provider's model (Claude, OpenAI, ...)."
      windows.edit(rules, "New file: what is in it goes along with every chat with " .. whom)
    end
  )

  local sandbox = require "user.ai.sandbox"
  local project = vim.fs.joinpath(vim.fn.getcwd(), sandbox.project_rules)
  local rules_state = sandbox.rules_state(project)
  local unusable = sandbox.rules_problem(project)
  local waiting = not unusable and rules_state == "unapproved"
  add(
    "Project rules",
    ("%s  (%s)%s"):format(
      short(project),
      unusable and "not in use" or size_of(project),
      unusable and (": " .. unusable) or waiting and "  not in use: read and approve it" or ""
    ),
    function(back)
      if not waiting then return project_rules.edit(project) end
      windows.options(
        "Project rules: new or changed since you approved them",
        {
          { "Open it (saving it from there approves it)", "open" },
          { "Read it as it is now, then approve it", "approve" },
        },
        1,
        function(choice)
          if not choice then return back() end
          if choice == "open" then return project_rules.edit(project) end
          project_rules.review(project, back)
        end
      )
    end
  )

  add(
    "Tags in a message",
    M.get "tag_question" == "ask" and "ask before a new one gives a chat a tool or attaches something"
      or "off: every tag counts as typed",
    pick_tag_question
  )

  local tool_rules = adapter == "claude_code" and vim.fs.normalize "~/.claude/settings.json" or sandbox.settings_file
  -- why the chat's commands would not run right now (Neovim in the home directory, srt missing, ...)
  local blocked = adapter ~= "claude_code" and sandbox.command_problem() or nil
  add(
    "Tool sandbox",
    ("%s  (%s)"):format(
      short(tool_rules),
      blocked and "the chat's commands do not run here: select to see why" or "what the chat's tools may read and write"
    ),
    function()
      if blocked then windows.notify("The chat's commands do not run: " .. blocked, vim.log.levels.WARN) end
      windows.edit(tool_rules)
    end
  )

  windows.choose(
    rows,
    {
      prompt = "AI settings (" .. ai.label() .. ")",
      format_item = function(item) return ("%-20s %s"):format(item.name, item.value) end,
    },
    row,
    function(item)
      if item then item.action() end
    end
  )
end

return M
