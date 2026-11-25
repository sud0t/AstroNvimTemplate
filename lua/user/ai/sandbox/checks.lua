-- Why a file tool, a search, a command or a web address may not be used right now, and what a
-- command runs as (under srt, without the variables that are named like secrets).
local M = {}

local uv = vim.uv

local State = require "user.ai.sandbox.state"
local Paths = require "user.ai.sandbox.paths"
local Names = require "user.ai.sandbox.names"
local Git = require "user.ai.sandbox.git"

local locks = State.locks
local tell = State.tell
local settings = State.settings
local srt_path = State.srt_path
local resolve = Paths.resolve
local within = Paths.within
local entry_path = Paths.entry_path
local is_pattern = Paths.is_pattern
local list = Paths.list
local covered = Paths.covered
local canonical = Paths.canonical
local protected_name = Names.protected_name
local secret_name = Names.secret_name
local git_dir = Git.git_dir
local git_file = Git.git_file
local hooks_dirs = Git.hooks_dirs

--- The directories that define the editor, the sandbox and what agents are told (resolved): what is in
--- them is loaded as code or as instructions the next time Neovim, Claude Code or srt starts.
local function core_roots()
  local roots = {}
  local function add(path) roots[#roots + 1] = resolve(path) end
  for _, what in ipairs { "config", "data", "state", "cache" } do
    add(vim.fn.stdpath(what))
  end
  for _, path in ipairs { "~/.claude", "~/.claude.json", "~/.config/codecompanion", "~/.agents" } do
    add(path)
  end
  local srt = srt_path()
  if srt then
    add(vim.fs.dirname(srt)) -- (a directory on $PATH)
    local real = uv.fs_realpath(srt)
    -- the runtime itself: all of node_modules when it is installed in one (its dependencies are its code)
    if real then add(real:match "^(.*/node_modules)/" or vim.fs.dirname(real)) end
  end
  return roots
end

--- Why `root` is too wide a directory for tools that write, search or run commands, or nil when it is not.
local function too_broad(root, roots)
  local what
  local home = resolve(uv.os_homedir())
  if within(home, root) then
    what = root == home and "is your home directory" or "contains your home directory"
  else
    for _, core in ipairs(roots) do
      if core ~= root and within(core, root) then
        what = "contains " .. core
        break
      end
    end
  end
  if not what then return nil end
  return (
    "Neovim is running in %s, which %s: in a directory that wide the AI's tools do not read, write, search or "
    .. "run commands. The user has to `:cd` into the project first."
  ):format(root, what)
end

--- The directory Neovim is in (resolved), or nil and why there is none.
---@return string|nil root, string|nil why_not
local function project_root()
  local cwd = uv.cwd()
  if not cwd then
    return nil, "the directory Neovim is running in no longer exists. The user has to `:cd` into the project first."
  end
  return resolve(cwd)
end

--- Why a file tool may not use `target` (resolved; `lexical`: as it was written), or nil when it may.
--- `keep_link`: the tool acts on a link itself.
local function refusal(target, lexical, shown, write, s, keep_link)
  local root, gone = project_root()
  if not root then return gone end
  if not within(target, root) then
    return ("`%s` is outside the project directory %s; the AI's file tools only work inside it"):format(shown, root)
  end
  local fs = s.filesystem
  for _, entries in ipairs(write and { fs.denyRead, fs.denyWrite } or { fs.denyRead }) do
    for _, entry in ipairs(list(entries)) do
      if covered(target, entry) then
        return ("`%s` is protected (%s, in %s)"):format(shown, entry_path(entry), State.settings_file)
      end
    end
  end
  local roots = core_roots()
  local broad = too_broad(root, roots)
  if broad then return broad end
  -- (only what is below the project counts: it may itself be in a directory with such a name)
  local function below(path) return within(path, root) and path:sub(#root + 2) or path end
  local named = secret_name(below(target)) or secret_name(below(lexical))
  if named then
    return (
      "`%s`: files named `%s` usually hold secrets (keys, tokens, passwords), so the AI's file tools neither "
      .. "read nor write them. Ask the user for the part that is needed."
    ):format(shown, named)
  end
  if not write then return nil end
  for _, core in ipairs(roots) do
    if within(target, core) then
      return ("`%s` is in %s, which belongs to the editor and its AI tools: they cannot change it"):format(shown, core)
    end
  end
  local name = protected_name(target, root) or protected_name(lexical, root)
  if name then
    return (
      "`%s`: `%s` is run or obeyed by other programs (git, shells, editors, AI agents), so the AI's file tools "
      .. "cannot change it. Tell the user what to change there instead."
    ):format(shown, name)
  end
  local marker = git_file(target) or git_file(lexical)
  if marker then
    return (
      "`%s`: a file named `%s` is what git knows a repository by, and git runs what a repository's "
      .. "configuration names, so the AI's file tools cannot write one. Tell the user what to change instead."
    ):format(shown, marker)
  end
  local git = git_dir(target) or git_dir(lexical)
  if git then
    return (
      "`%s` is one of git's own files in %s, which is a git repository or would be one with it (git knows one "
      .. "by HEAD, objects and refs), and git runs what a repository's configuration and hooks name. The AI's "
      .. "file tools cannot write there. Tell the user what to change instead."
    ):format(shown, git)
  end
  -- (the repository the project is in, and the one the file is in when that is another: one inside it)
  local seen = {}
  for _, start in ipairs { root, vim.fs.dirname(target) } do
    local dot_git = vim.fs.find(".git", { upward = true, path = start })[1]
    if not seen[dot_git or ""] then
      seen[dot_git or ""] = true
      local dirs, included = hooks_dirs(dot_git, root)
      for _, file in ipairs(included) do
        if target == file or lexical == file then
          return (
            "`%s` is a file that a git configuration of this repository includes: it is configuration itself, "
            .. "and git runs what a configuration names. Tell the user what to change there instead."
          ):format(shown)
        end
      end
      for _, hooks in ipairs(dirs) do
        if within(target, hooks) or within(lexical, hooks) then
          return (
            "`%s` is in %s, where this repository keeps its git hooks (core.hooksPath): git runs them, so the "
            .. "AI's file tools cannot change them. Tell the user what to change there instead."
          ):format(shown, hooks)
        end
      end
    end
  end
  local stat = not keep_link and uv.fs_stat(target)
  if stat and stat.type == "file" and stat.nlink > 1 then
    return (
      "`%s` has a second name (a hard link, as some package managers and backups make them): writing it would "
      .. "change the file under that other name too, and only this one was checked"
    ):format(shown)
  end
end

--- Why a file tool may not use `path`, or nil and the path to use in its place (absolute, links resolved).
---@param path string
---@param write boolean|nil
---@param keep_link boolean|nil the tool acts on a symbolic link itself (delete)
---@return string|nil why, string|nil resolved
function M.check_path(path, write, keep_link)
  local s, why = settings()
  if not s then return why end
  local root, gone = project_root()
  if not root then return gone end -- (a path cannot be made absolute without it)
  local target, lexical = canonical(path, keep_link)
  if not target then return lexical end
  why = refusal(target, lexical, path, write == true, s, keep_link)
  if why then return why end
  return nil, target
end

--- Why the search tools cannot run (they list and read whatever is below the project directory, and neither
--- knows srt-ai.json), or nil when they can.
local function search_problem()
  local s, why = settings()
  if not s then return why end
  local root, gone = project_root()
  if not root then return gone end
  local broad = too_broad(root, core_roots())
  if broad then return broad end
  for _, entry in ipairs(list(s.filesystem.denyRead)) do
    local path = entry_path(entry)
    local hidden
    if path and covered(root, path) then
      hidden = root
    elseif path and not is_pattern(path) then
      local real = resolve(path)
      if within(real, root) and uv.fs_lstat(real) then hidden = real end
    elseif path then
      for _, match in ipairs(vim.fn.glob(path, true, true)) do
        if within(resolve(match), root) then
          hidden = match
          break
        end
      end
    end
    if hidden then
      return ("a search of %s would also read %s, which is protected (%s, in %s). Read single files instead."):format(
        root,
        hidden,
        path,
        State.settings_file
      )
    end
  end
end

--- Why command tools cannot run sandboxed right now, or nil when they can. Asked when a command starts: the
--- directory srt writes in is the one Neovim is in at that moment.
local function command_problem()
  if locks.command then return locks.command end
  if not srt_path() then return "srt (the sandbox runtime) is not installed" end
  local s, why = settings()
  if not s then return why end
  local fs = s.filesystem
  local root, gone = project_root()
  if not root then return gone end
  local roots = core_roots()
  local broad = too_broad(root, roots)
  if broad then return broad end
  for _, entries in ipairs { fs.allowWrite, fs.denyWrite } do
    for _, entry in ipairs(list(entries)) do
      local path = entry_path(entry)
      -- (srt skips patterns in these two lists on Linux, without a word: the rule would only hold in here)
      if path and is_pattern(path) then
        return ("`%s` in %s is a pattern, and srt ignores patterns in allowWrite and denyWrite: list the paths"):format(
          path,
          State.settings_file
        )
      end
    end
  end
  for _, entry in ipairs(list(fs.allowWrite)) do
    local path = entry_path(entry)
    local wide = path and too_broad(resolve(path), roots)
    if wide then return ("allowWrite in %s has `%s`: %s"):format(State.settings_file, path, wide) end
  end
  -- Inside one of the editor's own directories it is srt that keeps a command from writing there, and only
  -- when denyWrite names the directory (or one above it): the literal entries have to match this machine.
  for _, core in ipairs(roots) do
    if within(root, core) then
      local denied = false
      for _, entry in ipairs(list(fs.denyWrite)) do
        local path = entry_path(entry)
        if path and within(core, resolve(path)) then denied = true end
      end
      if not denied then
        return ("Neovim is running inside %s, which denyWrite in %s does not list: add it there"):format(
          core,
          State.settings_file
        )
      end
    end
  end
end

--- Why a text search with the arguments `args` cannot run, or nil when it can: it would read a file that is
--- named like a secret, and what it answers says what is in there (a match or none, pattern by pattern).
--- ripgrep itself lists what the search would read (`--files`, with the call's own pattern): a pattern takes
--- in hidden files and the files git ignores, and only ripgrep knows what one matches. `opts`: the tool's.
local function secret_search(args, opts)
  if vim.fn.executable "rg" ~= 1 then return nil end -- (the tool says so itself)
  local pattern = args.include_pattern
  if pattern ~= nil and type(pattern) ~= "string" then return "`include_pattern` has to be text" end
  local cwd = vim.fn.getcwd()
  local cmd = { "rg", "--files" }
  if type(opts) == "table" and opts.respect_gitignore == false then cmd[#cmd + 1] = "--no-ignore" end
  if pattern and pattern ~= "" then vim.list_extend(cmd, { "--glob", pattern }) end
  cmd[#cmd + 1] = cwd
  local ran, res = pcall(function() return vim.system(cmd, { text = true }):wait(10000) end)
  if not ran or res.code > 1 or res.signal ~= 0 then
    local said = ran and (vim.trim(res.stderr or ""):match "^[^\n]*") or tostring(res)
    return ("the sandbox could not list the files this search would read (%s)"):format(
      said ~= "" and said or "that took longer than 10 seconds"
    )
  end
  local first, more = nil, 0
  for path in (res.stdout or ""):gmatch "[^\n]+" do
    -- (ripgrep writes every path with the directory it was given in front)
    local below = path:sub(1, #cwd + 1) == cwd .. "/" and path:sub(#cwd + 2) or path
    if secret_name(below) then
      if first then
        more = more + 1
      else
        first = below
      end
    end
  end
  if not first then return nil end
  return (
    "this search would read `%s`%s, and files named like that usually hold secrets: the search tools do not "
    .. "read them. Search with an `include_pattern` that leaves them out (for example `src/**` or `**/*.lua`)."
  ):format(first, more > 0 and (" and %d more"):format(more) or "")
end

--- Why the chat's commands would not run right now, or nil when they would. Never fails, and does not load
--- CodeCompanion (<Leader>AS shows it).
function M.command_problem()
  local ok, why = pcall(command_problem)
  if not ok then return "its check failed (" .. tostring(why) .. ")" end
  return why
end

--- The environment variables of this Neovim that are named like secrets (GITHUB_TOKEN, AWS_SECRET_ACCESS_KEY,
--- ...) or hold an address with a password in it: a command does not get them. srt-ai.json can only list
--- names one by one, and a command would otherwise read whatever a shell profile exports. Sorted.
local function secret_variables()
  local names = {}
  for name, value in pairs(vim.fn.environ()) do
    local upper = name:upper()
    local found = false
    -- these anywhere in the name...
    for _, piece in ipairs { "TOKEN", "SECRET", "PASSWORD", "PASSWD", "PASSPHRASE", "CREDENTIAL", "APIKEY" } do
      found = found or upper:find(piece, 1, true) ~= nil
    end
    -- ...and these as one of its words (SSH_AUTH_SOCK, but not GIT_AUTHOR_NAME or XDG_KEYBOARD)
    local words = vim.split(upper, "_", { plain = true, trimempty = true })
    for _, word in ipairs(words) do
      found = found or vim.list_contains({ "KEY", "KEYS", "PASS", "AUTH", "COOKIE", "PAT", "CREDS", "DSN" }, word)
    end
    -- (MYSQL_PWD is a password, PWD is the directory)
    found = found or (#words > 1 and vim.list_contains(words, "PWD"))
    -- the sessions of password managers
    found = found or upper == "BW_SESSION" or upper:find "^OP_SESSION_" ~= nil
    -- a value like scheme://user:password@host (DATABASE_URL)
    found = found or (type(value) == "string" and value:find "^%a[%w+.-]*://[^/%s@:]*:[^/%s@]+@" ~= nil)
    -- (GIT_CONFIG_KEY_<n> is the name of a git setting, and git stops when one of them is missing)
    if found and not name:find "^GIT_CONFIG_KEY_%d+$" then names[#names + 1] = name end
  end
  table.sort(names)
  return names
end

--- Neovim's temporary directory when srt-ai.json does not hide it from commands, else nil. CodeCompanion hands
--- curl a request's headers there, the API key among them (see `remove_request_headers`), and denyRead names
--- the directory as it is on this machine: a Neovim started with another $TMPDIR has it elsewhere.
function M.temp_exposed()
  local s = settings()
  local temp = resolve(vim.fs.dirname(vim.fn.tempname()))
  for _, entry in ipairs(list(s and s.filesystem.denyRead)) do
    if covered(temp, entry) then return nil end
  end
  return temp
end

--- CodeCompanion turns every command-line tool's command into `sh -c <command>` through
--- utils.os.build_shell_command: run it under srt instead, or not at all.
local function sandboxed_command(args)
  local cmd = type(args) == "table" and table.concat(args, " ") or args
  local why = M.command_problem()
  local read, temp = pcall(M.temp_exposed)
  if read and temp then
    tell(
      (
        "The chat's commands can read Neovim's temporary directory (%s), which API keys pass through on their way "
        .. "to a provider: add %s to denyRead in %s."
      ):format(temp, vim.fs.dirname(temp), State.settings_file)
    )
  end
  local hidden, env = secret_variables(), vim.fn.exepath "env"
  if not why and #hidden > 0 and env == "" then
    why = "`env` is not installed, which takes the secrets out of a command's environment"
  end
  if why then return { "sh", "-c", 'printf "%s\\n" "$1" >&2; exit 126', "sh", "Blocked by the sandbox: " .. why } end
  local run = {}
  if #hidden > 0 then
    run[1] = env
    for _, name in ipairs(hidden) do
      vim.list_extend(run, { "-u", name })
    end
  end
  return vim.list_extend(run, { srt_path(), "--settings", State.settings_file, "-c", cmd })
end

--- CodeCompanion hands curl a chat request's headers, the API key among them, in a file of Neovim's temporary
--- directory, and removes it only after a request that went well: otherwise the key stays there until Neovim
--- closes. This removes those that are at least `min_age` seconds old (the curl a file was written for has
--- long read it). curl's record of an answer's headers has the same ending and stays: CodeCompanion reads it
--- when the request ends (it begins with "HTTP/", or is still empty while the answer is awaited).
---@return integer removed
function M.remove_request_headers(min_age)
  local dir = vim.fs.dirname(vim.fn.tempname())
  local removed = 0
  for name, kind in vim.fs.dir(dir) do
    local path = dir .. "/" .. name
    local stat = kind == "file" and name:find "%.headers$" and uv.fs_stat(path)
    if stat and os.time() - stat.mtime.sec >= min_age then
      local read, lines = pcall(vim.fn.readfile, path, "", 1)
      local first = read and lines[1] or ""
      -- (a request's headers are lines of "Name: value")
      if first:find "^[%w_-]+:%s" and uv.fs_unlink(path) then removed = removed + 1 end
    end
  end
  return removed
end

--- Why the web tools do not go to `url`, or nil when they do: only to a web site by its name. A number, a
--- name without a dot or one that is local by its ending is this machine or its network (a router, a
--- service on localhost), which a page on the web has no business being.
local function address_problem(url)
  local scheme, rest = url:match "^%s*(%a[%w+.-]*)://(.*)$"
  if not scheme then return nil end -- (no address at all: the tool says so itself)
  -- (what is sent has to be what the question shows: a character outside ASCII can be one that does not
  -- show, and an address can say the same with %XX, which does)
  if url:find "[\128-\255]" then
    return "the address has characters outside ASCII, which can hide what is sent: write them percent-encoded"
  end
  if #url > 2000 then return ("the address is %d characters long: more than 2000 are not sent"):format(#url) end
  local host = rest:match("^[^/?#%s]*"):gsub("^.*@", ""):gsub(":%d*$", ""):gsub("%.+$", ""):lower()
  local by_name = host:find "^[%w-]+%.[%w.-]*%a[%w-]*$" ~= nil and not host:find "%.%." and not host:find "^0x"
  -- (programs do not agree on where the host ends when there is a backslash or a control character)
  if url:find "[\\%c]" then by_name = false end
  for _, ending in ipairs { "localhost", "local", "internal", "lan", "home", "arpa", "test", "invalid" } do
    if host == ending or vim.endswith(host, "." .. ending) then by_name = false end
  end
  scheme = scheme:lower()
  if (scheme == "http" or scheme == "https") and by_name then return nil end
  return (
    "`%s` is not the address of a web site by its name (http or https): the web tools are not given numeric "
    .. "or local addresses"
  ):format(url)
end

M.project_root = project_root
M.search_problem = search_problem
M.secret_search = secret_search
M.secret_variables = secret_variables
M.sandboxed_command = sandboxed_command
M.address_problem = address_problem
-- (`M.command_problem` never fails; `vet` in init.lua takes this one, whose error its caller reports)
M.raw_command_problem = command_problem

return M
