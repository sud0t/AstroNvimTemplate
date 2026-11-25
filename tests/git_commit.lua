-- The commit message window inside the whole configuration (lua/user/git_commit.lua).
--   nvim --headless -c 'luafile ~/.config/nvim/tests/git_commit.lua' -c 'qa!' < /dev/null
-- prints "ok: N checks", or what failed and exits with 1. Run it after changing that file and after an update of
-- git or snacks.nvim: git has to pass the output and the input of its editor through, and the window is snacks'.

local failures, count = {}, 0
local function ok(name, cond, detail)
  count = count + 1
  if not cond then failures[#failures + 1] = name .. (detail ~= nil and ("\n      " .. tostring(detail)) or "") end
end

local function wait_for(what, cond) assert(vim.wait(5000, cond, 20), "timed out waiting for " .. what) end
local function press(keys) vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false) end

local dir = vim.fn.tempname()
local remote = dir .. ".git"
local function git(...)
  local result = vim.system({ "git", ... }, { cwd = dir, text = true }):wait()
  assert(result.code == 0, "git failed: " .. (result.stderr or ""))
  return vim.trim(result.stdout)
end
local function stage(name)
  vim.fn.writefile({ name }, dir .. "/" .. name)
  git("add", name)
end

local notes = {}
local notify = vim.notify
---@diagnostic disable-next-line: duplicate-set-field
vim.notify = function(message, level, opts)
  notes[#notes + 1] = { message = message, level = level, title = (opts or {}).title }
end

local function floats()
  return vim.tbl_filter(
    function(win) return vim.api.nvim_win_get_config(win).relative ~= "" end,
    vim.api.nvim_list_wins()
  )
end

--- Starts a commit and returns once its window is the current one.
local function open(opts)
  notes = {}
  require("user.git_commit").commit(vim.tbl_extend("force", { dir = dir }, opts or {}))
  wait_for("the message window", function() return vim.bo.filetype == "gitcommit" end)
end
--- Waits until git has reported how the commit ended, and returns that notification.
local function result()
  wait_for("git's result", function() return #notes > 0 end)
  return notes[1]
end

local run, err = xpcall(function()
  vim.fn.mkdir(dir)
  git("init", "-q")
  git("config", "user.name", "test")
  git("config", "user.email", "test@localhost")
  stage "a.txt"
  git("commit", "-q", "-m", "first")

  vim.cmd.edit(dir .. "/a.txt")
  local origin = vim.api.nvim_get_current_win()
  -- options a window may have that the message window is opened from, as the file tree's has
  vim.cmd "setlocal nonumber signcolumn=no"

  stage "b.txt"
  local done = 0
  open { on_change = function() done = done + 1 end }
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local config = vim.api.nvim_win_get_config(win)
  ok("the message opens in a float", config.relative == "editor", vim.inspect(config.relative))
  ok(
    "the float is centred",
    math.abs((vim.o.columns - config.width) / 2 - config.col) <= 2
      and math.abs((vim.o.lines - config.height) / 2 - config.row) <= 2,
    ("%sx%s at %s,%s of %sx%s"):format(config.width, config.height, config.col, config.row, vim.o.columns, vim.o.lines)
  )
  ok(
    "on git's COMMIT_EDITMSG",
    vim.api.nvim_buf_get_name(buf) == dir .. "/.git/COMMIT_EDITMSG",
    vim.api.nvim_buf_get_name(buf)
  )
  ok("which can be edited", vim.bo.modifiable and not vim.bo.readonly)
  ok("with git's comments below the message", vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]:find "^# Please enter")
  ok("in the repository", vim.fn.getcwd() == dir, vim.fn.getcwd())
  ok(
    "with the options of a normal window",
    vim.wo.number == vim.go.number
      and vim.go.number
      and vim.wo.signcolumn == vim.go.signcolumn
      and vim.go.signcolumn ~= "no",
    ("number %s, signcolumn %s"):format(tostring(vim.wo.number), vim.wo.signcolumn)
  )
  ok("q is not a key of the window", vim.fn.maparg("q", "n", false, true).buffer ~= 1)

  local icon = require("astroui").get_icon
  local function title()
    local text = ""
    for _, chunk in ipairs(vim.api.nvim_win_get_config(win).title) do
      text = text .. chunk[1]
    end
    return text
  end
  local saved, unsaved = " Commit ", " Commit " .. icon "FileModified" .. " "
  ok("the title is the name alone", title() == saved, title())
  -- Neovim reports a change of 'modified' from its main loop, which this script does not return to
  local function modified_set() vim.api.nvim_exec_autocmds("BufModifiedSet", { buffer = buf }) end
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "draft" })
  modified_set()
  ok("unsaved changes are marked as in the tabline", title() == unsaved, title())
  vim.cmd "silent write"
  modified_set()
  ok("until they are saved", title() == saved, title())
  ok("and the window stays open", vim.api.nvim_get_current_win() == win and #floats() == 1)

  require("user.git_commit").commit { dir = dir }
  ok("a second commit opens no second window", #floats() == 1 and vim.api.nvim_get_current_win() == win, #floats())

  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "second" })
  vim.cmd "wq"
  ok(
    "save and quit commits",
    result().message:find("second", 1, true) and git("log", "-1", "--format=%s") == "second",
    vim.inspect(notes)
  )
  ok("the caller is told", done == 1, done)
  ok("the window is gone", #floats() == 0 and vim.api.nvim_get_current_win() == origin)
  ok("and so is its buffer", not vim.api.nvim_buf_is_valid(buf))
  ok("the directory of the other windows is untouched", vim.fn.getcwd() ~= dir, vim.fn.getcwd())

  stage "c.txt"
  open()
  buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "never saved" })
  vim.cmd "q!"
  ok("quitting without saving aborts", result().message == "Commit aborted: empty message", vim.inspect(notes))
  ok("no commit was made", git("log", "-1", "--format=%s") == "second")

  open()
  buf = vim.api.nvim_get_current_buf()
  ok("the next commit starts from git's template", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "")
  vim.cmd "wq"
  ok("saving an empty message aborts", result().message == "Commit aborted: empty message", vim.inspect(notes))
  ok("still no commit", git("log", "-1", "--format=%s") == "second")

  open()
  press "ithird<Esc>ZZ"
  ok(
    "typing a message and ZZ commits",
    result().level == vim.log.levels.INFO and git("log", "-1", "--format=%s") == "third",
    vim.inspect(notes)
  )

  git("init", "-q", "--bare", remote)
  git("remote", "add", "origin", remote)
  git("push", "-q", "-u", "origin", "HEAD")
  stage "d.txt"
  done = 0
  open { push = true, on_change = function() done = done + 1 end }
  press "ifourth<Esc>ZZ"
  wait_for("the push", function() return #notes == 2 end)
  ok(
    "commit and push pushes the commit",
    notes[2].title == "git push"
      and notes[2].level == vim.log.levels.INFO
      and git("--git-dir", remote, "log", "-1", "--format=%s") == "fourth",
    vim.inspect(notes)
  )
  ok("the caller is told after the commit and after the push", done == 2, done)

  -- not through git(): the first column of a line can be a space
  local function status()
    return vim.system({ "git", "status", "--porcelain" }, { cwd = dir, text = true }):wait().stdout
  end
  vim.fn.writefile({ "e" }, dir .. "/e.txt")
  done = 0
  open { stage = dir .. "/e.txt", on_change = function() done = done + 1 end }
  ok("a file with nothing staged is staged first", status() == "A  e.txt\n", status())
  ok("and is in the commit", vim.fn.search([[^#\s\+new file:\s\+e\.txt$]], "nw") > 0)
  ok("the caller is told of the staging", done == 1, done)
  vim.fn.writefile({ "f" }, dir .. "/f.txt")
  require("user.git_commit").commit { dir = dir, stage = dir .. "/f.txt" }
  ok("nothing is staged into a commit that is being written", status() == "A  e.txt\n?? f.txt\n", status())
  vim.cmd "q!"
  ok(
    "an aborted commit leaves the file staged",
    result().level == vim.log.levels.WARN and status() == "A  e.txt\n?? f.txt\n"
  )

  vim.fn.writefile({ "e", "more" }, dir .. "/e.txt")
  done = 0
  open { stage = dir .. "/e.txt", on_change = function() done = done + 1 end }
  ok("a file staged in part is left as it is", status() == "AM e.txt\n?? f.txt\n" and done == 0, status())
  press "ififth<Esc>ZZ"
  ok(
    "and only its staged part is committed",
    result().level == vim.log.levels.INFO and status() == " M e.txt\n?? f.txt\n",
    vim.inspect(notes)
  )
  git("checkout", "-q", "--", "e.txt")
  vim.fn.delete(dir .. "/f.txt")

  vim.fn.mkdir(dir .. "/.git/info", "p")
  vim.fn.writefile({ "scratch.txt" }, dir .. "/.git/info/exclude")
  vim.fn.writefile({ "scratch" }, dir .. "/scratch.txt")
  for name, what in pairs { ["a.txt"] = "an unchanged file", ["scratch.txt"] = "an ignored file" } do
    notes, done = {}, 0
    require("user.git_commit").commit {
      dir = dir,
      stage = dir .. "/" .. name,
      on_change = function() done = done + 1 end,
    }
    local refused = result()
    ok(
      what .. " is not staged",
      refused.title == "git commit" and refused.message:find "nothing to commit" and done == 0 and status() == "",
      vim.inspect(refused) .. status()
    )
  end

  notes = {}
  require("user.git_commit").commit { dir = dir }
  local nothing = result()
  ok(
    "nothing staged is reported",
    nothing.level == vim.log.levels.ERROR and nothing.message:find "nothing to commit",
    vim.inspect(nothing)
  )
  ok("without a window", #floats() == 0)

  ok("nothing reported an error", vim.v.errmsg == "", vim.v.errmsg)
end, debug.traceback)

vim.notify = notify
vim.fn.delete(dir, "rf")
vim.fn.delete(remote, "rf")
if not run then failures[#failures + 1] = "the test itself failed:\n" .. tostring(err) end
if #failures > 0 then
  io.stderr:write(("%d of %d checks failed:\n"):format(#failures, count))
  for _, failure in ipairs(failures) do
    io.stderr:write("  - " .. failure .. "\n")
  end
  vim.cmd "cq"
end
print(("ok: %d checks"):format(count))
