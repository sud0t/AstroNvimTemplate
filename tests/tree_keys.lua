-- The file tree's keys inside the whole configuration (lua/plugins/neo-tree.lua, lua/user/hidden_keys.lua).
--   nvim --headless -c 'luafile ~/.config/nvim/tests/tree_keys.lua' -c 'qa!' < /dev/null
-- prints "ok: N checks", or what failed and exits with 1. Run it after changing either file and after an update
-- of neo-tree, AstroNvim or which-key: the keys that are moved or removed are theirs.

local failures, count = {}, 0
local function ok(name, cond, detail)
  count = count + 1
  if not cond then failures[#failures + 1] = name .. (detail ~= nil and ("\n      " .. tostring(detail)) or "") end
end

local function press(keys) vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false) end
local function wait_for(what, cond) assert(vim.wait(5000, cond, 20), "timed out waiting for " .. what) end
local function git(dir, ...)
  local result = vim
    .system({ "git", "-c", "user.name=test", "-c", "user.email=test@localhost", ... }, { cwd = dir })
    :wait()
  assert(result.code == 0, "git failed: " .. (result.stderr or ""))
  return result.stdout
end

local function tree_state() return require("neo-tree.sources.manager").get_state_for_window() end
local function source() return vim.bo.filetype == "neo-tree" and vim.b.neo_tree_source or nil end
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
    wait_for("the source after " .. tostring(before), function() return source() and source() ~= before end)
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

