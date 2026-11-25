-- Sandbox for the CodeCompanion chat's own tools (the Ollama and API-key chats). Every tool call is treated
-- as if an attacker had written its arguments: a model is steered by what it reads.
--   * shell commands run under srt (rules: srt-ai.json);
--   * tools that run inside Neovim are checked here, before approval and again right before they run; a
--     tool without a class in `M.policy` is refused.
-- Fails closed: when CodeCompanion no longer has or calls a wrapped function, what it guards is switched off
-- (`M.install`). Two cases fail open, each with a warning: #{name} tags when the function that reads them is
-- gone, and links when both link hooks are gone.
-- The threat model and what is not covered: docs/ai-sandbox.md. Read it before changing a rule.
-- `:lua =require("user.ai.sandbox").status()` shows what is in place; tests/ai_sandbox*.lua check it.
local M = {}

local uv = vim.uv

-- The parts of the sandbox: other code requires "user.ai.sandbox" (this file), never one of them. All are
-- required here, also the ones nothing here names: an error in any part has to fail the load of this file.
local State = require "user.ai.sandbox.state"
require "user.ai.sandbox.paths"
local Text = require "user.ai.sandbox.text"
local Names = require "user.ai.sandbox.names"
require "user.ai.sandbox.git"
local Checks = require "user.ai.sandbox.checks"
local Rules = require "user.ai.sandbox.rules"
local Tags = require "user.ai.sandbox.tags"

local locks = State.locks
local tell = State.tell
local srt_path = State.srt_path
local spell_out = Text.spell_out
local project_root = Checks.project_root
local search_problem = Checks.search_problem
local secret_search = Checks.secret_search
local secret_variables = Checks.secret_variables
local sandboxed_command = Checks.sandboxed_command
local address_problem = Checks.address_problem
local vet_rules = Rules.vet_rules
local forget_tags = Tags.forget_tags
local forget_tags_on_change = Tags.forget_tags_on_change
local typed_only = Tags.typed_only
local tool_tags_in = Tags.tool_tags_in
local context_tags_in = Tags.context_tags_in
local checked_links = Tags.checked_links
local command_problem = Checks.raw_command_problem

M.settings_file = State.settings_file
M.project_rules = State.project_rules
M.protected_names = Names.protected_names
M.check_path = Checks.check_path
M.command_problem = Checks.command_problem
M.temp_exposed = Checks.temp_exposed
M.remove_request_headers = Checks.remove_request_headers
M.approved_file = Rules.approved_file
M.rules_max_size = Rules.rules_max_size
M.rules_state = Rules.rules_state
M.read_rules = Rules.read_rules
M.rules_problem = Rules.rules_problem
M.approve_rules = Rules.approve_rules
M.rules_locked = Rules.rules_locked

---------------------------------------------------------------------------------------------------- tools

local no_git = "it runs git outside the sandbox, and git runs whatever the repository's configuration names. "
  .. "Use run_command with `git diff` or `git status` instead: that runs sandboxed."
local no_memory = "the memory tool is switched off in this editor: what it stores would be obeyed by later chats"

