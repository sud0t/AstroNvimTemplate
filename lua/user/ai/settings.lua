-- <Leader>AS: the settings of the editor's AI, for the provider that is active (<Leader>As swaps it):
--   Chat rules      the instructions that go along with every chat (lua/user/ai/init.lua, `rules_files`: one
--                   file for the local model, one for the providers' models)
--   Project rules   .nvim-ai.md in the directory Neovim runs in, for every provider. Chats only get it as you
--                   approved it here (a repository can bring one along, and what it says is obeyed):
--                   saving it from this window approves it, and a file that got here or changed some other
--                   way waits for "Approve" (lua/user/ai/sandbox.lua keeps the record)
--   Local model     the Ollama model the local actions and the local chat use
--   Commit detail   how much <Leader>Ac writes below the first line (lua/user/ai/commit.lua)
--   Tool sandbox    what the chat's tools may read and write: srt-ai.json (lua/user/ai/sandbox.lua), or
--                   ~/.claude/settings.json for the Claude Code chat
-- The values are kept in stdpath("state")/ai_settings.json: only the ones that differ from the defaults, and
-- keys this version does not know are left alone, so an older or newer checkout does not lose them. The file is
-- not read at startup and every value is checked when it is used: a damaged or hand-edited file only means the
-- defaults. It is hardware-specific (which model fits this GPU), so it is not part of the configuration.
-- Context size, temperature and the length limits are not settings: they were measured per action against the
-- 4GB GPU (see the comments where they are set).
local M = {}

M.file = vim.fn.stdpath "state" .. "/ai_settings.json"

-- The right model of the ones installed: the actions are instruct tasks (reading a diff and summarising it in
-- prose, fixing code to a format), and qwen3:4b-instruct is the only one that mostly fits on the GPU (the
-- 7b/8b models run at half its speed).
M.default_model = "qwen3:4b-instruct"

local schema = {
  -- auto: by the size of the change; brief: always one line; detailed: one step more than the size calls for
  commit_detail = {
    default = "auto",
    valid = function(v) return v == "auto" or v == "brief" or v == "detailed" end,
  },
  -- ask: a tag in a chat message (@{tool}, #{context}) that is new to the chat gives it something only after
  -- a question; off: it counts as typed (lua/user/ai/sandbox.lua)
  tag_question = {
    default = "ask",
    valid = function(v) return v == "ask" or v == "off" end,
  },
  -- an Ollama model name: "qwen3:4b-instruct", "hf.co/user/model:Q4_K_M"
  local_model = {
    default = M.default_model,
    valid = function(v) return type(v) == "string" and #v <= 200 and v:find "^%w[%w._/:-]*$" ~= nil end,
    -- Ollama's full name of a model has a tag, and the VRAM housekeeping (lua/user/ai/ollama.lua) compares
    -- full names: "llama3" is "llama3:latest"
    fix = function(v) return v:find(":", 1, true) and v or v .. ":latest" end,
  },
}

---------------------------------------------------------------------------------------------------- store

local raw -- the file as it was read last, with the keys this version does not know
local unsaved = {} -- the values a write failed for: they hold until Neovim closes and go along with the next write

local function read()
  raw = {}
  local ok, lines = pcall(vim.fn.readfile, M.file)
  if not ok then return end
  local decoded, data = pcall(vim.json.decode, table.concat(lines, "\n"))
  -- only a JSON object (`[]` is an empty table too: as good as no file)
  if decoded and type(data) == "table" and (next(data) == nil or not vim.islist(data)) then raw = data end
end

--- The value of a setting: the stored one when it is valid, the default otherwise (nil for a key that is not
--- a setting). Never fails.
function M.get(key)
  local spec = schema[key]
  if not spec then return nil end
  if not raw then read() end
  local value = unsaved[key]
  if value == nil then value = raw[key] end
  if value == nil or not spec.valid(value) then return spec.default end
  return spec.fix and spec.fix(value) or value
end

--- Change a setting and store it. Returns false and the reason when the value is not valid. A value that
--- could not be written still holds until Neovim closes.
function M.set(key, value)
  local spec = schema[key]
  if not spec then return false, "unknown setting: " .. tostring(key) end
  if not spec.valid(value) then return false, ("not a valid value for %s: %s"):format(key, vim.inspect(value)) end
  read() -- what another Neovim stored meanwhile stays
  unsaved[key] = spec.fix and spec.fix(value) or value
  for k, v in pairs(unsaved) do
    raw[k] = v ~= schema[k].default and v or nil
  end
  local ok, res = pcall(function()
    vim.fn.mkdir(vim.fs.dirname(M.file), "p")
    return vim.fn.writefile({ vim.json.encode(next(raw) and raw or vim.empty_dict()) }, M.file)
  end)
  if ok and res == 0 then
    unsaved = {}
  else
    vim.notify(
      "Could not write " .. M.file .. ": the setting holds until Neovim closes",
      vim.log.levels.WARN,
      { title = "AI settings" }
    )
  end
  return true
end

---------------------------------------------------------------------------------------------------- window

local function notify(msg, level) vim.notify(msg, level or vim.log.levels.INFO, { title = "AI settings" }) end

local function short(path) return vim.fn.fnamemodify(path, ":~") end

--- How much of a chat's context a rules file takes (about 4 characters per token of prose)
local function size_of(path)
  local bytes = vim.fn.getfsize(path)
  if bytes < 0 then return "not created yet" end
  return ("~%d tokens"):format(math.ceil(bytes / 4))
end

--- Open `path` for editing; `note` is shown when the file does not exist yet. Returns whether it is open.
local function edit(path, note)
  local ok, err = pcall(function()
    if vim.bo.filetype == "codecompanion" then
      -- not over the chat: in a window of this tab that shows a file, or a new one
      local other = vim.iter(vim.api.nvim_tabpage_list_wins(0)):find(
        function(win)
          return vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "" and vim.api.nvim_win_get_config(win).relative == ""
        end
      )
      if other then
        vim.api.nvim_set_current_win(other)
      else
        vim.cmd "topleft vnew"
      end
    end
    vim.cmd.edit(vim.fn.fnameescape(path))
  end)
  if not ok then
    notify(("Could not open %s: %s"):format(short(path), err), vim.log.levels.ERROR)
    return false
  end
  if note and vim.fn.filereadable(path) == 0 then notify(note) end
  return true
end

--- The sha256 of what writing `bufnr` puts on disk (two, where it is one of them), or nil when that cannot be
--- told here (an encoding other than UTF-8).
local function written(bufnr)
  local bo = vim.bo[bufnr]
  if bo.fileencoding ~= "" and bo.fileencoding ~= "utf-8" then return nil end
  local eol = ({ unix = "\n", dos = "\r\n", mac = "\r" })[bo.fileformat]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines, eol)
  if bo.endofline or (bo.fixendofline and not bo.binary) then text = text .. eol end
  local bom = bo.bomb and "\239\187\191" or ""
  local hashes = { vim.fn.sha256(bom .. text) }
  -- (a buffer without a line is written as an empty file, and looks like one with an empty line)
  if #lines == 1 and lines[1] == "" then hashes[2] = vim.fn.sha256(bom) end
  return hashes
end

--- Open the project's rules file. Saving it from that buffer approves what was saved: this window is where
--- the owner goes to write them, and nothing the chat's tools do gets here (they cannot write the file, and a
--- command that changes it on disk does not save this buffer). When the buffer is loaded again from a file
--- that changed on disk (a command of the chat, `git checkout`), it shows text nobody approved and that the
--- owner may not have read: saving no longer approves, and the file waits for "Approve" in <Leader>AS.
local function edit_project_rules(path)
  local problem = require("user.ai.sandbox").rules_problem(path)
  if problem then
    return notify(("%s is not opened as the project's rules: %s."):format(short(path), problem), vim.log.levels.WARN)
  end
  local note = "New file: what is in it goes along with every chat opened in this directory, with any provider."
  -- (the file's own modeline could fold lines away or stop them from wrapping, and what is saved is approved)
  local modeline = vim.go.modeline
  vim.go.modeline = false
  local opened = edit(path, note)
  vim.go.modeline = modeline
  if not opened then return end
  for option, value in pairs { wrap = true, conceallevel = 0, foldenable = false } do
    vim.wo[0][0][option] = value
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local group = vim.api.nvim_create_augroup("ai_project_rules_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "FileChangedShellPost" }, {
    buffer = bufnr,
    group = group,
    desc = "Stop approving the project's AI rules on save once they changed on disk",
    callback = function()
      if require("user.ai.sandbox").rules_state(path) ~= "unapproved" then return end
      vim.api.nvim_clear_autocmds { group = group }
      notify(
        ("%s changed on disk: chats do not get it until you have read and approved it (<Leader>AS, Project rules)."):format(
          short(path)
        ),
        vim.log.levels.WARN
      )
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    buffer = bufnr,
    group = group,
    desc = "Approve the project's AI rules as they were just saved",
    callback = function(args)
      -- (`:w other-name` from this buffer is not the rules file)
      local saved = vim.uv.fs_realpath(args.match)
      if not saved or saved ~= vim.uv.fs_realpath(path) then return end
      -- what is approved is this buffer's text: not what something else made of the file in the same moment
      local shown = written(args.buf)
      local ok, err = false, "its encoding is not UTF-8: approve it in <Leader>AS, Project rules"
      if shown then
        ok, err = require("user.ai.sandbox").approve_rules(path, shown)
      end
      if not ok then notify("The project rules were saved but not approved: " .. err, vim.log.levels.WARN) end
    end,
  })