local dir = vim.fn.tempname()
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

  ok("<Tab> is next source", mapped_to("<Tab>", "next_source"), vim.inspect(own "<Tab>"))
  ok("<S-Tab> is previous source", mapped_to("<S-Tab>", "prev_source"), vim.inspect(own "<S-Tab>"))
  for _, lhs in ipairs { "<", ">", "[b", "]b", "<C-;>", "<Space>", "T", "Tf", "Th", "Tv", "ff", "fF", "fw", "fW", "f/" } do
    ok(lhs .. " is not a tree key", own(lhs) == nil, vim.inspect(own(lhs)))
  end
  ok("f filters", mapped_to("f", "filter_on_submit"), vim.inspect(own "f"))
  for lhs, desc in pairs {
    ["<Leader>ff"] = "Find files in this folder",
    ["<Leader>fF"] = "Find all files in this folder",
    ["<Leader>fw"] = "Find words in this folder",
    ["<Leader>fW"] = "Find words in all files in this folder",
    ["<Leader>tf"] = "Terminal in this folder (float)",
    ["<Leader>th"] = "Terminal in this folder (horizontal)",
    ["<Leader>tv"] = "Terminal in this folder (vertical)",
  } do
    ok(lhs .. " in Files", mapped_to(lhs, desc), vim.inspect(own(lhs)))
  end
  for lhs, entry in pairs(tree_state().resolved_mappings) do
    ok(lhs .. " names a command", not entry.text:find "<invalid>", entry.text)
  end

  local leader = vim.g.mapleader
  for _, mode in ipairs { "n", "x" } do
    local uncovered = {}
    for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
      if vim.startswith(map.lhs, leader) and not own(map.lhs, mode) then uncovered[#uncovered + 1] = map.lhs end
    end
    ok("no global <Leader> key is left in mode " .. mode, #uncovered == 0, table.concat(uncovered, " "))
  end
  ok("<Leader>q does nothing", is_hidden "<Leader>q", vim.inspect(own "<Leader>q"))
  ok("the Git keys are not in Files", is_hidden "<Leader>gc", vim.inspect(own "<Leader>gc"))

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
  wait_for("another source", function() return source() and source() ~= "filesystem" end)
  local after_tab = source()
  press "<S-Tab>"
  wait_for("the Files source", function() return source() == "filesystem" end)
  ok("<Tab> changes the source while files are selected", after_tab ~= nil)
  wait_for("the files", function() return line_of "a.txt" end)
  go_to "a.txt"
  if selected() == 0 then press "V<Tab>" end
  press "<Esc>"
  ok("<Esc> drops the selection", selected() == 0, selected())

  show("buffers", "a.txt")
  ok("<Leader>x in Buffers", mapped_to("<Leader>x", "Close buffer"), vim.inspect(own "<Leader>x"))
  ok("bd is not a tree key", own "bd" == nil, vim.inspect(own "bd"))
  ok("d is not a tree key in Buffers", own "d" == nil, vim.inspect(own "d"))
  ok("the find keys are not in Buffers", is_hidden "<Leader>ff", vim.inspect(own "<Leader>ff"))
  ok("<Tab> selects in Buffers", (own("<Tab>", "x") or {}).desc == "Select the highlighted files")

  show("git_status", "b.txt")
  local git_keys = {
    ["<Leader>ga"] = "Stage file",
    ["<Leader>gA"] = "Stage all",
    ["<Leader>gu"] = "Unstage file",
    ["<Leader>gt"] = "Stage or unstage file",
    ["<Leader>gr"] = "Revert file",
    ["<Leader>gc"] = "Commit",
    ["<Leader>gg"] = "Commit and push",
    ["<Leader>gp"] = "Push",
    ["<Leader>gl"] = "Pull",
    ["<Leader>gU"] = "Undo last commit",
  }
  for lhs, desc in pairs(git_keys) do
    ok(lhs .. " in Git", mapped_to(lhs, desc), vim.inspect(own(lhs)))
  end
  for _, lhs in ipairs { "A", "ga", "gu", "gt", "gr", "gc", "gg", "gp", "gl", "gU" } do
    ok(lhs .. " is not a tree key in Git", own(lhs) == nil, vim.inspect(own(lhs)))
  end
  for lhs, entry in pairs(tree_state().resolved_mappings) do
    ok(lhs .. " names a command in Git", not entry.text:find "<invalid>", entry.text)
  end
  go_to "b.txt"
  press "<Leader>ga"
  ok("<Leader>ga stages the file", git(dir, "status", "--porcelain") == "M  b.txt\n", git(dir, "status", "--porcelain"))
  wait_for("the staged file", function() return line_of "b.txt" end)
  go_to "b.txt"
  press "<Leader>gu"
  ok("<Leader>gu unstages it", git(dir, "status", "--porcelain") == " M b.txt\n", git(dir, "status", "--porcelain"))

  ok("AstroNvim's tree event handlers are kept", #require("neo-tree").config.event_handlers > 1)

  -- which-key comes last: its trigger on <Leader> reads the next keys itself, which the presses above cannot feed.
  -- It finishes its setup on VimEnter, which comes after the -c commands this test runs in.
  require("lazy").load { plugins = { "which-key.nvim" } }
  vim.api.nvim_exec_autocmds("VimEnter", { modeline = false })
  for _, case in ipairs {
    { "filesystem", "a.txt", "f t" },
    { "buffers", "a.txt", "t x" },
    { "git_status", "b.txt", "g t" },
  } do
    local name, row, groups = case[1], case[2], case[3]
    show(name, row)
    vim.cmd.wincmd "p"
    vim.cmd.wincmd "p"
    wait_for("which-key on <Leader> in " .. name, function() return own "<Space>" end)
    ok("which-key opens on <Leader> in " .. name, own("<Space>").desc:find("which-key-trigger", 1, true))
    ok("which-key lists only the tree's groups in " .. name, popup "<Space>" == groups, popup "<Space>")
  end
  ok("which-key lists the Git keys", popup "<Space>g" == "A U a c g l p r t u", popup "<Space>g")

  ok("nothing reported an error", vim.v.errmsg == "", vim.v.errmsg)
end, debug.traceback)

vim.fn.delete(dir, "rf")
if not run then failures[#failures + 1] = "the test itself failed:\n" .. tostring(err) end
if #failures > 0 then
  io.stderr:write(("%d of %d checks failed:\n"):format(#failures, count))
  for _, failure in ipairs(failures) do
    io.stderr:write("  - " .. failure .. "\n")
  end
  vim.cmd "cq"
end
print(("ok: %d checks"):format(count))
