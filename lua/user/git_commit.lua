-- Commit with the message written in a floating window on git's own COMMIT_EDITMSG (<Leader>gc, gg, gC in the file
-- tree). Leaving the window with the message saved commits; leaving it unsaved, or saving an empty message, aborts
-- (also for an amend, where git itself would commit the old message again).
-- A running Neovim cannot be told to open a file and wait, so `git commit` runs as a job whose editor is a shell
-- line: it prints the path to edit, then reads one line, which says whether the message was saved. Anything else,
-- or losing that input when Neovim exits, fails the editor and git aborts.
local git = require "user.git"

local M = {}

-- starts the line with the path, so that it is never taken for the output of a hook
local MARKER = "\30"
local EDITOR = [[sh -c 'printf "\036%s\n" "$1" && read -r reply && test "$reply" = saved' sh]]

-- A float starts with the options of the window it is opened from, the file tree's here. These are set back to
-- their global values, so that the message is edited in a window like any other.
local normal_window_options = {
  "number",
  "relativenumber",
  "signcolumn",
  "foldcolumn",
  "statuscolumn",
  "cursorline",
  "wrap",
  "list",
  "spell",
  "colorcolumn",
  "winfixwidth",
  "winfixheight",
}

---@class user.git_commit.Active
---@field window? snacks.win the message window, once git has asked for the editor
---@field unsaved? boolean the window was left without the message having been saved

---@type user.git_commit.Active? the commit that is running: one at a time, as they share COMMIT_EDITMSG
local active

---@param message string
---@param level integer
---@param title? string
local function notify(message, level, title) vim.notify(message, level, { title = title or "git commit" }) end

--- The message window's title: its name and, as a buffer's tab in the tabline has it, the mark of unsaved changes.
---@param buf integer
---@return [string, string][]
local function title(buf)
  local mark = vim.bo[buf].modified and require("astroui").get_icon "FileModified" .. " " or ""
  return { { " Commit " .. mark, "FloatTitle" } }
end

--- Opens `path` in the message window.
---@param path string
---@param dir string a directory in the repository
---@param on_close fun(saved: boolean) called when the window is left, with whether the message was saved in it
---@return snacks.win
local function edit(path, dir, on_close)
  local buf = vim.fn.bufadd(path)
  vim.bo[buf].swapfile = false
  vim.fn.bufload(buf)
  -- git writes a new COMMIT_EDITMSG for every commit: nothing of this buffer may be left for the next one
  vim.bo[buf].bufhidden = "wipe"

  local wo = {}
  for _, name in ipairs(normal_window_options) do
    wo[name] = vim.go[name]
  end
  local saved = false
  local window = require("snacks").win {
    buf = buf,
    title = title(buf),
    border = true,
    width = 0.6,
    min_width = 80,
    height = 0.6,
    backdrop = false,
    minimal = false,
    wo = wo,
    keys = { q = false }, -- snacks closes its windows on q, which records a macro in a normal buffer
    on_win = function(self)
      -- git starts its editor inside the repository: <Leader>Ac (user/ai/commit.lua) looks for the commit there
      vim.api.nvim_win_call(self.win, function() vim.cmd.lcd(vim.fn.fnameescape(dir)) end)
    end,
    on_close = function() on_close(saved) end,
  }
  require("user.float_focus").take_priority(window.win)
  -- both on the buffer, so they go when the buffer is wiped
  vim.api.nvim_create_autocmd("BufWritePost", { buffer = buf, callback = function() saved = true end })
  vim.api.nvim_create_autocmd("BufModifiedSet", {
    buffer = buf,
    callback = function() window:set_title(title(buf)) end,
  })
  return window
end

--- Whether the file `path` has changes of which none is staged: an untracked file, or one changed in the work tree
--- only. False for an unchanged or ignored file, and when git cannot tell, which `git commit` then reports.
---@param dir string
---@param path string
---@return boolean
local function only_unstaged_changes(dir, path)
  local cmd = { "git", git.LITERAL_PATHS, "status", "--porcelain", "--untracked-files=all", "--", path }
  local status = vim.system(cmd, { cwd = dir, text = true }):wait()
  -- a line is "XY path", where X is the file's state in the index: a space when it is as in the last commit
  return status.code == 0 and status.stdout:find "^[ ?]" ~= nil
end

---@class user.git_commit.Opts
---@field dir string a directory in the repository to commit in
---@field stage? string a file to stage first, when it has changes of which none is staged
---@field amend? boolean replace the last commit, starting from its message
---@field push? boolean push after the commit
---@field on_change? fun() called after each change made to the repository: the file staged, the commit, the push

--- Commits what is staged in the repository of `opts.dir`, with the message written in a floating window.
--- `opts.stage` makes that a commit of one changed file without staging it by hand; it stays staged when the commit
--- is aborted. A file staged in part is left as it is: what is not in the index was left out of it on purpose.
---@param opts user.git_commit.Opts
function M.commit(opts)
  if active then
    if active.window then
      active.window:focus()
    else
      notify("A commit is already being prepared", vim.log.levels.WARN)
    end
    return
  end
  if opts.stage and only_unstaged_changes(opts.dir, opts.stage) then
    local cmd = { "git", git.LITERAL_PATHS, "add", "--", opts.stage }
    local added = vim.system(cmd, { cwd = opts.dir, text = true }):wait()
    if added.code ~= 0 then
      notify(vim.trim(added.stderr), vim.log.levels.ERROR, "git add")
      return
    end
    if opts.on_change then opts.on_change() end
  end
  local current = {}
  active = current

  local output = ""
  local job
  job = vim.system(
    opts.amend and { "git", "commit", "--amend" } or { "git", "commit" },
    {
      cwd = opts.dir,
      env = { GIT_EDITOR = EDITOR },
      stdin = true,
      text = true,
      stdout = function(_, data)
        if not data then return end
        output = output .. data
        local path = output:match(MARKER .. "([^\n]*)\n")
        if not path then return end
        output = output:gsub(MARKER .. "[^\n]*\n", "")
        vim.schedule(function()
          current.window = edit(path, opts.dir, function(saved)
            current.window = nil
            current.unsaved = not saved
            if not job:is_closing() then job:write(saved and "saved\n" or "unsaved\n") end
          end)
        end)
      end,
    },
    vim.schedule_wrap(function(result)
      active = nil
      -- before the window is closed here, which counts as leaving it unsaved
      local left_unsaved = current.unsaved
      if current.window then current.window:close() end

      local errors = vim.trim(result.stderr or "")
      if result.code ~= 0 then
        if left_unsaved then
          notify("Commit aborted: the message was not saved", vim.log.levels.WARN)
        elseif errors:find "^Aborting commit due to empty commit message" then
          notify("Commit aborted: empty message", vim.log.levels.WARN)
        else
          -- nothing staged: git says so on its output, with nothing on its error output
          notify(errors ~= "" and errors or vim.trim(output), vim.log.levels.ERROR)
        end
        return
      end
      notify(vim.trim(output), vim.log.levels.INFO)
      if opts.on_change then opts.on_change() end
      if opts.push then git.push { dir = opts.dir, on_change = opts.on_change } end
    end)
  )
end

return M
