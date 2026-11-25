-- Autopairs inside the whole configuration (lua/plugins/autopairs.lua): a file that the file tree opens has its
-- pairs at once. The tree lists a buffer only after it has entered it, and the cases are the ones where nothing
-- gave such a buffer its pairs afterwards: a file opened after the first one of a git repository, a file that was
-- loaded before (the tree's preview does that), and a buffer that had pairs and was unlisted meanwhile.
--   tests/run.sh autopairs
-- prints "ok: N checks", or what failed and exits with 1. Run it after changing that file and after an update of
-- nvim-autopairs, neo-tree or AstroNvim: neo-tree decides when it lists the buffer it opens and what its preview
-- loads, and AstroNvim that only a listed buffer gets pairs and which files it detects the filetype of twice.
-- The keys go through the insert-mode mappings. The AI completion (lua/plugins/minuet.lua) asks a model from
-- insert mode once it is switched on: it stays off, a check says that it was never loaded, and tests/harness.lua
-- fails a test that starts curl.

local harness = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/harness.lua")
harness.whole_config()
local ok = harness.ok

local function press(keys) vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false) end
local function wait_for(what, cond) assert(vim.wait(5000, cond, 20), "timed out waiting for " .. what) end

--- Types `keys` on a new line of the current buffer and returns what the line holds then.
local function typed(keys)
  press("o" .. keys) -- (feedkeys leaves insert mode itself when the keys are used up)
  local line = vim.api.nvim_get_current_line()
  vim.cmd "silent undo"
  return line
end

local function tree_state() return require("neo-tree.sources.manager").get_state_for_window() end
local function line_of(name)
  local state = vim.bo.filetype == "neo-tree" and tree_state()
  if not (state and state.tree) then return nil end
  for line = 1, vim.api.nvim_buf_line_count(0) do
    local node = state.tree:get_node(line)
    if node and node.name == name then return line end
  end
end
--- Puts the cursor on the file's row in the tree.
local function go_to(name)
  vim.cmd "Neotree focus"
  wait_for("the row of " .. name, function() return line_of(name) end)
  vim.api.nvim_win_set_cursor(0, { line_of(name), 0 })
end

local dir = vim.fn.tempname()
local started_in = vim.fn.getcwd()
local run, err = xpcall(function()
  vim.fn.mkdir(dir)
  for _, name in ipairs { "first.py", "second.py", "previewed.py" } do
    vim.fn.writefile({ "x = 1" }, dir .. "/" .. name)
  end
  assert(vim.system({ "git", "init", "-q", dir }):wait().code == 0, "git init failed")
  vim.cmd.cd(dir)
  local function buffer_of(name) return vim.fn.bufadd(dir .. "/" .. name) end
  local function opened_from_tree(name)
    go_to(name)
    press "<CR>"
    wait_for(name .. " from the tree", function() return vim.api.nvim_get_current_buf() == buffer_of(name) end)
  end

  vim.cmd.edit "first.py"
  wait_for("autopairs", function() return package.loaded["nvim-autopairs"] end)
  ok("the first file, opened with :edit, gets pairs", typed "(" == "()", typed "(")
  -- (while AstroNvim follows files it detects the filetype of each new one a second time, a moment after the
  -- tree has listed it, which maps the keys then: here nothing does)
  ok(
    "AstroNvim follows no file after the first one of a git repository",
    not pcall(vim.api.nvim_get_autocmds, { group = "file_user_events" })
  )

  opened_from_tree "second.py"
  -- neo-tree's setup clears netrw's autocommand group with silent!, which leaves an error message behind here,
  -- where netrw is off and the group does not exist
  vim.v.errmsg = ""
  ok("the tree lists the file it opens", vim.bo.buflisted)
  ok("a file that was never loaded gets pairs when the tree opens it", typed "(" == "()", typed "(")

  local previewed = buffer_of "previewed.py"
  go_to "previewed.py"
  press "P"
  wait_for("the preview", function() return vim.api.nvim_buf_is_loaded(previewed) end)
  press "<Esc>"
  -- The preview loads image.nvim, which would write kitty's escape sequence that clears all images to this
  -- test's output when Neovim exits. (Not with `require`: where the output is no terminal and no pipe the
  -- module fails to load, and writes nothing.)
  local kitty = package.loaded["image/backends/kitty"]
  if type(kitty) == "table" then kitty.clear = function() end end
  ok(
    "the tree's preview leaves the file in a loaded buffer that is not listed",
    vim.api.nvim_buf_is_loaded(previewed) and not vim.bo[previewed].buflisted
  )
  opened_from_tree "previewed.py"
  ok("a file the tree opens after its preview gets pairs", typed "(" == "()", typed "(")
  ok("and pairs of quotes", typed '"' == '""', typed '"')

  -- (entered while it is not listed, such a buffer loses its keys and still counts as mapped: entering it
  -- again would map nothing)
  vim.bo[buffer_of "second.py"].buflisted = false
  opened_from_tree "second.py"
  ok("a buffer that had pairs and was unlisted meanwhile has them when the tree opens it", typed "(" == "()", typed "(")

  ok("the AI completion was never loaded", package.loaded["minuet"] == nil)
  ok("nothing reported an error", vim.v.errmsg == "", vim.v.errmsg)
end, debug.traceback)

-- not from inside it: what still runs before Neovim exits (a language server) may ask for the directory
vim.cmd.cd(started_in)
vim.fn.delete(dir, "rf")
harness.finish(run, err)
