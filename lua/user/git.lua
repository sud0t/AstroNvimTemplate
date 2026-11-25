-- The Git commands that change a repository, run from the file tree (plugins/neo-tree.lua, user/git_prompts.lua).
-- All but `ignore` run in the background and report in a notification. Committing is in user/git_commit.lua.
local M = {}

---@class user.git.Repository
---@field dir string a directory in the repository
---@field on_change? fun() called when a command has ended, as the repository may have changed

-- The first argument of a command that is given paths: they are the names of files, not patterns. Not for every
-- command: under it `stash --include-untracked` leaves untracked files behind and `check-ignore` refuses to run.
M.LITERAL_PATHS = "--literal-pathspecs"

-- Over HTTPS git asks for a password on the terminal, which is Neovim's screen here: it fails instead, and says so.
local ENV = { GIT_TERMINAL_PROMPT = "0" }

---@class user.git.Report
---@field title string the title of the notification
---@field done? string what to say when git succeeds and says nothing itself; nothing is said without it
---@field summary? string what to say when git succeeds, in place of what git says

---@param repo user.git.Repository
---@param args string[]
---@param report user.git.Report
local function run(repo, args, report)
  vim.system(
    vim.list_extend({ "git" }, args),
    { cwd = repo.dir, env = ENV, text = true },
    vim.schedule_wrap(function(result)
      local output = vim.trim((result.stderr or "") .. (result.stdout or ""))
      if result.code ~= 0 then
        local problem = output ~= "" and output or ("git exited with code " .. result.code)
        vim.notify(problem, vim.log.levels.ERROR, { title = report.title })
      else
        local message = report.summary or (output ~= "" and output) or report.done
        if message then vim.notify(message, vim.log.levels.INFO, { title = report.title }) end
      end
      -- after a failure as well: a pull or a stash that stops at a conflict has changed files
      if repo.on_change then repo.on_change() end
    end)
  )
end

--- Pushes the current branch. A branch without an upstream gets the branch of its name on the default remote as
--- one, as `git push --set-upstream` gives it.
---@param repo user.git.Repository
function M.push(repo) run(repo, { "-c", "push.autoSetupRemote=true", "push" }, { title = "git push" }) end

--- Pulls the current branch. A merge it has to make gets git's own message: there is no editor to write one in.
---@param repo user.git.Repository
function M.pull(repo) run(repo, { "pull", "--no-edit" }, { title = "git pull" }) end

--- Fetches from the default remote, and forgets its branches that are gone there.
---@param repo user.git.Repository
function M.fetch(repo) run(repo, { "fetch", "--prune" }, { title = "git fetch", done = "Nothing new" }) end

--- Stashes all changes, those in untracked files as well: the work tree is left as the last commit has it.
---@param repo user.git.Repository
---@param message? string
function M.stash(repo, message)
  local args = { "stash", "push", "--include-untracked" }
  if message and message ~= "" then vim.list_extend(args, { "--message", message }) end
  run(repo, args, { title = "git stash" })
end

--- Applies a stash and drops it from the list. Git keeps it when it cannot apply all of it, and says so. What git
--- says of a stash it could apply is the whole of `git status`, which reads as if something went wrong.
---@param repo user.git.Repository
---@param stash string the stash as git names it, like stash@{0}
function M.pop_stash(repo, stash)
  run(
    repo,
    { "stash", "pop", stash },
    { title = "git stash pop", summary = ("Applied %s and dropped it"):format(stash) }
  )
end

--- Drops a stash from the list without applying it: its changes are lost.
---@param repo user.git.Repository
---@param stash string the stash as git names it, like stash@{0}
function M.drop_stash(repo, stash) run(repo, { "stash", "drop", stash }, { title = "git stash drop" }) end

---@param repo user.git.Repository
---@param branch string
---@return boolean
local function has_branch(repo, branch)
  local cmd = { "git", "show-ref", "--verify", "--quiet", "refs/heads/" .. branch }
  return vim.system(cmd, { cwd = repo.dir }):wait().code == 0
end

