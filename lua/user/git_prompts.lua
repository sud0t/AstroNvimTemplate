-- What the file tree asks before a Git command of user/git.lua runs: a confirmation, a name, or a pick in one of
-- snacks' Git pickers. Each function takes the repository and runs its command once it has the answer.
local M = {}

--- Runs `action` once the question is answered with Yes. No comes first, so that it is what Enter alone answers.
---@param question string
---@param action fun()
local function confirmed(question, action)
  vim.ui.select({ "No", "Yes" }, { prompt = question }, function(answer)
    if answer == "Yes" then action() end
  end)
end

--- Opens one of snacks' Git pickers on the repository and hands the picked item to `on_pick`.
---@param repo user.git.Repository
---@param picker snacks.picker.Config the source, and a title that says what Enter does: two keys open one source
---@param on_pick fun(item: snacks.picker.Item)
local function pick(repo, picker, on_pick)
  require("snacks").picker.pick(vim.tbl_extend("error", picker, {
    cwd = repo.dir,
    -- the window the key was pressed in: a closed picker would otherwise leave for the one it opens files in
    main = { current = true },
    confirm = function(open, item)
      open:close()
      -- not before the picker has left insert mode, which it does after this: a picker that `on_pick` opens to
      -- ask a question would be left in normal mode with it
      if item then vim.schedule(function() on_pick(item) end) end
    end,
  }))
end

---@param repo user.git.Repository
function M.push(repo)
  confirmed("Are you sure you want to push your changes?", function() require("user.git").push(repo) end)
end

---@param repo user.git.Repository
function M.pull(repo)
  confirmed("Run a git pull?", function() require("user.git").pull(repo) end)
end

---@param repo user.git.Repository
function M.undo_last_commit(repo)
  confirmed("Undo the last commit? Its changes stay staged.", function() require("user.git").undo_last_commit(repo) end)
end

---@param repo user.git.Repository
---@param path string a file or directory
---@param name string what the question calls it
function M.revert(repo, path, name)
  confirmed(("Are you sure you want to revert %s?"):format(name), function() require("user.git").revert(repo, path) end)
end

---@param repo user.git.Repository
function M.switch_branch(repo)
  -- all: the branches of the remotes too, each of which `checkout` makes a local branch
  pick(repo, { source = "git_branches", all = true, title = "Switch branch" }, function(item)
    local ref = item.branch or item.commit
    if ref then require("user.git").checkout(repo, ref) end
  end)
end

---@param repo user.git.Repository
function M.new_branch(repo)
  vim.ui.input({ prompt = "New branch: " }, function(name)
    if name and name ~= "" then require("user.git").create_branch(repo, name) end
  end)
end

---@param repo user.git.Repository
function M.delete_branch(repo)
  local others = {
    source = "git_branches",
    title = "Delete a branch",
    -- git deletes no branch that is checked out
    transform = function(item) return not item.current end,
  }
  pick(repo, others, function(item)
    if not item.branch then return end
    local git = require "user.git"
    local lost = git.commits_only_in(repo, item.branch)
    local question = ("Delete branch %s?"):format(item.branch)
    if lost > 0 then
      local commits = lost == 1 and "1 commit" or (lost .. " commits")
      question = ("%s It has %s the current branch does not."):format(question, commits)
    end
    confirmed(question, function() git.delete_branch(repo, item.branch) end)
  end)
end

---@param repo user.git.Repository
function M.stash(repo)
  vim.ui.input({ prompt = "Stash message (optional): " }, function(message)
    if message then require("user.git").stash(repo, message) end
  end)
end

---@param repo user.git.Repository
function M.pop_stash(repo)
  pick(
    repo,
    { source = "git_stash", title = "Apply a stash" },
    function(item) require("user.git").pop_stash(repo, item.stash) end
  )
end

---@param repo user.git.Repository
function M.drop_stash(repo)
  pick(repo, { source = "git_stash", title = "Drop a stash" }, function(item)
    confirmed(
      ("Drop %s without applying it?"):format(item.stash),
      function() require("user.git").drop_stash(repo, item.stash) end
    )
  end)
end

return M