end

--- vim.ui.select with the cursor on `row` (snacks, AstroNvim's picker, starts on the first row; other
--- pickers ignore the extra option)
local function choose(items, opts, row, on_choice)
  if row and row > 1 then
    opts.snacks = {
      on_show = function(picker)
        pcall(function() picker.list:view(row) end)
      end,
    }
  end
  vim.ui.select(items, opts, on_choice)
end
M.choose = choose -- (<Leader>As in lua/user/ai/init.lua has the same kind of windows)

--- Show the project's rules as they are on disk, all of them (a window of its own without a file behind it:
--- no modeline, nothing folded or concealed, long lines wrapped, tabs and trailing blanks marked). `a`
--- approves exactly the text that is shown, once every line of it has been on screen in full and after a question
--- (`a` is a key that is pressed by habit); `q` closes. `back()` after either.
local function review_project_rules(path, back)
  local sandbox = require "user.ai.sandbox"
  local text, hash = sandbox.read_rules(path)
  if not text then
    notify(("%s is not approved: %s."):format(short(path), hash), vim.log.levels.WARN)
    return back()
  end
  local lines = vim.split(text, "\n", { plain = true })
  if #lines > 1 and lines[#lines] == "" then table.remove(lines) end
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].bufhidden = "wipe"
  vim.cmd "botright split"
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, bufnr)
  local bar = ("%s as it is on disk, %d line%s    a: approve it (once all of it was on screen)    q: close"):format(
    short(path),
    #lines,
    #lines == 1 and "" or "s"
  )
  for option, value in pairs {
    wrap = true,
    list = true,
    number = true,
    conceallevel = 0,
    foldenable = false,
    smoothscroll = true, -- (a line that is longer than the window is scrolled through, not over)
    winbar = bar:gsub("%%", "%%%%"),
  } do
    vim.wo[win][0][option] = value
  end
  -- What is approved has been on screen, all of it: text can be kept off the first screen with empty lines
  -- and off the last one with a jump to the end. A line counts once all of it was on screen at one time
  -- (its first and its last character): of one that is longer than the window, moving down shows the
  -- start and the end and never the middle.
  local seen, unseen = {}, #lines
  local function look()
    if not vim.api.nvim_win_is_valid(win) then return end
    for row = math.max(vim.fn.line("w0", win), 1), math.min(vim.fn.line("w$", win) + 1, #lines) do
      if
        not seen[row]
        and vim.fn.screenpos(win, row, 1).row > 0
        and vim.fn.screenpos(win, row, math.max(#lines[row], 1)).row > 0
      then
        seen[row], unseen = true, unseen - 1
      end
    end
  end
  local group = vim.api.nvim_create_augroup("ai_project_rules_review_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", { group = group, buffer = bufnr, callback = look })
  vim.api.nvim_create_autocmd("WinScrolled", { group = group, pattern = tostring(win), callback = look })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    once = true,
    callback = function() pcall(vim.api.nvim_del_augroup_by_id, group) end,
  })
  local function close()
    if not vim.api.nvim_win_is_valid(win) then return end
    -- (the last window of a tab page cannot be closed: it gets an empty buffer)
    if not pcall(vim.api.nvim_win_close, win, true) then pcall(vim.cmd.enew) end
  end
  vim.keymap.set("n", "q", function()
    close()
    back()
  end, { buffer = bufnr, nowait = true, desc = "Close without approving" })
  vim.keymap.set("n", "a", function()
    -- (where the window is, is only settled when it is drawn)
    pcall(vim.cmd.redraw)
    look()
    if unseen > 0 then
      local first = 1
      while seen[first] do
        first = first + 1
      end
      return notify(
        (
          "Not approved yet: %d of its %d lines have not been on screen in full (the first: line %d). Scroll "
          .. "through all of it; a line that is longer than the window needs a larger window."
        ):format(unseen, #lines, first),
        vim.log.levels.WARN
      )
    end
    choose(
      { { "Approve these rules: chats in this directory get them", true }, { "Not yet", false } },
      { prompt = "Project rules, read to the end", format_item = function(option) return option[1] end },
      2,
      function(option)
        if not option or not option[2] then return end
        local ok, err = sandbox.approve_rules(path, hash)
        notify(
          ok and ("Approved: chats opened in this directory get " .. short(path) .. ".") or ("Not approved: " .. err),
          ok and vim.log.levels.INFO or vim.log.levels.ERROR
        )
        close()
        back()
      end
    )
  end, { buffer = bufnr, nowait = true, desc = "Approve the project's AI rules as shown here" })
end

local commit_details = {
  { "auto", "by the size of the change: one line when it is small, a few bullets when it is larger" },
  { "brief", "always one line" },
  { "detailed", "one step more than the size calls for: bullets for small changes too" },
}

local function pick_commit_detail(back)
  local current = M.get "commit_detail"
  local row = 1
  for i, option in ipairs(commit_details) do
    if option[1] == current then row = i end
  end
  choose(
    commit_details,
    {
      prompt = "Commit message detail (<Leader>Ac)",
      format_item = function(option)
        return ("%s %-9s %s"):format(option[1] == current and "●" or " ", option[1], option[2])
      end,
    },
    row,
    function(option)
      if option then M.set("commit_detail", option[1]) end
      back()
    end
  )
end

local tag_questions = {
  { "ask", "a tag that is new to a chat (@{tool}, #{context}) gives it something only after a question" },
  { "off", "tags count as typed, also in text that a command put into the message or that was pasted" },
}

local function pick_tag_question(back)
  local current = M.get "tag_question"
  choose(
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

local function pick_local_model(back)
  local ollama = require "user.ai.ollama"
  local current = M.get "local_model"

  local function apply(name)
    name = vim.trim(name or "")
    if name == "" or name == current then return back() end
    local ok, err = M.set("local_model", name)
    if not ok then
      notify(err, vim.log.levels.WARN)
      return back()
    end
    name = M.get "local_model" -- (with its tag)
    if name == current then return back() end
    ollama.unload(current, function() end)
    local caveat = name == M.default_model and ""
      or (
        "\nThe context size and the length limits were measured for %s on the 4GB GPU: a larger model is slower, "
        .. "and one that cannot follow the review's format finds no fixes."
      ):format(M.default_model)
    notify(("The local model is %s, for the AI actions and for chats opened from now on.%s"):format(name, caveat))
    back()
  end

  local function type_name()
    vim.ui.input({ prompt = "Ollama model: ", default = current }, function(name)
      if name == nil then return back() end
      apply(name)
    end)
  end

  ollama.models(function(names)
    if not names then return type_name() end -- Ollama is not running: the name can still be typed
    local options, row = {}, 1
    if not vim.list_contains(names, M.default_model) then table.insert(names, 1, M.default_model) end
    if not vim.list_contains(names, current) then table.insert(names, 1, current) end
    for i, name in ipairs(names) do
      options[i] = { name = name }
      if name == current then row = i end
    end
    options[#options + 1] = { other = true }
    choose(
      options,
      {
        prompt = "Local model (installed in Ollama)",
        format_item = function(option)
          if option.other then return "  Other... (type a name)" end
          return ("%s %s%s"):format(
            option.name == current and "●" or " ",
            option.name,
            option.name == M.default_model and "  (default: what the limits were measured for)" or ""
          )
        end,
      },
      row,
      function(option)
        if not option then return back() end
        if option.other then return type_name() end
        apply(option.name)
      end
    )
  end)
end

--- <Leader>AS. `row`: the row to put the cursor on (the one that was just changed).
function M.open(row)
  read() -- what was edited by hand or stored by another Neovim applies from here on
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
      edit(rules, "New file: what is in it goes along with every chat with " .. whom)
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
      if not waiting then return edit_project_rules(project) end
      choose(
        {
          { "Open it (saving it from there approves it)", "open" },
          { "Read it as it is now, then approve it", "approve" },
        },
        {
          prompt = "Project rules: new or changed since you approved them",
          format_item = function(option) return option[1] end,
        },
        1,
        function(option)
          if not option then return back() end
          if option[2] == "open" then return edit_project_rules(project) end
          review_project_rules(project, back)
        end
      )
    end
  )

  if ai.is_local() or chat_is_local then add("Local model", M.get "local_model", pick_local_model) end
  add("Commit detail", M.get "commit_detail", pick_commit_detail)
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
      if blocked then notify("The chat's commands do not run: " .. blocked, vim.log.levels.WARN) end
      edit(tool_rules)
    end
  )

  choose(
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