--- Checks out a branch or a commit. A branch of a remote, named as `git branch --all` names it, becomes a local
--- branch that follows it; the local branch of its name is checked out when the repository has one already.
---@param repo user.git.Repository
---@param ref string
function M.checkout(repo, ref)
  local branch = ref:match "^remotes/[^/]+/(.+)$"
  local args = { "checkout", ref }
  if branch then args = has_branch(repo, branch) and { "checkout", branch } or { "checkout", "-b", branch, ref } end
  run(repo, args, { title = "git checkout" })
end

--- Takes the last commit back. What it changed stays, staged.
---@param repo user.git.Repository
function M.undo_last_commit(repo)
  run(
    repo,
    { "reset", "--soft", "HEAD~1" },
    { title = "git reset", done = "The last commit is undone: its changes are staged" }
  )
end

--- Makes a branch at the current commit and checks it out.
---@param repo user.git.Repository
---@param name string
function M.create_branch(repo, name) run(repo, { "checkout", "-b", name }, { title = "git checkout" }) end

--- How many commits `branch` has that the current branch does not: what deleting it can lose.
---@param repo user.git.Repository
---@param branch string
---@return integer
function M.commits_only_in(repo, branch)
  local cmd = { "git", "rev-list", "--count", "HEAD.." .. branch }
  local counted = vim.system(cmd, { cwd = repo.dir, text = true }):wait()
  assert(counted.code == 0, counted.stderr)
  return assert(tonumber(vim.trim(counted.stdout)), "git rev-list --count gave no number")
end

--- Deletes a branch, also when no other branch has its commits: ask first, with `commits_only_in`.
---@param repo user.git.Repository
---@param branch string
function M.delete_branch(repo, branch) run(repo, { "branch", "--delete", "--force", branch }, { title = "git branch" }) end

---@param repo user.git.Repository
function M.unstage_all(repo) run(repo, { "reset", "--quiet" }, { title = "git reset" }) end

--- Puts a file or directory back as the last commit has it: its changes are lost, the staged ones as well.
---@param repo user.git.Repository
---@param path string
function M.revert(repo, path) run(repo, { M.LITERAL_PATHS, "checkout", "HEAD", "--", path }, { title = "git checkout" }) end

--- Adds a file or directory to the .gitignore at the top of the repository, as a line that names it alone.
---@param repo user.git.Repository
---@param path string
function M.ignore(repo, path)
  local function git(args) return vim.system(vim.list_extend({ "git" }, args), { cwd = repo.dir, text = true }):wait() end
  local function say(message, level) vim.notify(message, level, { title = ".gitignore" }) end
  local name = vim.fs.basename(path)

  local top = git { "rev-parse", "--show-toplevel" }
  if top.code ~= 0 then return say(vim.trim(top.stderr), vim.log.levels.ERROR) end
  if git({ M.LITERAL_PATHS, "ls-files", "--error-unmatch", "--", path }).code == 0 then
    return say(name .. " is in the repository: ignoring it would change nothing", vim.log.levels.WARN)
  end
  if git({ "check-ignore", "--quiet", "--", path }).code == 0 then
    return say(name .. " is ignored already", vim.log.levels.INFO)
  end

  local root = vim.trim(top.stdout)
  -- git names the top of the repository by its real path, which the path asked about need not be
  local inside = vim.fs.relpath(root, vim.uv.fs_realpath(path) or path)
  if not inside then return say(name .. " is not in the repository " .. root, vim.log.levels.ERROR) end
  if inside == "." then return say("The top of the repository cannot be ignored", vim.log.levels.WARN) end

  -- the path as a pattern for itself: from the top (the first /), and with what a pattern reads as more than a
  -- character escaped
  local line = "/" .. inside:gsub("[\\*?%[]", "\\%0"):gsub(" $", "\\ ")
  if vim.fn.isdirectory(path) == 1 then line = line .. "/" end
  local file = root .. "/.gitignore"
  local lines = vim.fn.filereadable(file) == 1 and vim.fn.readfile(file) or {}
  lines[#lines + 1] = line
  vim.fn.writefile(lines, file)
  say("Added " .. line, vim.log.levels.INFO)
  if repo.on_change then repo.on_change() end
end

return M
