-- The git keys of a file buffer inside the whole configuration: they only look (lua/plugins/gitsigns.lua, and the
-- git parts of astrocore.lua, snacks.lua and diffview.lua there).
--   tests/run.sh git_keys
-- prints "ok: N checks", or what failed and exits with 1. Run it after changing those files and after an update of
-- AstroNvim, gitsigns, snacks or diffview: the keys and actions that are taken out are theirs.

local harness = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/harness.lua")
harness.whole_config()
local ok = harness.ok

local function wait_for(what, cond) assert(vim.wait(5000, cond, 20), "timed out waiting for " .. what) end

--- The mapping of `lhs` that the current buffer has of its own
local function own(lhs, mode)
  local map = vim.fn.maparg(lhs, mode, false, true)
  return map.buffer == 1 and map or nil
end

local dir = vim.fn.tempname()
local started_in = vim.fn.getcwd()
local run, err = xpcall(function()
  vim.fn.mkdir(dir)
  local function git(...)
    local result = vim.system({ "git", ... }, { cwd = dir, text = true }):wait()
    assert(result.code == 0, "git failed: " .. (result.stderr or ""))
  end
  vim.fn.writefile({ "one", "two" }, dir .. "/a.txt")
  git("init", "-q")
  git("config", "user.name", "test")
  git("config", "user.email", "test@localhost")
  git("add", ".")
  git("commit", "-q", "-m", "first")
  vim.fn.writefile({ "one", "two", "three" }, dir .. "/a.txt")
  git("commit", "-q", "-am", "second")
  vim.fn.writefile({ "one", "changed" }, dir .. "/a.txt")

  vim.cmd.cd(dir)
  vim.cmd.edit "a.txt"
  wait_for("gitsigns' keys", function() return own("<Leader>gp", "n") end)

  for mode, keys in pairs {
    n = { "<Leader>gp", "<Leader>gd", "<Leader>gl", "<Leader>gL", "]g", "[g", "]G", "[G" },
    x = { "ig" },
    o = { "ig" },
  } do
    for _, lhs in ipairs(keys) do
      ok(lhs .. " looks, and stays in mode " .. mode, own(lhs, mode))
    end
  end

  for _, mode in ipairs { "n", "x", "s" } do
    for _, lhs in ipairs { "<Leader>gs", "<Leader>gS", "<Leader>gr", "<Leader>gR" } do
      ok(lhs .. " does nothing in mode " .. mode, vim.fn.maparg(lhs, mode) == "", vim.fn.maparg(lhs, mode))
    end
    -- by what the key says it does, so that a key AstroNvim adds or moves is found as well
    local changing = {}
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, mode)) do
      local desc = (map.desc or ""):lower()
      if desc:find "stage" or desc:find "reset" then changing[#changing + 1] = map.lhs .. " (" .. map.desc .. ")" end
    end
    ok("no key of the buffer stages or resets in mode " .. mode, #changing == 0, table.concat(changing, ", "))
  end

  for _, lhs in ipairs { "<Leader>gb", "<Leader>gT" } do
    ok(lhs .. " opens no picker that changes the repository", vim.fn.maparg(lhs, "n") == "", vim.fn.maparg(lhs, "n"))
  end

  local picker = require("snacks.picker.config").get
  for _, source in ipairs { "git_log", "git_log_file", "git_log_line" } do
    ok("Enter does not check out in " .. source, type(picker({ source = source }).confirm) == "function")
  end
  -- snacks keeps the keys of a picker as Neovim spells them, whatever the spelling they were given in
  for _, source in ipairs { "git_status", "git_diff" } do
    local keys = picker({ source = source }).win.input.keys
    ok("<Tab> selects in " .. source, keys["<Tab>"][1] == "select_and_next", vim.inspect(keys["<Tab>"]))
    ok("<C-r> restores nothing in " .. source, keys["<C-R>"] == false, vim.inspect(keys["<C-R>"]))
  end
  -- opened from the file tree, which has the keys that make and delete a branch
  local branch_keys = picker({ source = "git_branches" }).win.input.keys
  ok(
    "<C-a> makes no branch in the picker of branches",
    branch_keys["<C-A>"][1] == "select_all",
    vim.inspect(branch_keys["<C-A>"])
  )
  ok("and <C-x> deletes none", branch_keys["<C-X>"] == false, vim.inspect(branch_keys["<C-X>"]))

  local diffview = require "diffview.lib"
  --- The buffers of the open Diffview by what they show
  local function diffview_buffers()
    local found = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(buf)
      if vim.bo[buf].filetype == "DiffviewFiles" then found.panel = buf end
      if name:find "^diffview://.*a%.txt$" then found.index = buf end
    end
    return found
  end
  --- Diffview opens in steps of its own, the last of which puts both sides of the first file in windows. A view
  --- that is closed before that fails in a later step.
  local function opened()
    local view = diffview.get_current_view()
    local sides = 0
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.wo[win].diff and vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)):find "a%.txt$" then
        sides = sides + 1
      end
    end
    return view ~= nil and view.ready and sides == 2
  end
  vim.cmd.DiffviewOpen()
  wait_for("diffview", function() return opened() and diffview_buffers().panel and diffview_buffers().index end)
  local shown = diffview_buffers()
  local function panel_key(lhs)
    return vim.api.nvim_buf_call(shown.panel, function() return own(lhs, "n") end)
  end
  for _, lhs in ipairs { "-", "s", "S", "U", "X" } do
    ok(lhs .. " changes nothing in Diffview's file panel", panel_key(lhs) == nil, vim.inspect(panel_key(lhs)))
  end
  ok("q closes Diffview from its file panel", (panel_key "q" or {}).desc == "Close diffview")
  wait_for("the index in a window", function() return vim.fn.bufwinid(shown.index) ~= -1 end)
  ok("the index cannot be edited in Diffview", not vim.bo[shown.index].modifiable)
  ok("the file can", vim.bo[vim.fn.bufnr(dir .. "/a.txt")].modifiable)
  vim.cmd.DiffviewClose()

  local head = vim.trim(vim.system({ "git", "rev-parse", "HEAD" }, { cwd = dir, text = true }):wait().stdout)
  local closed = false
  picker({ source = "git_log" }).confirm({ close = function() closed = true end }, { cwd = dir, commit = head })
  --- What the file panel of the Diffview in this tab page lists
  local function listed()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype == "DiffviewFiles" then
        return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      end
    end
    return ""
  end
  wait_for("the commit in diffview", function() return opened() and listed():find("a.txt", 1, true) end)
  ok("Enter on a commit closes the picker", closed)
  ok("and shows what the commit changed in Diffview", listed():find(head:sub(-8) .. "^!", 1, true), listed())
  vim.cmd.DiffviewClose()

  ok("nothing reported an error", vim.v.errmsg == "", vim.v.errmsg)
end, debug.traceback)

-- not from inside it: what still runs before Neovim exits (gitsigns watches the repository) may ask for the directory
vim.cmd.cd(started_in)
vim.fn.delete(dir, "rf")
harness.finish(run, err)