-- What every tool of the chat may do. `class`:
--   none      nothing outside the chat (asks the user, reads the plugin's own documentation)
--   path      works on the file named by `arg`: checked with `check_path` (`write`), and it gets the checked
--             path. `keep_link`: acts on a link itself. `open`: only for files that are open in the editor
--             (get_diagnostics would load the file otherwise, which starts language servers and git on a file
--             the model picked)
--   search    lists or reads below the project directory
--   command   runs a shell command: under srt
--   network   sends what the model writes to the web: only with the approval plugins/codecompanion.lua sets,
--             and asked for at every call (the `approval` hook below)
--   refuse    never runs
-- A tool that is not listed is refused.
M.policy = {
  ask_questions = { class = "none" },
  search_help = { class = "none" },
  read_file = { class = "path", arg = "filepath" },
  get_diagnostics = { class = "path", arg = "filepath", open = true },
  create_file = { class = "path", arg = "filepath", write = true },
  edit_file = { class = "path", arg = "filepath", write = true },
  overwrite_file = { class = "path", arg = "filepath", write = true },
  delete_file = { class = "path", arg = "filepath", write = true, keep_link = true },
  file_search = { class = "search" },
  grep_search = { class = "search" },
  run_command = { class = "command" },
  fetch_webpage = { class = "network" },
  web_search = { class = "network" },
  get_changed_files = { class = "refuse", why = no_git },
  memory = { class = "refuse", why = no_memory },
}

--- What the question before a web tool's call shows: every argument of the call, whole, with the characters
--- that do not show on a screen written out (they are sent like any other). (CodeCompanion's own question
--- names the tool and nothing else.)
local function web_question(tool, args)
  local lines, longest = {}, 2
  local keys = vim.tbl_keys(args)
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, key in ipairs(keys) do
    local value = args[key]
    if type(value) ~= "string" then
      local encoded, text = pcall(vim.json.encode, value)
      value = encoded and text or vim.inspect(value)
    end
    -- (one line each; a character that does not show is written out)
    value = spell_out(value:gsub("[\t\r\n]", " "), true)
    for run in value:gmatch "`+" do
      longest = math.max(longest, #run)
    end
    lines[#lines + 1] = ("%s: %s"):format((spell_out(tostring(key):gsub("[\t\r\n]", " "), true)), value)
  end
  local fence = ("`"):rep(longest + 1)
  return ("**%s** sends this to the web, all of it:\n\n%s\n%s\n%s"):format(
    tool.name,
    fence,
    table.concat(lines, "\n"),
    fence
  )
end

--- Why diagnostics for `path` (resolved) are not available, or nil when its file is open.
local function not_open(path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and uv.fs_realpath(vim.api.nvim_buf_get_name(bufnr)) == path then
      return nil
    end
  end
  return (
    "`%s` is not open in the editor, and diagnostics are only read for open files. Ask the user to open it, "
    .. "or run the project's linter or compiler with run_command."
  ):format(vim.fn.fnamemodify(path, ":."))
end

--- Why the tool call `tool` (as CodeCompanion prepared it) may not run, or nil when it may. A file tool's
--- path is replaced by the one that was checked, and its functions check once more when they are called:
--- every call of an answer is prepared before the first one runs, so an earlier command of the same answer
--- can have put a link where this one writes.
---@param given table|nil the tools the chat was given (chat.tool_registry.in_use)
local function vet(tool, given)
  local policy = M.policy[tool.name]
  if not policy then
    return (
      "it is not a tool this sandbox knows (`M.policy` in lua/user/ai/sandbox/init.lua), and a tool without a class "
      .. "there does not run"
    )
  end
  -- CodeCompanion runs any tool of its configuration that the model names, also one the chat does not have
  if type(given) ~= "table" then
    return "CodeCompanion no longer keeps a chat's tools where lua/user/ai/sandbox/ looks for them"
  end
  -- (what gives a chat its tools has to be what the user typed: `typed` in tags.lua)
  if locks.tool_tags then return locks.tool_tags end
  if not given[tool.name] then
    return "this chat was not given that tool. The user gives a chat a tool by naming it in a message: @{"
      .. tool.name
      .. "}"
  end
  local check
  if policy.class == "none" then
    return nil
  elseif policy.class == "refuse" then
    return policy.why
  elseif policy.class == "command" then
    return command_problem() -- (and again when the command starts: `sandboxed_command`)
  elseif policy.class == "network" then
    if locks.approval then return locks.approval end
    local opts = type(tool.opts) == "table" and tool.opts or {}
    if opts.require_approval_before ~= true or opts.protect ~= true then
      return "web tools only run when every call is approved, and that setting is missing (plugins/codecompanion.lua)"
    end
    local args = type(tool.args) == "table" and tool.args or {}
    local why = type(args.url) == "string" and address_problem(args.url)
    if why then return why end
    tool.output = type(tool.output) == "table" and tool.output or {}
    tool.output.prompt = function() return web_question(tool, args) end
    return nil
  elseif policy.class == "search" then
    local args = type(tool.args) == "table" and tool.args or {}
    local reads = tool.name ~= "file_search" -- (that one lists names, and a name is no secret)
    check = function() return search_problem() or (reads and secret_search(args, tool.opts) or nil) end
  elseif policy.class == "path" then
    local args = type(tool.args) == "table" and tool.args or {}
    local why, path = M.check_path(args[policy.arg], policy.write, policy.keep_link)
    if why then return why end
    -- a copy: the table is the model's own call, which stays in the conversation as it was written
    local checked = {}
    for key, value in pairs(args) do
      checked[key] = value
    end
    checked[policy.arg] = path
    tool.args = checked
    check = function()
      local again, now = M.check_path(path, policy.write, policy.keep_link)
      if again then return again end
      if now ~= path then
        return ("`%s` has changed since this tool call was checked: it now leads to %s"):format(path, tostring(now))
      end
      return policy.open and not_open(path) or nil
    end
  else
    return "its class in `M.policy` is not one the sandbox knows"
  end
  local why = check()
  if why then return why end
  for i, cmd in ipairs(type(tool.cmds) == "table" and tool.cmds or {}) do
    if type(cmd) ~= "function" then
      return "it is not built the way the sandbox expects (a command where a function belongs)"
    end
    tool.cmds[i] = function(...)
      local ok, again = pcall(check)
      if not ok then again = "its check failed (" .. tostring(again) .. ")" end
      if again then return { status = "error", data = ("The sandbox refused `%s`: %s"):format(tool.name, again) } end
      return cmd(...)
    end
  end
end

-- (what a question about tags ends with)
local not_typed =
  "\n\nIf you did not type that, it came in with other text: a file's path, a diagnostic, a diff, a paste.\n"

--- Every tool call passes through Tools:_resolve_and_prepare_tool before it is approved or run.
local function gate(upstream)
  return function(self, call)
    local tool, err, handled = upstream(self, call)
    if not tool then return tool, err, handled end
    local ok, why = pcall(vet, tool, vim.tbl_get(self, "chat", "tool_registry", "in_use"))
    if not ok then why = "its check failed (" .. tostring(why) .. ")" end
    if not why then return tool, err, handled end
    local msg = ("The sandbox refused `%s`: %s"):format(tostring(tool.name), why)
    -- CodeCompanion words an error it is handed as "tool not found", next to the list of tools that has the
    -- tool in it. The reason goes into the chat here instead, the way it reports arguments it cannot parse.
    local reported = pcall(function()
      self.chat:add_tool_output(tool, { content = msg })
      self.status = self.constants.STATUS_ERROR
    end)
    return nil, msg, reported
  end
end

---------------------------------------------------------------------------------------------------- install

local plugin = "lua/codecompanion/"
local hooks = {
  command = {
    module = "codecompanion.utils.os",
    field = "build_shell_command",
    caller = plugin .. "interactions/chat/tools/orchestrator.lua",
    call = "os_utils.build_shell_command(",
    wrap = function() return sandboxed_command end,
  },
  tools = {
    module = "codecompanion.interactions.chat.tools",
    field = "_resolve_and_prepare_tool",
    caller = plugin .. "interactions/chat/tools/init.lua",
    call = "self:_resolve_and_prepare_tool(",
    wrap = gate,
  },
  -- CodeCompanion asks this before it asks the user. A chat in "yolo" mode approves every tool, and "always
  -- accept" approves a tool for the rest of the chat: neither holds for the web tools, which ask each time.
  approval = {
    module = "codecompanion.interactions.chat.tools.approvals",
    field = "is_approved",
    caller = plugin .. "interactions/chat/tools/orchestrator.lua",
    call = "Approvals:is_approved(",
    wrap = function(upstream)
      return function(self, bufnr, args)
        local policy = type(args) == "table" and M.policy[args.tool_name]
        if policy and policy.class == "network" then return false end
        return upstream(self, bufnr, args)
      end
    end,
  },
  tool_tags = {
    module = "codecompanion.interactions.chat.tools",
    field = "parse",
    caller = plugin .. "interactions/chat/init.lua",
    call = "self.tools:parse(self, message)",
    wrap = typed_only(
      tool_tags_in,
      "A message gives this chat tools it did not have:\n\n%s" .. not_typed .. "Give the chat these tools?"
    ),
  },
  context_tags = {
    module = "codecompanion.interactions.shared.editor_context",
    field = "parse",
    caller = plugin .. "interactions/chat/init.lua",
    call = "self.editor_context:parse(self, message)",
    wrap = typed_only(
      context_tags_in,
      "A message attaches to this chat, for the first time:\n\n%s" .. not_typed .. "Attach it?"
    ),
  },
  link_list = {
    module = "codecompanion.interactions.chat.parser",
    field = "context_paths",
    caller = plugin .. "interactions/chat/helpers/context_paths.lua",
    call = "parser.context_paths(chat",
    wrap = checked_links,
  },
  links = {
    module = "codecompanion.interactions.chat.helpers.context_paths",
    field = "attach",
    caller = plugin .. "interactions/chat/init.lua",
    call = "context_paths.attach({",
    wrap = function(upstream)
      return function(...)
        -- (links that nothing checks attach nothing)
        if locks.link_list then return end
        return upstream(...)
      end
    end,
  },
  rules = {
    module = "codecompanion.interactions.shared.rules",
    field = "resolve_paths",
    caller = plugin .. "interactions/shared/rules/init.lua",
    call = "self:resolve_paths()",
    wrap = function(upstream)
      return function(...)
        local paths = upstream(...)
        local ok, kept = pcall(vet_rules, paths)
        return ok and kept or {}
      end
    end,
  },
}
M._hooks = hooks -- for tests
-- hook name -> the wrapper that was put in place. CodeCompanion's modules are loaded anew by `:Lazy reload`
-- (this one is not): a function that is not the wrapper is CodeCompanion's own and gets wrapped.
local ours = {}

--- Put the sandbox in place (again). Never fails. Returns whether the check on tool calls is in place, and
--- why not: without it the chat must not have tools (plugins/codecompanion.lua).
---@return boolean ok, string|nil why
function M.install()
  local function place(name, hook)
    local loaded, module = pcall(require, hook.module)
    local upstream = loaded and type(module) == "table" and module[hook.field]
    if type(upstream) ~= "function" then
      return ("CodeCompanion no longer has %s.%s, which lua/user/ai/sandbox/ wraps"):format(hook.module, hook.field)
    end
    if upstream ~= ours[name] then
      ours[name] = hook.wrap(upstream)
      module[hook.field] = ours[name]
    end
    local src = vim.api.nvim_get_runtime_file(hook.caller, false)[1]
    local read, lines = pcall(vim.fn.readfile, src or "")
    if not read or not table.concat(lines, "\n"):find(hook.call, 1, true) then
      return ("CodeCompanion no longer calls %s where lua/user/ai/sandbox/ expects it (%s)"):format(
        hook.field,
        hook.caller
      )
    end
  end
  for name, hook in pairs(hooks) do
    local ok, why = pcall(place, name, hook)
    locks[name] = not ok and ("the sandbox could not wrap %s: %s"):format(hook.field, tostring(why)) or why or nil
  end
  local consequence = {
    approval = "web tools do not run",
    command = "command tools do not run",
    tools = "the chat has no tools",
    rules = "rules files are not sent along with chats",
    tool_tags = "the chat's tools do not run",
    context_tags = "code that is pasted or selected can attach buffers to a chat (#{name})",
    link_list = "links in a message attach nothing",
    links = "links in a message attach files and pages unchecked",
  }
  for name, why in pairs(locks) do
    tell(("%s: %s until lua/user/ai/sandbox/ is updated."):format(why, consequence[name]))
  end
  local tags_group = vim.api.nvim_create_augroup("ai_sandbox_tags", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    pattern = { "CodeCompanionChatCleared", "CodeCompanionChatClosed" },
    group = tags_group,
    desc = "A chat that is cleared or closed is asked about its tags again",
    callback = function(args) forget_tags(vim.tbl_get(args, "data", "bufnr")) end,
  })
  vim.api.nvim_create_autocmd("User", {
    -- A yes was given for the model the chat talked to then: what a tag attaches must not go to another
    -- one unasked. (Not on every event: CodeCompanion fires the second after every answer of Claude Code.)
    pattern = { "CodeCompanionChatAdapter", "CodeCompanionChatModel" },
    group = tags_group,
    desc = "A chat that moved to another adapter or model is asked about its tags again",
    callback = function(args) forget_tags_on_change(args.data) end,
  })
  return locks.tools == nil, locks.tools
end

--- What is in place, for `:lua =require("user.ai.sandbox").status()`.
function M.status()
  local root = project_root()
  local wrapped = {}
  for name, hook in pairs(hooks) do
    local loaded, module = pcall(require, hook.module)
    wrapped[name] = loaded and ours[name] ~= nil and module[hook.field] == ours[name]
  end
  return {
    settings = M.settings_file,
    srt = srt_path() or false,
    project = root or false,
    wrapped = wrapped,
    locks = vim.deepcopy(locks),
    commands = M.command_problem() or "sandboxed",
    temp_exposed = M.temp_exposed() or false,
    hidden_variables = secret_variables(),
    project_rules = root and (M.rules_state(vim.fs.joinpath(root, M.project_rules))) or "missing",
  }
end

return M
