-- What the text of a submitted message gives a chat: tools and context by tag (@{name}, #{name}),
-- files and pages by link.
local M = {}

local uv = vim.uv

local State = require "user.ai.sandbox.state"
local Text = require "user.ai.sandbox.text"
local Checks = require "user.ai.sandbox.checks"

local tell = State.tell
local spell_out = Text.spell_out
local address_problem = Checks.address_problem

--- `text` without what gives a chat nothing: fenced code blocks and the lines of the selection the chat was
--- opened with (`selection`). Whoever wrote pasted or selected code must not hand the chat tools (@{name}) or
--- buffers (#{name}). Selection lines are matched one by one (the chat buffer re-flows blank lines) and never
--- close a fence, so a selection with "```" in it cannot end the block it was put in. Errs towards giving
--- nothing, in every message of the chat: a block typed later is not closed by such a line either.
local function typed(text, selection)
  local selected = {}
  if type(selection) == "string" then
    for line in selection:gmatch "[^\n]+" do
      selected[vim.trim(line)] = true
    end
    selected[""] = nil
  end
  local kept, fence = {}, nil
  for line in (text .. "\n"):gmatch "(.-)\n" do
    local inert = selected[vim.trim(line)]
    if fence then
      local closing = not inert and line:match("^ ? ? ?(" .. fence.mark .. "+)%s*$")
      if closing and #closing >= fence.length then fence = nil end
    else
      local opening = line:match "^ ? ? ?(```+)[^`]*$" or line:match "^ ? ? ?(~~~+)"
      if opening then
        fence = { mark = opening:sub(1, 1), length = #opening }
      elseif not inert then
        kept[#kept + 1] = line
      end
    end
  end
  return table.concat(kept, "\n")
end

-- The tags (`@{name}`, `#{name}`) the user said yes to, by the number of the chat's buffer (Neovim uses none
-- twice), each with the chat's list of context, adapter and model as they were then. Not by `chat.messages`:
-- CodeCompanion makes that table anew whenever a tool is added.
local given_tags = {}

--- The adapter (its name) and the model a message of `chat` goes to, or nothing when either cannot be told.
--- Read from the chat: CodeCompanion announces neither a move to g:codecompanion_adapter nor a model that an
--- agent changed by itself.
local function sent_to(chat)
  local adapter = type(chat) == "table" and chat.adapter
  if type(adapter) ~= "table" or type(adapter.name) ~= "string" then return end
  -- (Chat:submit moves the chat there after the tags of its message were read: to the adapter CodeCompanion
  -- finds by that name, which for a name it does not find is the one of new chats)
  local moves_to = vim.g.codecompanion_adapter
  if moves_to ~= nil and moves_to ~= adapter.name then return end
  local model
  if adapter.type == "http" then
    -- (a request names the first, CodeCompanion shows the second. A chat that g:codecompanion_adapter moved
    -- keeps the settings of the adapter it left: the two differ, and neither is told to be its model)
    model = vim.tbl_get(chat, "settings", "model")
    if model ~= vim.tbl_get(adapter, "schema", "model", "default") then return end
  elseif adapter.type == "acp" and type(chat.acp_connection) == "table" then
    local read, models = pcall(chat.acp_connection.get_models, chat.acp_connection)
    if not read or (models ~= nil and type(models) ~= "table") then return end
    -- (an agent that offers no models: CodeCompanion calls its model "default" too, and announces none)
    model = models and models.currentModelId
    if model == nil then model = "default" end
  end
  if type(model) ~= "string" then return end
  return adapter.name, model
end

--- The tags `chat` was given, as a set: none for a chat without a buffer number, none once something was
--- taken out of the chat (CodeCompanion then makes its list of context anew), and none while its messages
--- go to another adapter or model, or to one that cannot be told: a yes does not outlast what it gave, nor
--- where it gave it.
local function tags_given(chat)
  local bufnr = type(chat) == "table" and chat.bufnr
  local record = type(bufnr) == "number" and given_tags[bufnr]
  if not record or record.context ~= chat.context_items then return {} end
  local adapter, model = sent_to(chat)
  return adapter ~= nil and record.adapter == adapter and record.model == model and record.tags or {}
end

--- Remember that the user gave `chat` the tags `new`. A chat without a buffer number or without a list of
--- context cannot be told from another one, or from itself with less in it, and one whose adapter or model
--- cannot be told from itself with another: it is asked every time.
local function give_tags(chat, new)
  local bufnr = type(chat) == "table" and chat.bufnr
  if type(bufnr) ~= "number" or type(chat.context_items) ~= "table" then return end
  local adapter, model = sent_to(chat)
  if adapter == nil then return end
  local tags = tags_given(chat)
  for _, tag in ipairs(new) do
    tags[tag] = true
  end
  given_tags[bufnr] = { context = chat.context_items, adapter = adapter, model = model, tags = tags }
end

--- A chat that is cleared or closed starts anew (`bufnr`: its buffer).
local function forget_tags(bufnr)
  if bufnr ~= nil then given_tags[bufnr] = nil end
end

--- CodeCompanion announced the adapter or the model of a chat (`announced`: the data of its ChatAdapter or
--- ChatModel event): another one than the yes was given for ends it, also for a chat that moves back later.
--- The same one does not: a chat with Claude Code announces its model after every answer.
local function forget_tags_on_change(announced)
  local bufnr = type(announced) == "table" and announced.bufnr
  local record = bufnr ~= nil and given_tags[bufnr]
  if not record then return end
  local adapter = vim.tbl_get(announced, "adapter", "name")
  -- (the adapter of a chat over HTTP is announced with its model)
  local model = announced.model or vim.tbl_get(announced, "adapter", "model", "name")
  local same = (adapter ~= nil or model ~= nil)
    and (adapter == nil or adapter == record.adapter)
    and (model == nil or model == record.model)
  if not same then given_tags[bufnr] = nil end
end

--- Whether a tag that is new to a chat is asked about (<Leader>AS, "Tags in a message"): yes, unless that
--- was turned off.
local function asks_about_tags()
  local loaded, prefs = pcall(require, "user.ai.settings")
  return not (loaded and prefs.get "tag_question" == "off")
end

--- The tags out of `found` (the ones in a message) that `chat` gets what they stand for: the ones the user
--- has given it before, and after a question the rest. What was typed and what only reads as typed (pasted
--- text; a file's path, a diagnostic or a line of a diff that a command of CodeCompanion put into the message)
--- look the same from here: the question is what tells them apart.
--- `tools`: for the tags of tools, the tools each one stands for.
local function user_gives(chat, found, question, notes, tools)
  local given = tags_given(chat)
  local in_use = type(chat) == "table" and vim.tbl_get(chat, "tool_registry", "in_use")
  --- Whether the chat was given `tag` and still has all of it: a tool that was taken out of the chat since
  --- (its line of context deleted) is not put back by text that names it.
  local function known(tag)
    if not given[tag] then return false end
    if tools == nil then return true end
    local stands_for = tools[tag]
    if type(stands_for) ~= "table" or #stands_for == 0 or type(in_use) ~= "table" then return false end
    for _, tool in ipairs(stands_for) do
      if not in_use[tool] then return false end
    end
    return true
  end
  local new, listed = {}, {}
  for _, tag in ipairs(found) do
    if not known(tag) and not listed[tag] then
      listed[tag] = true
      new[#new + 1] = tag
    end
  end
  if #new == 0 or not asks_about_tags() then return found end
  table.sort(new)
  local shown = vim.tbl_map(function(tag)
    local note = type(notes) == "table" and notes[tag]
    return "  " .. spell_out(tag:gsub("%s+", " "), true) .. (note and "  (" .. note .. ")" or "")
  end, new)
  if vim.fn.confirm(question:format(table.concat(shown, "\n")), "&Yes\n&No", 2, "Question") ~= 1 then
    return vim.tbl_filter(known, found)
  end
  give_tags(chat, new)
  return found
end

--- The tags of the tools and groups that CodeCompanion finds in `message`, as they are written, what the
--- question says about them (a group: the tools in it) and the tools each one stands for.
local function tool_tags_in(tools, message)
  local found, notes, stands_for = {}, {}, {}
  local names, groups = tools:find(message)
  for _, name in ipairs(names or {}) do
    local tag = "@{" .. name .. "}"
    found[#found + 1] = tag
    stands_for[tag] = { name }
  end
  for _, name in ipairs(groups or {}) do
    local tag = "@{" .. name .. "}"
    local members = vim.tbl_get(tools, "tools_config", "groups", name, "tools")
    found[#found + 1] = tag
    notes[tag] = type(members) == "table" and table.concat(vim.tbl_map(tostring, members), ", ") or "a group of tools"
    stands_for[tag] = members
  end
  return found, notes, stands_for
end

--- The same for what it attaches (`#{buffer}`, `#{buffer:name}`), each with what follows it in braces: that
--- changes what is attached (`#{buffer}{diff}`), and CodeCompanion reads it the same way.
local function context_tags_in(context, message)
  local found = {}
  for _, instance in ipairs(context:find(message) or {}) do
    local tag = instance.target and ("#{%s:%s}"):format(instance.ctx, instance.target) or ("#{%s}"):format(instance.ctx)
    local params = message.content:match(vim.pesc(tag) .. "{([^}]*)}")
    found[#found + 1] = params and ("%s{%s}"):format(tag, params) or tag
  end
  return found
end

--- Chat:replace_user_inputs asks the tools and the editor context to `parse(chat, message)`: they get the
--- message as `typed` leaves it (a copy: the message itself goes to the model as it was written), and only
--- when the user gives the chat what its tags stand for. `tags_in`: the tags CodeCompanion finds in it.
local function typed_only(tags_in, question)
  return function(upstream)
    return function(self, chat, message, ...)
      if type(message) ~= "table" or type(message.content) ~= "string" then return false end
      local opened_with = type(chat) == "table" and type(chat.buffer_context) == "table" and chat.buffer_context.code
      local read, text = pcall(typed, message.content, opened_with)
      local copy = setmetatable({ content = read and text or "" }, { __index = message })
      local listed, found, notes, tools = pcall(tags_in, self, copy)
      if not listed or type(found) ~= "table" then
        tell(
          "The sandbox could not tell what a message gives the chat (CodeCompanion finds tags in another way "
            .. "than lua/user/ai/sandbox/ expects): the message gave it nothing."
        )
        return false
      end
      -- (nothing to give: CodeCompanion is not asked either)
      local given = #found > 0 and user_gives(chat, found, question, notes, tools) or {}
      if #given == 0 then return false end
      -- (after a no to the new ones: the ones the chat had, as they are written and nothing else)
      if #given < #found then copy = setmetatable({ content = table.concat(given, "\n") }, { __index = message }) end
      return upstream(self, chat, copy, ...)
    end
  end
end

--- Why the link `link` of a message ({ destination, markdown }) attaches nothing to `chat`, or nil when it
--- does; "" when there is nothing to say about it. CodeCompanion attaches the file or fetches the page that
--- any link in a submitted message points to: `[x](~/.aws/credentials)` in text that was pasted, or in code
--- that was selected, would send that file to the provider. A file is attached when the file tools may read
--- it, a page after a question that shows its address, and nothing that the selection brought along.
local function link_problem(chat, link)
  local destination = type(link) == "table" and link.destination
  if type(destination) ~= "string" or destination == "" then return "" end
  local selection = type(chat) == "table" and type(chat.buffer_context) == "table" and chat.buffer_context.code
  if type(selection) == "string" and type(link.markdown) == "string" and selection:find(link.markdown, 1, true) then
    return "it is part of the code this chat was opened with"
  end
  -- CodeCompanion looks for a file first, by this path (to it `http://a/b` is the path `http:/a/b` as well),
  -- and for a page only when there is none: the same order here, so that what is checked is what it attaches.
  local path = vim.fs.abspath(vim.fs.normalize(destination))
  local stat = uv.fs_stat(path)
  if stat and stat.type ~= "directory" then return (Checks.check_path(path, false)) end
  -- (a link to something else is text and stays that)
  if not destination:find "^https?://." then return "" end
  local why = address_problem(destination)
  if why then return why end
  local question = ("A link in your message points to a page:\n\n  %s\n\nFetch it and attach it to the chat?"):format(
    (spell_out(destination, true))
  )
  return vim.fn.confirm(question, "&Fetch it\n&Leave it out", 2, "Question") ~= 1 and "you left it out" or nil
end

--- parser.context_paths lists the links of the message that is being submitted: only those that may attach
--- something go on to helpers.context_paths.attach, which calls it.
local function checked_links(upstream)
  return function(chat, ...)
    local links = upstream(chat, ...)
    if type(links) ~= "table" then return links end
    local kept = {}
    for _, link in ipairs(links) do
      local checked, why = pcall(link_problem, chat, link)
      if not checked then why = "its check failed (" .. tostring(why) .. ")" end
      if not why then
        kept[#kept + 1] = link
      elseif why ~= "" then
        local shown = spell_out(tostring(link.markdown):gsub("%s+", " "), true)
        if #shown > 120 then shown = shown:sub(1, 117) .. "..." end
        tell(
          ("A link in the message attached nothing to the chat: %s\n%s\n/file attaches a file, /fetch a page."):format(
            shown,
            why
          )
        )
      end
    end
    return #kept > 0 and kept or nil
  end
end

M.forget_tags = forget_tags
M.forget_tags_on_change = forget_tags_on_change
M.typed_only = typed_only
M.tool_tags_in = tool_tags_in
M.context_tags_in = context_tags_in
M.checked_links = checked_links

return M
