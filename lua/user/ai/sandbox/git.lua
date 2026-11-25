-- What git takes for a repository, and where its configuration says the hooks are: read from the
-- files, without running git.
local M = {}

local uv = vim.uv

local Paths = require "user.ai.sandbox.paths"

local resolve = Paths.resolve

-- the directories git makes in a repository's own directory, and the three it knows one by
local git_internal = {}
for _, name in ipairs {
  "head",
  "branches",
  "hooks",
  "info",
  "lfs",
  "logs",
  "modules",
  "objects",
  "rebase-apply",
  "rebase-merge",
  "refs",
  "remotes",
  "rr-cache",
  "sequencer",
  "worktrees",
} do
  git_internal[name] = true
end

--- The bare repository (`name.git` by custom) whose own files `path` (absolute) is among, decided by what git
--- looks for (HEAD, with objects and refs or a `commondir`), not by the name. Another directory in it is a
--- work tree and is not refused. A path that would itself complete a repository counts, so the file tools
--- cannot build one around a `config` they wrote earlier (`git_file` is the other half).
local function git_dir(path)
  local parts = vim.split(path, "/", { plain = true })
  local dir = ""
  for i = 2, #parts - 1 do
    dir = dir .. "/" .. parts[i]
    local child = parts[i + 1]:lower()
    local function has(name) return child == name:lower() or uv.fs_lstat(dir .. "/" .. name) ~= nil end
    local is_repository = has "HEAD" and ((has "objects" and has "refs") or has "commondir")
    if is_repository and (i + 1 == #parts or git_internal[child]) then return dir end
  end
end

--- The name of `path` when it is one git knows a repository's directory by, in any directory: without a HEAD
--- (or a `commondir`/`gitdir` that points to one elsewhere) there is no repository for git to find, so the
--- file tools cannot make one piece by piece, whatever the order.
local function git_file(path)
  local name = vim.fs.basename(path):lower()
  return (name == "head" or name == "commondir" or name == "gitdir") and name or nil
end

--- What the git configuration file `path` says about hooks, itself and in the files it includes (also those
--- it includes on a condition: which of them holds is git's to say), added to `into`: every core.hooksPath
--- (`into.hooks`) and every file that is one of them (`into.files`, each one once, also one that is not there
--- yet: it is read once it is). The files are read as text: asking git would run what those same files name.
local function read_git_config(path, into, depth)
  -- (the same file by another way to it is the same file, as long as what it includes is looked for from
  -- the same directory: git reads a relative include from where the file was named)
  local dir = vim.fs.dirname(path)
  local known = (uv.fs_realpath(path) or path) .. "\0" .. (uv.fs_realpath(dir) or dir)
  if into.read[known] then return end
  into.read[known] = true
  into.files[#into.files + 1] = path
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then return end
  local at = 1
  --- The value that starts with `text` as git reads it: quotes taken off wherever they are, `\t` and its
  --- like, a comment outside quotes left out and the blanks before it too. It goes on in the next line when
  --- a backslash ends this one (in a value: a comment ends with its line).
  local function value_of(text)
    local value, quoted, keep = {}, false, 0
    while true do
      local pos, goes_on = 1, false
      while pos <= #text do
        local char = text:sub(pos, pos)
        if char == "\\" then
          pos = pos + 1
          local escaped = text:sub(pos, pos)
          if escaped == "" then
            goes_on, keep = true, #value
          else
            value[#value + 1] = ({ t = "\t", n = "\n", b = "\b" })[escaped] or escaped
            keep = #value
          end
        elseif char == '"' then
          quoted, keep = not quoted, #value
        elseif (char == "#" or char == ";") and not quoted then
          break
        elseif quoted or not char:find "%s" then
          value[#value + 1] = char
          keep = #value
        elseif #value > 0 then
          value[#value + 1] = char
        end
        pos = pos + 1
      end
      if not goes_on or not lines[at] then break end
      text, at = lines[at], at + 1
    end
    return table.concat(value, "", 1, keep)
  end
  local section = ""
  while at <= #lines do
    local line = lines[at] -- (readfile() has taken the CR of a CR-LF line end off)
    at = at + 1
    -- (a setting can follow its section on the same line)
    local name, rest = line:match "^%s*%[%s*([%w.-]+)[^%]]*%](.*)$"
    if name then
      section, line = name:lower(), rest
    end
    local key, text = line:match "^%s*(%a[%w-]*)%s*=%s*(.*)$"
    local value = text and value_of(text)
    key = key and key:lower()
    if value and value ~= "" then
      if section == "core" and key == "hookspath" then
        into.hooks[#into.hooks + 1] = value
      elseif (section == "include" or section == "includeif") and key == "path" and depth < 10 then
        local file = vim.fs.normalize(value)
        if not file:find "^/" then file = vim.fs.joinpath(vim.fs.dirname(path), file) end
        read_git_config(vim.fs.normalize(file), into, depth + 1)
      end
    end
  end
end

--- The first line of the file `path`, trimmed, or nil.
local function first_line(path)
  local ok, lines = pcall(vim.fn.readfile, path, "", 1)
  local line = ok and vim.trim(lines[1] or "") or ""
  return line ~= "" and line or nil
end

--- The directories the repository with the `.git` at `dot_git` (nil: none) keeps its hooks in, when a
--- configuration names one (core.hooksPath: the repository's own files, yours, the system's, and what they
--- include) and it is not the usual .git/hooks: what is in them runs on `git commit`. Where .git is a file (a
--- linked work tree, a submodule) the configuration is in the directory it names and in that one's
--- `commondir`. All of them count, not only the one that wins: which that is depends on conditions git
--- checks. `top`: the directory a relative one is read from when there is no repository.
--- Also returns the configuration files that those include (resolved): they are configuration like the rest.
local function hooks_dirs(dot_git, top)
  local function from(dir, path) return vim.fs.normalize(path:find "^/" and path or vim.fs.joinpath(dir, path)) end
  local git, files = dot_git, {}
  local stat = dot_git and uv.fs_stat(dot_git)
  if stat and stat.type == "file" then
    local named = (first_line(dot_git) or ""):match "^gitdir:%s*(.+)$"
    git = named and from(vim.fs.dirname(dot_git), named) or nil
  end
  if git then
    local common = first_line(git .. "/commondir")
    vim.list_extend(files, { git .. "/config.worktree", git .. "/config" })
    if common then files[#files + 1] = from(git, common) .. "/config" end
  end
  vim.list_extend(
    files,
    { "~/.gitconfig", (vim.env.XDG_CONFIG_HOME or "~/.config") .. "/git/config", "/etc/gitconfig" }
  )
  local into, dirs, included = { hooks = {}, files = {}, read = {} }, {}, {}
  local own = {}
  for _, file in ipairs(files) do
    file = vim.fs.normalize(file)
    own[file] = true
    read_git_config(file, into, 1)
  end
  for _, path in ipairs(into.hooks) do
    path = vim.fs.normalize(path)
    -- (git reads a relative one from the top of the work tree)
    if not path:find "^/" then path = vim.fs.joinpath(dot_git and vim.fs.dirname(dot_git) or top, path) end
    dirs[#dirs + 1] = resolve(path)
  end
  for _, file in ipairs(into.files) do
    if not own[file] then included[#included + 1] = resolve(file) end
  end
  return dirs, included
end

M.git_dir = git_dir
M.git_file = git_file
M.hooks_dirs = hooks_dirs

return M
