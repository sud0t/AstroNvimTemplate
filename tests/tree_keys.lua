-- The file tree's keys inside the whole configuration (lua/plugins/neo-tree.lua, lua/user/git_prompts.lua,
-- lua/user/hidden_keys.lua).
--   tests/run.sh tree_keys
-- prints "ok: N checks", or what failed and exits with 1. Run it after changing one of those files and after an
-- update of neo-tree, AstroNvim, snacks or which-key: the keys that are moved or removed and the pickers are theirs.

local harness = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/harness.lua")
harness.whole_config()
local ok = harness.ok

local function press(keys) vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false) end
local function wait_for(what, cond) assert(vim.wait(5000, cond, 20), "timed out waiting for " .. what) end
local function git(dir, ...)
  local result = vim
    .system({ "git", "-c", "user.name=test", "-c", "user.email=test@localhost", ... }, { cwd = dir })
    :wait()
  assert(result.code == 0, "git failed: " .. (result.stderr or ""))
  return result.stdout
end

--- Runs `fn` with the notifications it causes collected, not shown, and returns them. `fn` gets the list as well.
local function with_notifications(fn)
  local notes, notify = {}, vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(message) notes[#notes + 1] = message end
  local done, err = pcall(fn, notes)
  vim.notify = notify
  if not done then error(err, 0) end
  return notes
end

--- Runs `fn` with `answer` given to every question asked through vim.ui.select, and returns the questions.
local function answering(answer, fn)
  local asked, select = {}, vim.ui.select
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.ui.select = function(items, opts, on_choice)
    asked[#asked + 1] = { prompt = opts.prompt, items = items }
    on_choice(answer)
  end
  local done, err = pcall(fn)
  vim.ui.select = select
  if not done then error(err, 0) end
  return asked
end

--- The windows that show a buffer of the filetype
local function windows_of(filetype)
  return vim.tbl_filter(
    function(win) return vim.bo[vim.api.nvim_win_get_buf(win)].filetype == filetype end,
    vim.api.nvim_tabpage_list_wins(0)
  )
end

local function tree_state() return require("neo-tree.sources.manager").get_state_for_window() end
local function source() return vim.bo.filetype == "neo-tree" and vim.b.neo_tree_source or nil end
--- The source the tree window shows, once neo-tree has drawn it. The window holds a source's buffer before the
--- rows are drawn, and a draw that is still to come takes the window back from a source switched to before it.
--- (`_ready` is the flag neo-tree keeps for its own tests to wait on.)
local function drawn_source()
  local state = source() and tree_state()
  return state and state._ready and source() or nil
end
local function selected() return vim.tbl_count(tree_state().selected) end

local function line_of(name)
  local state = tree_state()
  if not (state and state.tree) then return nil end
  for line = 1, vim.api.nvim_buf_line_count(0) do
    local node = state.tree:get_node(line)
    if node and node.name == name then return line end
  end
end
local function go_to(name) vim.api.nvim_win_set_cursor(0, { assert(line_of(name), "no row for " .. name), 0 }) end

--- The tree buffer's own mapping of `lhs`, or nil when the tree does not map it
local function own(lhs, mode)
  local map = vim.fn.maparg(lhs, mode or "n", false, true)
  return map.buffer == 1 and map or nil
end
local function is_hidden(lhs, mode) return (own(lhs, mode) or {}).desc == "which_key_ignore" end
local function mapped_to(lhs, desc) return (own(lhs) or {}).desc == desc end

local function show(wanted, row)
  for _ = 1, 6 do
    if source() == wanted then break end
    local before = source()
    press "<Tab>"
    wait_for("the source after " .. tostring(before), function() return drawn_source() and drawn_source() ~= before end)
  end
  assert(source() == wanted, "there is no source " .. wanted)
  wait_for(row .. " in " .. wanted, function() return line_of(row) end)
end

--- The keys which-key lists after `prefix` in the current buffer
local function popup(prefix)
  local mode = require("which-key.buf").get { buf = vim.api.nvim_get_current_buf(), mode = "n", update = true }
  local node = mode.tree:find(prefix)
  local keys = {}
  for _, child in ipairs(node and node:children() or {}) do
    keys[#keys + 1] = child.key
  end
  table.sort(keys)
  return table.concat(keys, " ")
end

--- Returns a function that tells whether neo-tree still has a change of the repository to hand to its sources,
--- which it does 100 ms after the command that made the change. For once the tree is loaded.
local function git_events()
  local events = require "neo-tree.events"
  -- (under another name nothing below would ever be pending, and the wait on it would pass at once)
  local git_event =
    assert(events.GIT_EVENT, "neo-tree no longer names its event for a change of the repository GIT_EVENT")
  local pending, fire = false, events.fire_event
  ---@diagnostic disable-next-line: duplicate-set-field
  events.fire_event = function(event, ...)
    if event == git_event then pending = true end
    return fire(event, ...)
  end
  events.subscribe { event = git_event, handler = function() pending = false end }
  return function() return pending end
end

local dir = vim.fn.tempname()
local remote = vim.fn.tempname()
local started_in = vim.fn.getcwd()
local run, err = xpcall(function()
  vim.fn.mkdir(dir)
  for _, name in ipairs { "a.txt", "b.txt", "c.txt" } do
    vim.fn.writefile({ name }, dir .. "/" .. name)
  end
  git(dir, "init", "-q")
  git(dir, "add", ".")
  git(dir, "commit", "-q", "-m", "files")
  vim.fn.writefile({ "changed" }, dir .. "/b.txt")

  vim.cmd.cd(dir)
  vim.cmd.edit "a.txt"
  vim.cmd "Neotree focus"
  wait_for("the tree", function() return source() == "filesystem" and line_of "c.txt" end)
  -- neo-tree's setup clears netrw's autocommand group with silent!, which leaves an error message behind here,
  -- where netrw is off and the group does not exist
  vim.v.errmsg = ""
  local git_event_pending = git_events()

  ok("<Tab> is next source", mapped_to("<Tab>", "next_source"), vim.inspect(own "<Tab>"))
  ok("<S-Tab> is previous source", mapped_to("<S-Tab>", "prev_source"), vim.inspect(own "<S-Tab>"))
  for _, lhs in ipairs { "<", ">", "[b", "]b", "<C-;>", "<Space>", "T", "Tf", "Th", "Tv", "ff", "fF", "fw", "fW", "f/" } do
    ok(lhs .. " is not a tree key", own(lhs) == nil, vim.inspect(own(lhs)))
  end
  ok("f filters", mapped_to("f", "filter_on_submit"), vim.inspect(own "f"))
  local leader_keys = {
    ["<Leader>ff"] = "Find files in this folder",
    ["<Leader>fF"] = "Find all files in this folder",
    ["<Leader>fw"] = "Find words in this folder",
    ["<Leader>fW"] = "Find words in all files in this folder",
    ["<Leader>tf"] = "Terminal in this folder (float)",
    ["<Leader>th"] = "Terminal in this folder (horizontal)",
    ["<Leader>tv"] = "Terminal in this folder (vertical)",
    ["<Leader>x"] = "Close buffer",
    ["<Leader>ga"] = "Stage file",
    ["<Leader>gA"] = "Stage all",
    ["<Leader>gu"] = "Unstage file",
    ["<Leader>gt"] = "Stage or unstage file",
    ["<Leader>gx"] = "Unstage all",
    ["<Leader>gr"] = "Revert file",
    ["<Leader>gi"] = "Ignore file",
    ["<Leader>gc"] = "Commit",
    ["<Leader>gC"] = "Amend last commit",
    ["<Leader>gg"] = "Commit and push",
    ["<Leader>gU"] = "Undo last commit",
    ["<Leader>gp"] = "Push",
    ["<Leader>gl"] = "Pull",
    ["<Leader>gf"] = "Fetch",
    ["<Leader>gb"] = "Switch branch",
    ["<Leader>gB"] = "New branch",
    ["<Leader>gd"] = "Delete a branch",
    ["<Leader>gs"] = "Stash changes",
    ["<Leader>gT"] = "Apply a stash",
    ["<Leader>gD"] = "Drop a stash",
  }
  --- The tree's <Leader> keys are the same in every source, and every key of a source names a command it has.
  local function check_keys(name)
    for lhs, desc in pairs(leader_keys) do
      ok(lhs .. " in " .. name, mapped_to(lhs, desc), vim.inspect(own(lhs)))
    end
    for lhs, entry in pairs(tree_state().resolved_mappings) do
      ok(lhs .. " names a command in " .. name, not entry.text:find "<invalid>", entry.text)
    end
  end
  local function status() return git(dir, "status", "--porcelain") end
  check_keys "Files"

  local leader = vim.g.mapleader
  for _, mode in ipairs { "n", "x" } do
    local uncovered = {}
    for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
      if vim.startswith(map.lhs, leader) and not own(map.lhs, mode) then uncovered[#uncovered + 1] = map.lhs end
    end
    ok("no global <Leader> key is left in mode " .. mode, #uncovered == 0, table.concat(uncovered, " "))
  end
  ok("<Leader>q does nothing", is_hidden "<Leader>q", vim.inspect(own "<Leader>q"))

  vim.keymap.set("n", "<Leader>~", "<Nop>", { desc = "made after the tree was opened" })
  vim.cmd.wincmd "p"
  vim.cmd.wincmd "p"
  ok("a later global <Leader> key is hidden on the next entry", is_hidden "<Leader>~", vim.inspect(own "<Leader>~"))
  vim.keymap.del("n", "<Leader>~")

  go_to "a.txt"
  press "Vj<Tab>"
  ok("<Tab> selects the highlighted files", selected() == 2, selected())
  ok("and leaves visual mode", vim.api.nvim_get_mode().mode == "n", vim.api.nvim_get_mode().mode)
  go_to "c.txt"
  press "V<Tab>"
  ok("a second selection adds to the first", selected() == 3, selected())
  press "V<Tab>"
  ok("<Tab> on selected files unselects only those", selected() == 2, selected())
  press "<Tab>"
  ok(
    "<Tab> changes the source while files are selected",
    vim.wait(5000, function() return drawn_source() and drawn_source() ~= "filesystem" end, 20),
    drawn_source()
  )
  press "<S-Tab>"
  wait_for("the Files source", function() return drawn_source() == "filesystem" end)
  wait_for("the files", function() return line_of "a.txt" end)
  go_to "a.txt"
  if selected() == 0 then press "V<Tab>" end
  press "<Esc>"
  ok("<Esc> drops the selection", selected() == 0, selected())

  go_to "b.txt"
  press "<Leader>ga"
  ok("<Leader>ga stages the file in Files", status() == "M  b.txt\n", status())
  wait_for("the staged file", function() return line_of "b.txt" end)
  go_to "b.txt"
  press "<Leader>gu"
  ok("<Leader>gu unstages it in Files", status() == " M b.txt\n", status())
  wait_for("the unstaged file", function() return line_of "c.txt" end)

  local function open_in_background(name)
    local buf = vim.fn.bufadd(dir .. "/" .. name)
    vim.fn.bufload(buf)
    vim.bo[buf].buflisted = true
    return buf
  end
  local c = open_in_background "c.txt"
  go_to "c.txt"
  press "<Leader>x"
  ok("<Leader>x closes the buffer of the file under the cursor in Files", vim.fn.buflisted(c) == 0)
  local unopened = with_notifications(function() press "<Leader>x" end)
  ok("and says so when the file is in no buffer", unopened[1] == "c.txt is not open in a buffer", vim.inspect(unopened))
  ok("the tree is still the window", source() == "filesystem")

  c = open_in_background "c.txt"
  show("buffers", "c.txt")
  check_keys "Buffers"
  ok("bd is not a tree key", own "bd" == nil, vim.inspect(own "bd"))
  ok("d is not a tree key in Buffers", own "d" == nil, vim.inspect(own "d"))
  go_to "c.txt"
  press "<Leader>x"
  ok("<Leader>x closes the buffer under the cursor in Buffers", vim.fn.buflisted(c) == 0)
  wait_for("the buffer to leave the tree", function() return not line_of "c.txt" end)
  ok("<Tab> selects in Buffers", (own("<Tab>", "x") or {}).desc == "Select the highlighted files")

  show("git_status", "b.txt")
  check_keys "Git"
  for _, lhs in ipairs { "A", "ga", "gu", "gt", "gr", "gc", "gg", "gp", "gl", "gU" } do
    ok(lhs .. " is not a tree key in Git", own(lhs) == nil, vim.inspect(own(lhs)))
  end
  go_to "b.txt"
  press "<Leader>ga"
  ok("<Leader>ga stages the file", status() == "M  b.txt\n", status())
  wait_for("the staged file", function() return line_of "b.txt" end)
  go_to "b.txt"
  press "<Leader>gu"
  ok("<Leader>gu unstages it", status() == " M b.txt\n", status())
  wait_for("the unstaged file", function() return line_of "b.txt" end)
  go_to "b.txt"
  local tree = vim.api.nvim_get_current_win()
  with_notifications(function(notes)
    press "<Leader>gc"
    wait_for("the commit message", function() return vim.bo.filetype == "gitcommit" end)
    ok("<Leader>gc stages the file first", status() == "M  b.txt\n", status())
    vim.cmd "q!"
    wait_for("the commit to be aborted", function() return #notes == 1 end)
  end)
  ok("the tree is the window again", vim.api.nvim_get_current_win() == tree and source() == "git_status")
  press "<Leader>gx"
  ok("<Leader>gx unstages all", vim.wait(5000, function() return status() == " M b.txt\n" end, 20), status())

  local function head() return git(dir, "log", "-1", "--format=%s") end
  git(dir, "commit", "-q", "-am", "second")
  local asked = answering("No", function() press "<Leader>gU" end)
  ok(
    "<Leader>gU asks first, and No is the first answer",
    #asked == 1 and asked[1].prompt:find "Undo the last commit" and vim.deep_equal(asked[1].items, { "No", "Yes" }),
    vim.inspect(asked)
  )
  ok("No leaves the commit", head() == "second\n" and #windows_of "neo-tree-popup" == 0, head())
  with_notifications(function(notes)
    answering("Yes", function() press "<Leader>gU" end)
    wait_for("the commit to be undone", function() return #notes == 1 end)
  end)
  ok("Yes undoes it and keeps its changes staged", head() == "files\n" and status() == "M  b.txt\n", status())
  for lhs, question in pairs {
    ["<Leader>gp"] = "push",
    ["<Leader>gl"] = "pull",
    ["<Leader>gr"] = "revert b.txt",
  } do
    asked = answering(nil, function() press(lhs) end)
    ok(
      lhs .. " asks first in the same way",
      #asked == 1 and asked[1].prompt:find(question, 1, true) and #windows_of "neo-tree-popup" == 0,
      vim.inspect(asked)
    )
  end
  ok("and an unanswered question changes nothing", status() == "M  b.txt\n", status())

  local function branches() return git(dir, "branch", "--format=%(refname:short)") end
  local started_on = vim.trim(git(dir, "branch", "--show-current"))
  local input = vim.ui.input
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.ui.input = function(_, on_confirm) on_confirm "topic" end
  with_notifications(function(notes)
    press "<Leader>gB"
    wait_for("the new branch", function() return #notes == 1 end)
  end)
  vim.ui.input = input
  ok("<Leader>gB makes a branch and checks it out", git(dir, "branch", "--show-current") == "topic\n", branches())
  git(dir, "checkout", "-q", started_on)
  with_notifications(function(notes)
    asked = answering("Yes", function()
      press "<Leader>gd"
      -- the branch that is checked out is not listed, which leaves the new one
      wait_for("the picker of branches", function()
        local open = require("snacks").picker.get({ source = "git_branches" })[1]
        return open and open:count() == 1 and vim.bo.filetype == "snacks_picker_input"
      end)
      press "<CR>"
      wait_for("the branch to be deleted", function() return #notes == 1 end)
    end)
  end)
  ok(
    "<Leader>gd asks before it deletes the branch that is picked",
    asked[1].prompt == "Delete branch topic?",
    vim.inspect(asked)
  )
  ok("and deletes it", branches() == started_on .. "\n", branches())

  -- a remote with a branch that the repository has not heard of
  git(dir, "init", "-q", "--bare", remote)
  git(dir, "remote", "add", "origin", remote)
  git(dir, "push", "-q", "origin", started_on)
  git(remote, "branch", "feature", started_on)
  with_notifications(function(notes)
    press "<Leader>gf"
    wait_for("the fetch", function() return #notes == 1 end)
  end)
  with_notifications(function(notes)
    --- How many branches the open picker lists for what is typed in it
    local function listed()
      local open = require("snacks").picker.get({ source = "git_branches" })[1]
      return open and vim.bo.filetype == "snacks_picker_input" and #open:items() or 0
    end
    press "<Leader>gb"
    -- the branch that is checked out, and the two the remote has
    wait_for("the picker of all branches", function() return listed() == 3 end)
    press "ifeature"
    -- Neovim reports typed text from its main loop, which this script does not return to
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = 0 })
    wait_for("the remote's new branch alone", function() return listed() == 1 end)
    press "<CR>"
    wait_for("the checkout", function() return #notes == 1 end)
  end)
  ok(
    "<Leader>gb makes a branch that only the remote has a local one that follows it",
    git(dir, "branch", "--show-current") == "feature\n"
      and git(dir, "rev-parse", "--abbrev-ref", "feature@{upstream}") == "origin/feature\n",
    branches()
  )
  ok(
    "the tree is the window again after the pickers",
    vim.api.nvim_get_current_win() == tree and source() == "git_status"
  )

  ok("AstroNvim's tree event handlers are kept", #require("neo-tree").config.event_handlers > 1)

  -- Not while neo-tree has yet to tell its sources of the last Git command: it would do so with the Files source
  -- shown below, and puts a second refresh of Files off by another 100 ms. That is about when the test ends, and
  -- Neovim exits with 1 when the refresh starts while it is exiting.
  wait_for("the tree to hear of the last Git command", function() return not git_event_pending() end)

  -- which-key comes last: its trigger on <Leader> reads the next keys itself, which the presses above cannot feed.
  -- It finishes its setup on VimEnter, which comes after the -c commands this test runs in.
  require("lazy").load { plugins = { "which-key.nvim" } }
  vim.api.nvim_exec_autocmds("VimEnter", { modeline = false })
  for _, case in ipairs {
    { "filesystem", "a.txt", "f g t x" },
    { "buffers", "a.txt", "f g t x" },
    { "git_status", "b.txt", "f g t x" },
  } do
    local name, row, groups = case[1], case[2], case[3]
    show(name, row)
    vim.cmd.wincmd "p"
    vim.cmd.wincmd "p"
    wait_for("which-key on <Leader> in " .. name, function() return own "<Space>" end)
    ok("which-key opens on <Leader> in " .. name, own("<Space>").desc:find("which-key-trigger", 1, true))
    ok("which-key lists only the tree's groups in " .. name, popup "<Space>" == groups, popup "<Space>")
  end
  ok("which-key lists the Git keys", popup "<Space>g" == "A B C D T U a b c d f g i l p r s t u x", popup "<Space>g")

  ok("nothing reported an error", vim.v.errmsg == "", vim.v.errmsg)
end, debug.traceback)

-- not from inside it: what still runs before Neovim exits (a watcher on the repository) may ask for the directory
vim.cmd.cd(started_in)
vim.fn.delete(dir, "rf")
vim.fn.delete(remote, "rf")
harness.finish(run, err)
