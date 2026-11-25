-- The file tree's git commands inside the whole configuration (lua/user/git.lua).
--   nvim --headless -c 'luafile ~/.config/nvim/tests/git.lua' -c 'qa!' < /dev/null
-- prints "ok: N checks", or what failed and exits with 1. Run it after changing that file and after an update of
-- git: the commands rely on what git does with a branch that has no upstream, and on how it words its refusals.

local failures, count = {}, 0
local function ok(name, cond, detail)
  count = count + 1
  if not cond then failures[#failures + 1] = name .. (detail ~= nil and ("\n      " .. tostring(detail)) or "") end
end

local function wait_for(what, cond) assert(vim.wait(10000, cond, 20), "timed out waiting for " .. what) end

local base = vim.fn.tempname()
-- a work tree, the remote it pushes to, and the work tree of someone else who pushes there
local dir, remote, other = base .. "/work", base .. "/remote.git", base .. "/other"

local function git_in(cwd, ...)
  local result = vim.system({ "git", ... }, { cwd = cwd, text = true }):wait()
  assert(result.code == 0, ("git %s failed: %s"):format(table.concat({ ... }, " "), result.stderr or ""))
  return result.stdout
end
local function git(...) return git_in(dir, ...) end
local function status() return git("status", "--porcelain") end
local function write(name, text) vim.fn.writefile({ text or name }, dir .. "/" .. name) end
local function commit_in(cwd, name)
  vim.fn.writefile({ name }, cwd .. "/" .. name)
  git_in(cwd, "add", name)
  git_in(cwd, "commit", "-q", "-m", "add " .. name)
end
local function identify(cwd)
  git_in(cwd, "config", "user.name", "test")
  git_in(cwd, "config", "user.email", "test@localhost")
end

local notes = {}
local notify = vim.notify
---@diagnostic disable-next-line: duplicate-set-field
vim.notify = function(message, level, opts)
  notes[#notes + 1] = { message = message, level = level, title = (opts or {}).title }
end

local changes = 0
local repo = { dir = dir, on_change = function() changes = changes + 1 end }
--- Runs a command of the module that works in the background, waits for it to end and returns its notifications.
local function run(command, ...)
  notes = {}
  local before = changes
  require("user.git")[command](repo, ...)
  wait_for(command, function() return changes > before end)
  return notes
end
local function ignore(name)
  notes = {}
  require("user.git").ignore(repo, dir .. "/" .. name)
  return notes
end
local function ignored() return vim.fn.readfile(dir .. "/.gitignore") end

local ERROR, WARN, INFO = vim.log.levels.ERROR, vim.log.levels.WARN, vim.log.levels.INFO

local run_ok, err = xpcall(function()
  vim.fn.mkdir(dir, "p")
  git("init", "-q", "-b", "main")
  identify(dir)
  commit_in(dir, "a.txt")
  git_in(base, "init", "-q", "--bare", "-b", "main", remote)
  git("remote", "add", "origin", remote)
  git("push", "-q", "-u", "origin", "main")
  git_in(base, "clone", "-q", remote, other)
  identify(other)

  commit_in(dir, "b.txt")
  local pushed = run "push"
  ok("push pushes the branch", git_in(remote, "log", "-1", "--format=%s", "main") == "add b.txt\n")
  ok("and reports git's output", pushed[1].title == "git push" and pushed[1].level == INFO, vim.inspect(pushed))

  git("checkout", "-q", "-b", "topic")
  commit_in(dir, "c.txt")
  pushed = run "push"
  ok(
    "push gives a new branch its upstream",
    pushed[1].level == INFO
      and git_in(remote, "log", "-1", "--format=%s", "topic") == "add c.txt\n"
      and git("rev-parse", "--abbrev-ref", "topic@{upstream}") == "origin/topic\n",
    vim.inspect(pushed)
  )

  local switched = run("checkout", "main")
  ok(
    "checkout switches to a branch",
    git("branch", "--show-current") == "main\n" and switched[1].title == "git checkout",
    vim.inspect(switched)
  )

  git_in(other, "pull", "-q")
  commit_in(other, "theirs.txt")
  git_in(other, "push", "-q")
  local pulled = run "pull"
  ok(
    "pull brings in what was pushed",
    vim.fn.filereadable(dir .. "/theirs.txt") == 1 and pulled[1].title == "git pull" and pulled[1].level == INFO,
    vim.inspect(pulled)
  )

  git_in(other, "checkout", "-q", "-b", "feature")
  commit_in(other, "feature.txt")
  git_in(other, "push", "-q", "-u", "origin", "feature")
  local fetched = run "fetch"
  ok(
    "fetch learns of a new branch",
    fetched[1].level == INFO and git("branch", "--remotes"):find("origin/feature", 1, true),
    vim.inspect(fetched)
  )
  fetched = run "fetch"
  ok("fetch says when there was nothing", fetched[1].message == "Nothing new", vim.inspect(fetched))
  run("checkout", "remotes/origin/feature")
  ok(
    "checkout of a remote's branch makes a local one that follows it",
    git("branch", "--show-current") == "feature\n"
      and git("rev-parse", "--abbrev-ref", "feature@{upstream}") == "origin/feature\n"
  )
  run("checkout", "main")

  local made = run("create_branch", "scratch")
  ok(
    "create_branch makes a branch and checks it out",
    git("branch", "--show-current") == "scratch\n" and made[1].title == "git checkout",
    vim.inspect(made)
  )
  commit_in(dir, "scratch.txt")
  git("branch", "same")
  run("checkout", "main")
  local user_git = require "user.git"
  ok(
    "commits_only_in counts what deleting a branch can lose",
    user_git.commits_only_in(repo, "scratch") == 1 and user_git.commits_only_in(repo, "main") == 0,
    user_git.commits_only_in(repo, "scratch")
  )
  local deleted = run("delete_branch", "scratch")
  ok(
    "delete_branch deletes a branch that is not merged",
    git("branch", "--list", "scratch") == "" and deleted[1].level == INFO and deleted[1].title == "git branch",
    vim.inspect(deleted)
  )
  local current = run("delete_branch", "main")
  ok(
    "and says why git keeps the branch that is checked out",
    current[1].level == ERROR and git("branch", "--show-current") == "main\n",
    vim.inspect(current)
  )
  git("branch", "-q", "-D", "same")

  write("a.txt", "changed")
  write "new.txt"
  local stashed = run("stash", "work in progress")
  ok("stash puts all changes away, untracked files as well", status() == "", status())
  ok(
    "under the message given",
    git("stash", "list"):find("work in progress", 1, true) and stashed[1].title == "git stash",
    vim.inspect(stashed)
  )
  local popped = run("pop_stash", "stash@{0}")
  ok("pop_stash brings them back", status() == " M a.txt\n?? new.txt\n", status())
  ok("and drops the stash", git("stash", "list") == "", git("stash", "list"))
  ok(
    "in one line, not in git's status",
    #popped == 1 and popped[1].level == INFO and popped[1].message == "Applied stash@{0} and dropped it",
    vim.inspect(popped)
  )

  run "stash"
  write("a.txt", "changed otherwise")
  git("commit", "-q", "-am", "in the way")
  local kept = run("pop_stash", "stash@{0}")
  ok(
    "pop_stash keeps a stash that does not apply, and says why",
    kept[1].level == ERROR and kept[1].message:find("CONFLICT", 1, true) and git("stash", "list") ~= "",
    vim.inspect(kept)
  )
  git("checkout", "-q", "HEAD", "--", "a.txt")
  vim.fn.delete(dir .. "/new.txt")
  local dropped = run("drop_stash", "stash@{0}")
  ok(
    "drop_stash drops a stash without applying it",
    git("stash", "list") == "" and status() == "" and dropped[1].title == "git stash drop",
    status() .. vim.inspect(dropped)
  )
  write("a.txt", "changed")
  write "new.txt"

  commit_in(dir, "undone.txt")
  local undone = run "undo_last_commit"
  ok(
    "undo_last_commit takes the commit back and keeps its changes staged",
    git("log", "-1", "--format=%s") ~= "add undone.txt\n" and status():find("A  undone.txt", 1, true),
    status()
  )
  ok("and says so", undone[1].level == INFO and undone[1].title == "git reset", vim.inspect(undone))
  git("rm", "-q", "--cached", "undone.txt")
  vim.fn.delete(dir .. "/undone.txt")

  git("add", ".")
  local quiet = run "unstage_all"
  ok("unstage_all empties the index", status() == " M a.txt\n?? new.txt\n", status())
  ok("without a notification", #quiet == 0, vim.inspect(quiet))

  quiet = run("revert", dir .. "/a.txt")
  ok("revert puts a file back", status() == "?? new.txt\n" and #quiet == 0, status())
  local refused = run("revert", dir .. "/new.txt")
  ok(
    "revert says why git refuses",
    refused[1].level == ERROR and refused[1].message:find "did not match" and status() == "?? new.txt\n",
    vim.inspect(refused)
  )

  local first = { dir = base .. "/first", on_change = repo.on_change }
  vim.fn.mkdir(first.dir)
  git_in(first.dir, "init", "-q", "-b", "main")
  identify(first.dir)
  commit_in(first.dir, "only.txt")
  notes = {}
  local before = changes
  require("user.git").undo_last_commit(first)
  wait_for("the refusal", function() return changes > before end)
  ok(
    "undo_last_commit says why git refuses the first commit",
    notes[1].level == ERROR and git_in(first.dir, "log", "--format=%s") == "add only.txt\n",
    vim.inspect(notes)
  )

  before = changes
  local added = ignore "new.txt"
  ok("ignore adds the file to .gitignore", vim.deep_equal(ignored(), { "/new.txt" }), vim.inspect(ignored()))
  ok("says so", added[1].message == "Added /new.txt" and added[1].level == INFO, vim.inspect(added))
  ok("and tells the caller", changes == before + 1)
  local again = ignore "new.txt"
  ok("a file that is ignored is not added again", #ignored() == 1 and again[1].level == INFO, vim.inspect(again))
  local tracked = ignore "a.txt"
  ok("nor is a file of the repository", #ignored() == 1 and tracked[1].level == WARN, vim.inspect(tracked))
  vim.fn.mkdir(dir .. "/build")
  write "build/out.txt"
  ignore "build"
  ok("a directory is ignored as one", ignored()[2] == "/build/", vim.inspect(ignored()))
  write "we[ird]*.txt"
  ignore "we[ird]*.txt"
  ok("a name is not read as a pattern", ignored()[3] == [[/we\[ird]\*.txt]], vim.inspect(ignored()))
  ok("git ignores all three", status() == "?? .gitignore\n", status())

  ok("nothing reported an error", vim.v.errmsg == "", vim.v.errmsg)
end, debug.traceback)

vim.notify = notify
vim.fn.delete(base, "rf")
if not run_ok then failures[#failures + 1] = "the test itself failed:\n" .. tostring(err) end
if #failures > 0 then
  io.stderr:write(("%d of %d checks failed:\n"):format(#failures, count))
  for _, failure in ipairs(failures) do
    io.stderr:write("  - " .. failure .. "\n")
  end
  vim.cmd "cq"
end
print(("ok: %d checks"):format(count))
