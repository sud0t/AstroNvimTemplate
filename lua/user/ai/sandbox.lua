-- Keeps the CodeCompanion chat's own tools (the tools the Ollama and API-key Claude chats use) away from
-- secrets and from everything that runs as code outside the sandbox. What a model does with its tools is
-- steered by what it reads (a project file, a web page, a tool's output), so every tool call is treated as
-- if an attacker had written its arguments. Two layers, with the rules in ~/.config/nvim/srt-ai.json:
--   * every shell command a tool runs (run_command) runs under srt, Anthropic's sandbox runtime (bubblewrap +
--     seccomp): no network, no D-Bus (so no keyring through `secret-tool`), no other Unix sockets (KeePassXC's
--     browser socket), the denyRead paths hidden, and writes only inside the directory Neovim runs in, minus
--     denyWrite;
--   * the tools that run inside Neovim are checked here, before they are approved and again right before they
--     run. Every tool has a class in `M.policy`; one that has none is refused, so a tool a CodeCompanion update
--     or an MCP server brings does nothing until it is classified. File tools get the one absolute path that
--     was checked (symbolic links resolved) in place of the path the model wrote. A tool the chat was not
--     given does not run because the model names it, and a chat is given tools by what you type: a tag
--     (@{name}, #{name}) inside a code block or in the selection a chat was opened with gives it nothing, and
--     any other one that is new to the chat only after a question (a file's path, a diagnostic or a diff that
--     a command put into the message, and text that was pasted, read as typed). A link in a message
--     attaches a file only when the file tools may read it, a page only after a question. The
--     web tools ask before every single call, also in a chat set to approve everything ("yolo") and after
--     "always accept", and the question shows all of what is about to be sent, characters that do not show on
--     a screen spelled out: a call can carry whatever the model has read.
-- On top of denyWrite the file tools never write:
--   * Neovim's own directories (configuration, plugins, state, cache), Claude Code's, the skill directories
--     and srt itself: whatever is loaded as code or as instructions the next time something starts;
--   * the names in `M.protected_names` anywhere in a project (.git, editor and agent settings and instruction
--     files, shell startup files, hook directories, the build settings a language server runs commands from),
--     the directories a git configuration names as core.hooksPath, and
--     git's own files in a repository without a .git (a bare one, also one the tools would be completing
--     themselves): git alone runs what its configuration names on every `git status`;
--   * a file that has a second name (a hard link): the other name was not checked;
-- they neither read nor write files that are named like secrets (`M.secret_names`: .env, private keys), and
-- a text search does not run when it would read one;
-- and nothing reads, writes, searches or runs commands while Neovim runs in the home directory or another
-- directory that contains those (`allowWrite: ["."]` would be every startup file there is, and the home
-- directory has more secrets than any list names).
-- Fails closed: without srt or srt-ai.json command tools refuse to run; when CodeCompanion no longer has or
-- calls the functions wrapped here, what they guard is switched off (plugins/codecompanion.lua then starts the
-- chat without tools). One exception: when the function that reads #{name} tags is gone, tags in code attach
-- buffers again, and a warning says so. `:Lazy reload codecompanion.nvim` loads its modules anew: `install` wraps them again.
-- srt-ai.json is read again on every check, so edits to it apply right away. So is the directory Neovim is in:
-- the project is where the focused window is (`:cd`, `:tcd` and `:lcd` all count), which is also where srt and
-- the tools themselves work.
-- Not covered:
--   * what an approved command does inside the project. srt keeps commands from .git/hooks and .git/config
--     only where a .git exists when the command starts: in a project without one a command can run `git init`
--     and set its configuration, and it can write the agent files, .nvim-ai.md (which then waits for your
--     approval) and build scripts. Look at what a command does before you approve it.
--   * a file that is swapped for a link between your accepting a diff and the write, or between the check of
--     a rules file and CodeCompanion reading it (both need a second process writing at that moment);
--   * a web address by name that resolves to this machine or network, or that redirects there (the program
--     that fetches a page follows redirects); the question shows the address the tool was given;
--   * what the editor's own tools do with a file a tool wrote, outside every sandbox: rust-analyzer builds and
--     runs build scripts and procedural macros (also those of a dependency that Cargo.toml names) when a file
--     is saved, and the JSON, TOML and XML language servers fetch the schema address a file names. A chat that
--     approves everything writes such files unseen: do not use that mode where a language server runs the
--     project's code;
--   * with the question about tags turned off (<Leader>AS, "Tags in a message"): text that you paste into a
--     message, or that a command of CodeCompanion puts there (a file's path, a diagnostic, a diff), outside
--     a code block or ending the one it is in: a tag in it (@{name}, #{name}) counts as typed;
--   * files that an instruction file pulls in (`@path` in CLAUDE.md), git configuration that comes from the
--     environment (GIT_CONFIG_*), and secrets in files that are not named like one.
-- The Claude Code chat (ACP) is not covered here: Claude Code reads, writes, fetches and runs commands itself,
-- under ~/.claude/settings.json (its permission rules, its sandbox for Bash, its Read() deny rules), and what
-- it asks CodeCompanion's permission for follows the chat's approval mode. The editor's own file access is not
-- offered to it (plugins/codecompanion.lua), so none of that passes through Neovim. What srt-ai.json hides
-- from commands (key variables, Neovim's temporary directory) is hidden from Claude Code only if its own
-- settings say so.
-- Nor are skills (`/skills` adds one of your own when you pick it, none by itself; the ones a project brings are
-- not offered: plugins/codecompanion.lua) and CLI agents (none set up).
-- `cmd:` values in an adapter's `env` go through the same wrapped function, so they would run under srt too
-- (none is used here: a key helper that needs the keyring or the network would fail).
-- `:lua =require("user.ai.sandbox").status()` shows what is in place; tests/ai_sandbox.lua checks the rules and
-- tests/ai_sandbox_chat.lua checks them in a real chat.
local M = {}

local uv = vim.uv

M.settings_file = vim.fn.stdpath "config" .. "/srt-ai.json"
-- instructions for the chat in a project's root (the rule groups in plugins/codecompanion.lua)
M.project_rules = ".nvim-ai.md"
-- which versions of those files the owner has read and approved: { [path] = sha256 }
M.approved_file = vim.fn.stdpath "state" .. "/ai_rules_approved.json"
M.rules_max_size = 262144 -- bytes; far more than a chat has room for

local locks = {} -- hook name -> why what it guards is switched off
local told = {}

--- A warning that is shown once per session.
local function tell(msg)
  if told[msg] then return end
  told[msg] = true
  vim.schedule(function() vim.notify(msg, vim.log.levels.WARN, { title = "AI sandbox" }) end)
end

---@return table|nil settings, string|nil why_not
local function settings()
  local ok, lines = pcall(vim.fn.readfile, M.settings_file)
  if not ok then return nil, "cannot read " .. M.settings_file end
  local decoded, s = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decoded or type(s) ~= "table" or type(s.filesystem) ~= "table" then
    return nil, M.settings_file .. " is not valid JSON with a `filesystem` table"
  end
  return s
end

local function srt_path()
  local path = vim.fn.exepath "srt"
  if path == "" then path = uv.os_homedir() .. "/.local/bin/srt" end
  return vim.fn.executable(path) == 1 and path or nil
end

---------------------------------------------------------------------------------------------------- paths

--- Absolute path with symbolic links resolved as far as it exists: for the entries of srt-ai.json and the
--- directories they are compared with (`canonical` is the strict one, for what a tool is about to use).
local function resolve(path)
  local abs = vim.fs.abspath(vim.fs.normalize(path))
  local tail, dir = {}, abs
  while true do
    local real = uv.fs_realpath(dir)
    if real then return #tail == 0 and real or vim.fs.joinpath(real, unpack(tail)) end
    local parent = vim.fs.dirname(dir)
    if parent == dir then return abs end
    table.insert(tail, 1, vim.fs.basename(dir))
    dir = parent
  end
end

local function within(path, dir) return path == dir or vim.startswith(path, dir == "/" and "/" or dir .. "/") end

local function entry_path(entry)
  if type(entry) == "table" then entry = entry.path end
  return type(entry) == "string" and entry ~= "" and vim.fs.normalize(entry) or nil
end

local function is_pattern(entry) return entry:find "[*?%[]" ~= nil end

local function list(entries) return type(entries) == "table" and entries or {} end

--- Whether `path` (resolved) is `entry` or lies beneath it; `entry` may be a glob like /tmp/dbus-*.
local function covered(path, entry)
  entry = entry_path(entry)
  if not entry then return false end
  if not is_pattern(entry) then return within(path, resolve(entry)) end
  local glob = vim.glob.to_lpeg(entry)
  local p = path
  while true do
    if glob:match(p) then return true end
    local parent = vim.fs.dirname(p)
    if parent == p then return false end
    p = parent
  end
end

--- The path a file tool is about to use, as the one absolute spelling that every later step agrees on:
--- symbolic links resolved as far as the path exists (a file about to be created resolves through its
--- existing parent directories). `keep_link`: resolve the directory only, for a tool that acts on a link
--- itself (deleting one must not delete what it points to).
---@return string|nil resolved, string lexical_or_why the path as it was written (absolute); the reason on nil
local function canonical(path, keep_link)
  if type(path) ~= "string" or path == "" then return nil, "the tool call has no path" end
  if path:find("\0", 1, true) or path:find "[\r\n]" then
    return nil, "a path cannot contain line breaks or NUL characters"
  end
  if vim.list_contains(vim.split(path, "[/\\]"), "..") then
    return nil, ("`%s`: `..` is not allowed in paths"):format(path)
  end
  -- (it would be dropped below, and `src/new/` would become a file `new`)
  if path:find "[/\\]$" then
    return nil, ("`%s` names a directory: the file tools take the path of a file"):format(path)
  end
  local abs = vim.fs.abspath(vim.fs.normalize(path))
  -- The tools spell the path out once more before they use it, some with vim.fs.normalize and some with
  -- fnamemodify(":p"), and the two disagree (on `~user`, on `$VAR`): only a path that both leave alone is
  -- certain to be the one that was checked. (":p" also marks a directory, which no file tool takes.)
  if vim.fs.normalize(abs) ~= abs or vim.fn.fnamemodify(abs, ":p") ~= abs then
    return nil, ("`%s` is a directory, or not a plain file path"):format(path)
  end
  local dir, tail = abs, {}
  if keep_link then
    dir, tail = vim.fs.dirname(abs), { vim.fs.basename(abs) }
  end
  while true do
    local real = uv.fs_realpath(dir)
    if real then return (#tail == 0 and real or vim.fs.joinpath(real, unpack(tail))), abs end
    -- It does not resolve. When nothing is there it is about to be created: fine. A link that leads nowhere
    -- (yet) would pass every check and then have the file created wherever it points.
    if uv.fs_lstat(dir) then
      return nil, ("`%s` goes through a symbolic link that leads nowhere or in a circle"):format(path)
    end
    local parent = vim.fs.dirname(dir)
    if parent == dir then return nil, ("`%s` cannot be resolved"):format(path) end
    table.insert(tail, 1, vim.fs.basename(dir))
    dir = parent
  end
end

---------------------------------------------------------------------------------------------------- text

--- Whether the character with the code point `cp` takes no room on a screen, or changes how the text around
--- it is laid out: what text is hidden with, from the person who reads it and not from a model.
local function unseen(cp)
  return (cp < 0x20 and cp ~= 0x09 and cp ~= 0x0A and cp ~= 0x0D)
    or (cp >= 0x7F and cp <= 0x9F)
    or cp == 0xAD
    or cp == 0x34F
    or cp == 0x61C
    or cp == 0x115F
    or cp == 0x1160
    or cp == 0x17B4
    or cp == 0x17B5
    or (cp >= 0x180B and cp <= 0x180F)
    or (cp >= 0x200B and cp <= 0x200F)
    or (cp >= 0x2028 and cp <= 0x202E)
    or (cp >= 0x2060 and cp <= 0x206F)
    or cp == 0x3164
    or (cp >= 0xFE00 and cp <= 0xFE0F)
    or cp == 0xFEFF
    or cp == 0xFFA0
    or (cp >= 0xFFF9 and cp <= 0xFFFB)
    or (cp >= 0x1BCA0 and cp <= 0x1BCA3)
    or (cp >= 0x1D173 and cp <= 0x1D17A)
    or (cp >= 0xE0000 and cp <= 0xE0FFF)
end

--- The code point that the bytes `seq` are in UTF-8, or nil when they are not one character of it.
local function code_point(seq)
  local a, b, c, d = seq:byte(1, 4)
  local cp, least
  if #seq == 1 and a < 0x80 then
    return a
  elseif #seq == 2 and a >= 0xC2 and a <= 0xDF then
    cp, least = (a - 0xC0) * 0x40 + (b - 0x80), 0x80
  elseif #seq == 3 and a >= 0xE0 and a <= 0xEF then
    cp, least = (a - 0xE0) * 0x1000 + (b - 0x80) * 0x40 + (c - 0x80), 0x800
  elseif #seq == 4 and a >= 0xF0 and a <= 0xF4 then
    cp, least = (a - 0xF0) * 0x40000 + (b - 0x80) * 0x1000 + (c - 0x80) * 0x40 + (d - 0x80), 0x10000
  end
  -- (not a longer way to write a shorter one, and not half of a UTF-16 pair)
  if not cp or cp < least or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then return nil end
  return cp
end

--- The three that emoji are put together with: a joiner, and "as text" / "as a picture".
local function joins(cp) return cp == 0x200D or cp == 0xFE0E or cp == 0xFE0F end

--- `text` with every character that does not show written out (`<U+200B>`; bytes that are no text: `<FF>`),
--- how many there were, the first one as it is written out and the line it is in. Line breaks and tabs stay.
--- The pieces emoji are made of stay where emoji have them: straight after a character outside ASCII, two in
--- a row at most (more of them would be a text of their own), and in a keycap (a digit, `#` or `*`, U+FE0F,
--- U+20E3). `strict`: they are written out as well (where every character counts: what is sent to the web).
---@return string spelled, integer count, string|nil first, integer|nil line
local function spell_out(text, strict)
  local count, first, at = 0, nil, nil
  local shown_until, run = 0, 0 -- where the last character outside ASCII that stayed ends; joiners since
  local function note(pos, shown)
    count = count + 1
    if not first then
      first, at = shown, pos
    end
    return shown
  end
  local spelled = text:gsub("()([%z\1-\8\11\12\14-\31\127-\255][\128-\191]*)", function(pos, seq)
    local cp = code_point(seq)
    if cp and joins(cp) and not strict then
      local after_shown = pos == shown_until and run < 2
      local keycap = cp == 0xFE0F
        and text:sub(pos - 1, pos - 1):find "[%d#*]"
        and text:sub(pos + #seq, pos + #seq + 2) == "\226\131\163"
      if after_shown or keycap then
        shown_until, run = pos + #seq, after_shown and run + 1 or 1
        return nil
      end
    end
    if cp and not unseen(cp) then
      shown_until, run = pos + #seq, 0
      return nil
    end
    shown_until = 0
    if cp then return note(pos, ("<U+%04X>"):format(cp)) end
    return note(pos, (seq:gsub(".", function(byte) return ("<%02X>"):format(byte:byte()) end)))
  end)
  local line = at and select(2, text:sub(1, at):gsub("\n", "")) + 1 or nil
  return spelled, count, first, line
end

---------------------------------------------------------------------------------------------------- what is protected

-- Names that run as code or steer an agent wherever they are in a project. The first two rows are srt's own
-- list (it denies them to commands: DANGEROUS_FILES and DANGEROUS_DIRECTORIES in its sandbox-utils.js;
-- tests/ai_sandbox.lua compares), the rest is what it leaves out. All of .git is on it: srt has to leave most
-- of it writable for `git commit` to work, a file tool has no business there.
M.protected_names = {
  ".gitconfig",
  ".gitmodules",
  ".bashrc",
  ".bash_profile",
  ".zshrc",
  ".zprofile",
  ".profile",
  ".ripgreprc",
  ".mcp.json",
  ".git",
  ".vscode",
  ".idea",
  ".claude",
  ".codecompanion",
  ".bash_login",
  ".bash_logout",
  ".zshenv",
  ".zlogin",
  ".zlogout",
  M.project_rules,
  -- what other agents read as their instructions the next time they start in the project
  "CLAUDE.md",
  "CLAUDE.local.md",
  "AGENTS.md",
  "GEMINI.md",
  ".cursorrules",
  ".cursor",
  ".windsurfrules",
  ".clinerules",
  "copilot-instructions.md",
  ".codex",
  ".gemini",
  ".opencode",
  "opencode.json",
  "opencode.jsonc",
  "AGENT.md",
  ".aider.conf.yml",
  ".agents",
  -- what an editor or a shell loads from the directory it starts in
  ".lazy.lua",
  ".nvim.lua",
  ".nvimrc",
  ".exrc",
  ".envrc",
  -- the usual directories for git hooks that are kept in the repository, and the hook managers' files
  ".husky",
  ".githooks",
  ".pre-commit-config.yaml",
  "lefthook.yml",
  ".lefthook.yml",
  "lefthook-local.yml",
  ".lefthook-local.yml",
  -- what this editor's language servers and builds run by themselves when a file of the project is opened
  -- or saved: rust-analyzer builds and runs build.rs and the commands its and cargo's settings name, latexmk
  -- runs its settings file (Perl). Not all of it: see "Not covered" above.
  "build.rs",
  ".cargo",
  "rust-analyzer.toml",
  ".rust-analyzer.toml",
  "rust-toolchain",
  "rust-toolchain.toml",
  "latexmkrc",
  ".latexmkrc",
}
-- ...and these, which are more than one name
local protected_paths = { ".github/instructions" }
local protected = {}
for _, name in ipairs(M.protected_names) do
  protected[name:lower()] = true
end

--- The protected name in `path`, if any: one of the names below the project directory `root`, or `.git`
--- anywhere (Neovim can run inside one). Compared without case: harmless here, and right on a file system
--- that ignores it.
local function protected_name(path, root)
  local below = within(path, root) and path:sub(#root + 1) or path
  for _, part in ipairs(vim.split(below:lower(), "/", { plain = true })) do
    if protected[part] then return part end
  end
  for _, piece in ipairs(protected_paths) do
    if ("/" .. below:lower() .. "/"):find("/" .. piece .. "/", 1, true) then return piece end
  end
  for _, part in ipairs(vim.split(path:lower(), "/", { plain = true })) do
    if part == ".git" then return part end
  end
end

-- Names of files that hold secrets: file tools neither read nor write them. (A command can still read them:
-- that one you see before it runs, unless the chat is set to approve everything.) Whole names of files, in
-- any directory of a project (a directory called .env, as some call a Python environment, is none)...
M.secret_names = {
  ".env",
  ".envrc",
  ".netrc",
  ".npmrc",
  ".pypirc",
  ".pgpass",
  ".git-credentials",
  ".htpasswd",
  ".yarnrc.yml",
  ".dev.vars",
  "credentials.json",
  "id_rsa",
  "id_dsa",
  "id_ecdsa",
  "id_ed25519",
}
-- ...directories, with all that is in them...
M.secret_directories = { ".ssh", ".gnupg", ".aws" }
-- ...and endings (`.env.local`, `prod.env`, but not the examples a project keeps for others to copy)
local secret_endings = {
  "%.pem$",
  "%.key$",
  "%.p12$",
  "%.pfx$",
  "%.kdbx$",
  "%.env$",
  "^%.env[%.%-_].+",
  "%.tfvars$",
  "%.tfstate$",
  "%.tfstate%.backup$",
  "^secrets?%.ya?ml$",
  "^secrets?%.json$",
  "^secrets?%.toml$",
}
local not_secret = { "%.example$", "%.sample$", "%.template$", "%.dist$", "%.defaults$" }
local secret, secret_directory = {}, {}
for _, name in ipairs(M.secret_names) do
  secret[name] = true
end
for _, name in ipairs(M.secret_directories) do
  secret_directory[name] = true
end

--- The part of `path` that is named like a secret, if any.
local function secret_name(path)
  path = path:lower()
  for part in path:gmatch "([^/]+)/" do
    if secret_directory[part] then return part end
  end
  local name = path:match "[^/]*$"
  if secret[name] or secret_directory[name] then return name end
  for _, ending in ipairs(not_secret) do
    if name:find(ending) then return nil end
  end
  for _, ending in ipairs(secret_endings) do
    if name:find(ending) then return name end
  end
end

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

--- The repository whose own files `path` (absolute) is among, when its directory is not called `.git`: a bare
--- repository, `name.git` by custom. What counts is what git looks for, not the name: a HEAD, and objects and
--- refs or a `commondir` that says where those are. A directory that is only called `x.git` is no repository.
--- In one, everything directly in it is git's (config, HEAD, packed-refs) and so are the directories git makes
--- there; another directory in it is a work tree (`project.git/main/...`, as some keep them) and not refused
--- here.
--- A directory that `path` itself would make one counts as one: with HEAD, objects/x and refs/x written by
--- the file tools, a `config` they wrote before would be a configuration git obeys, in any directory of a
--- project. (`git_file` below is the other half: they cannot write a HEAD at all.)
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
        return ("`%s` is protected (%s, in %s)"):format(shown, entry_path(entry), M.settings_file)
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
        M.settings_file
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
          M.settings_file
        )
      end
    end
  end
  for _, entry in ipairs(list(fs.allowWrite)) do
    local path = entry_path(entry)
    local wide = path and too_broad(resolve(path), roots)
    if wide then return ("allowWrite in %s has `%s`: %s"):format(M.settings_file, path, wide) end
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
          M.settings_file
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
      ):format(temp, vim.fs.dirname(temp), M.settings_file)
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
  return vim.list_extend(run, { srt_path(), "--settings", M.settings_file, "-c", cmd })
end

--- CodeCompanion hands curl the headers of a chat request, the API key among them, in a file of Neovim's
--- temporary directory, and only removes it after a request that went well: after a failed or cancelled one
--- the key stays there until Neovim closes. This removes those that are at least `min_age` seconds old (the
--- curl a file was written for has read it long before). curl's record of an answer's headers has the same
--- ending and is read by CodeCompanion when the request ends: it begins with "HTTP/", or is still empty
--- while the answer is awaited, and stays.
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

---------------------------------------------------------------------------------------------------- rules files

local function content_hash(path)
  local ok, lines = pcall(vim.fn.readfile, path, "b")
  return ok and vim.fn.sha256(table.concat(lines, "\n")) or nil
end

local function approved()
  local ok, lines = pcall(vim.fn.readfile, M.approved_file)
  local decoded, data = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
  return decoded and type(data) == "table" and not vim.islist(data) and data or {}
end

--- Whether the project instructions at `path` go along with chats: "missing", "approved" (the owner has
--- approved exactly this content in <Leader>AS) or "unapproved" (new, or changed since). What the file says
--- is obeyed by every later chat in the project, and a repository can bring one along (so can a command the
--- chat runs): it only counts once the owner has seen it.
--- Only a regular file of a size instructions have is read at all: a repository can bring a link to anything.
---@return "missing"|"approved"|"unapproved" state, string|nil real, string|nil hash
function M.rules_state(path)
  local read, real = pcall(function() return uv.fs_realpath(vim.fs.abspath(vim.fs.normalize(path))) end)
  local stat = read and real and uv.fs_stat(real)
  if not stat or stat.type ~= "file" then return "missing" end
  if stat.size > M.rules_max_size then return "unapproved", real, nil end
  local hash = content_hash(real)
  if not hash then return "missing" end
  return approved()[real] == hash and "approved" or "unapproved", real, hash
end

--- Why the file at `path` cannot be the project's instructions, or nil when it can (also when there is none
--- yet), and its absolute path. A repository can bring a link under that name: to a device that never ends,
--- or to a file of yours that opening and saving would then change.
local function rules_file_problem(path)
  local found, abs, stat = pcall(function()
    local full = vim.fs.abspath(vim.fs.normalize(path))
    return full, uv.fs_lstat(full)
  end)
  if not found or not stat then return nil end
  if stat.type == "link" then return "it is a symbolic link, and instructions are a file of the project itself" end
  if stat.type ~= "file" then return "it is not a regular file" end
  if stat.size > M.rules_max_size then return ("it is larger than instructions are (%d bytes)"):format(stat.size) end
  return nil, abs
end

-- More blanks in a row (a table with one long cell is padded with a good hundred), and more empty lines,
-- than instructions have a use for
local most_blanks, most_empty_lines = 400, 10
-- Characters that show as an empty place (the ones that show as nothing at all are in `unseen`): no-break
-- space, ogham space, U+2000 to U+200A and U+202F, U+205F, the empty braille pattern, ideographic space
local blank_characters = {
  "\194\160",
  "\225\154\128",
  "\226\128[\128-\138\175]",
  "\226\129\159",
  "\226\160\128",
  "\227\128\128",
}

--- Why `text` cannot be instructions: characters that do not show on a screen are how instructions are
--- written that a model reads and the person who approves them does not. (A byte order mark at the very
--- start is how some editors save, and the pieces emoji are made of say nothing.)
local function rules_text_problem(text)
  text = text:gsub("^\239\187\191", "")
  local _, count, first, line = spell_out(text)
  if count > 0 then
    return (
      "it has %d character%s that %s not show on a screen (%s in line %d), which is how instructions are hidden "
      .. "from the one who approves them. Open the file yourself and take %s out"
    ):format(
      count,
      count == 1 and "" or "s",
      count == 1 and "does" or "do",
      first,
      line,
      count == 1 and "it" or "them"
    )
  end
  -- Nor is it padded: blanks are how text is kept off the screen it is read on before it is approved.
  local number, empty = 0, 0
  for row in (text .. "\n"):gmatch "(.-)\r?\n" do
    number = number + 1
    for _, blank in ipairs(blank_characters) do
      row = row:gsub(blank, " ")
    end
    for run in row:gmatch "[ \t]+" do
      if #run > most_blanks then
        return (
          "line %d has %d blanks in a row, which is how text is kept off the screen of the one who approves it. "
          .. "Open the file yourself and take them out"
        ):format(number, #run)
      end
    end
    if not row:find "%S" then
      empty = empty + 1
    elseif empty > most_empty_lines then
      -- (only before more text: the ones a file ends with keep nothing off the screen)
      return (
        "it has more than %d lines in a row with nothing in them (from line %d), which is how text is kept off "
        .. "the screen of the one who approves it. Open the file yourself and take them out"
      ):format(most_empty_lines, number - empty)
    else
      empty = 0
    end
  end
end

--- The project instructions at `path` as they are on disk and the hash of exactly that text, for showing
--- them before they are approved; nil and why when they cannot be instructions (or there are none).
---@return string|nil text, string hash_or_why
function M.read_rules(path)
  local problem, abs = rules_file_problem(path)
  if problem then return nil, problem end
  local read, lines = pcall(vim.fn.readfile, abs or "", "b")
  if not abs or not read then return nil, "there is no such file" end
  local text = table.concat(lines, "\n")
  problem = rules_text_problem(text)
  if problem then return nil, problem end
  return text, vim.fn.sha256(text)
end

--- Why the project instructions at `path` cannot be opened or approved as they are, or nil when they can
--- (also when there is no file yet).
function M.rules_problem(path)
  local problem, abs = rules_file_problem(path)
  if problem or not abs then return problem end
  local read, lines = pcall(vim.fn.readfile, abs, "b")
  return read and rules_text_problem(table.concat(lines, "\n")) or nil
end

--- Approve the instructions at `path` as they are now. `shown`: the hash of what the owner was shown (or
--- several, when it is one of them): a file that is not that text, or no longer, is not approved.
--- Returns false and the reason when that failed.
function M.approve_rules(path, shown)
  local problem = M.rules_problem(path)
  if problem then return false, problem end
  local state, real, hash = M.rules_state(path)
  if state == "missing" or not hash then return false, path .. " does not exist" end
  if type(shown) == "string" then shown = { shown } end
  if type(shown) ~= "table" then return false, "nothing says which text was read" end
  if not vim.list_contains(shown, hash) then
    return false, "the file on disk is not what you were shown: it changed meanwhile"
  end
  if state == "approved" then return true end
  local all = approved()
  all[real] = hash
  -- Written beside the record and moved into place, so that nothing ever reads half of it. (Two Neovims that
  -- approve at the same moment can lose one of the two approvals: that file then waits to be approved again.)
  local ok = pcall(function()
    vim.fn.mkdir(vim.fs.dirname(M.approved_file), "p")
    local beside = ("%s.%d"):format(M.approved_file, uv.os_getpid())
    assert(vim.fn.writefile({ vim.json.encode(all) }, beside) == 0)
    assert(uv.fs_rename(beside, M.approved_file))
  end)
  if ok then return true end
  return false, "could not write " .. M.approved_file
end

--- The rules files out of `paths` (what CodeCompanion is about to read and send along) that may be used:
--- regular files, none of them protected, none that is written as part of the project but leads out of it
--- (a link in a repository), and the project's own instructions only as the owner approved them.
local function vet_rules(paths)
  local s = settings()
  local root = project_root()
  local kept = {}
  for _, path in ipairs(paths) do
    local abs = vim.fs.abspath(vim.fs.normalize(path))
    local real = uv.fs_realpath(abs)
    local stat = real and uv.fs_stat(real)
    local why
    if not s then
      why = "srt-ai.json cannot be read"
    elseif not root then
      why = "the directory Neovim is running in no longer exists"
    elseif not stat or stat.type ~= "file" then
      why = "it is not a regular file"
    elseif within(abs, root) and not within(real, root) then
      why = "it is a link that leads out of the project"
    else
      for _, entry in ipairs(list(s.filesystem.denyRead)) do
        if covered(real, entry) then why = "it is protected (" .. entry_path(entry) .. ")" end
      end
    end
    if not why and vim.fs.basename(abs) == M.project_rules then
      local state, _, hash = M.rules_state(real)
      -- (also for a file that was approved before this was looked for)
      local unusable = state == "approved" and M.rules_problem(real)
      if unusable then
        tell(("The project's AI instructions (%s) are not used: %s."):format(vim.fn.fnamemodify(real, ":~"), unusable))
        why = unusable
      elseif state ~= "approved" then
        tell(
          (
            "The project's AI instructions (%s) are new or have changed: chats do not get them until you have "
            .. "approved them (<Leader>AS, Project rules).\n[%s]"
          ):format(vim.fn.fnamemodify(real, ":~"), (hash or ""):sub(1, 8))
        )
        why = "not approved"
      end
    elseif why then
      tell(("The AI rules file %s is not used: %s."):format(vim.fn.fnamemodify(abs, ":~"), why))
    end
    if not why then kept[#kept + 1] = path end
  end
  return kept
end

--- Whether the rules files are sent along unchecked (the function wrapped for them is gone): the rule groups
--- in plugins/codecompanion.lua then load nothing by themselves.
function M.rules_locked() return locks.rules ~= nil end

---------------------------------------------------------------------------------------------------- tools

local no_git = "it runs git outside the sandbox, and git runs whatever the repository's configuration names. "
  .. "Use run_command with `git diff` or `git status` instead: that runs sandboxed."
local no_memory = "the memory tool is switched off in this editor: what it stores would be obeyed by later chats"

-- What every tool of the chat may do. `class`:
--   none      nothing outside the chat (asks the user, reads the plugin's own documentation)
--   path      works on the file named by `arg`: checked with `check_path` (`write`), and it gets the checked
--             path. `keep_link`: acts on a link itself. `open`: only for files that are open in the editor
--             (get_diagnostics would load the file otherwise, which starts language servers and git on a file
--             the model picked)
--   search    lists or reads below the project directory
--   command   runs a shell command: under srt
--   network   sends what the model writes to the web: only with the approval plugins/codecompanion.lua sets,
--             and asked for at every call (the `approval` hook below)
--   refuse    never runs
-- A tool that is not listed is refused.
M.policy = {
  ask_questions = { class = "none" },
  search_help = { class = "none" },
  read_file = { class = "path", arg = "filepath" },
  get_diagnostics = { class = "path", arg = "filepath", open = true },
  create_file = { class = "path", arg = "filepath", write = true },
  edit_file = { class = "path", arg = "filepath", write = true },
  overwrite_file = { class = "path", arg = "filepath", write = true },
  delete_file = { class = "path", arg = "filepath", write = true, keep_link = true },
  file_search = { class = "search" },
  grep_search = { class = "search" },
  run_command = { class = "command" },
  fetch_webpage = { class = "network" },
  web_search = { class = "network" },
  get_changed_files = { class = "refuse", why = no_git },
  memory = { class = "refuse", why = no_memory },
}

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

--- What the question before a web tool's call shows: every argument of the call, whole, with the characters
--- that do not show on a screen written out (they are sent like any other). (CodeCompanion's own question
--- names the tool and nothing else.)
local function web_question(tool, args)
  local lines, longest = {}, 2
  local keys = vim.tbl_keys(args)
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, key in ipairs(keys) do
    local value = args[key]
    if type(value) ~= "string" then
      local encoded, text = pcall(vim.json.encode, value)
      value = encoded and text or vim.inspect(value)
    end
    -- (one line each; a character that does not show is written out)
    value = spell_out(value:gsub("[\t\r\n]", " "), true)
    for run in value:gmatch "`+" do
      longest = math.max(longest, #run)
    end
    lines[#lines + 1] = ("%s: %s"):format((spell_out(tostring(key):gsub("[\t\r\n]", " "), true)), value)
  end
  local fence = ("`"):rep(longest + 1)
  return ("**%s** sends this to the web, all of it:\n\n%s\n%s\n%s"):format(
    tool.name,
    fence,
    table.concat(lines, "\n"),
    fence
  )
end

--- Why diagnostics for `path` (resolved) are not available, or nil when its file is open.
local function not_open(path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and uv.fs_realpath(vim.api.nvim_buf_get_name(bufnr)) == path then
      return nil
    end
  end
  return (
    "`%s` is not open in the editor, and diagnostics are only read for open files. Ask the user to open it, "
    .. "or run the project's linter or compiler with run_command."
  ):format(vim.fn.fnamemodify(path, ":."))
end

--- Why the tool call `tool` (as CodeCompanion prepared it) may not run, or nil when it may. A file tool's
--- path is replaced by the one that was checked, and its functions check once more when they are called:
--- every call of an answer is prepared before the first one runs, so an earlier command of the same answer
--- can have put a link where this one writes.
---@param given table|nil the tools the chat was given (chat.tool_registry.in_use)
local function vet(tool, given)
  local policy = M.policy[tool.name]
  if not policy then
    return (
      "it is not a tool this sandbox knows (`M.policy` in lua/user/ai/sandbox.lua), and a tool without a class "
      .. "there does not run"
    )
  end
  -- CodeCompanion runs any tool of its configuration that the model names, also one the chat does not have
  if type(given) ~= "table" then
    return "CodeCompanion no longer keeps a chat's tools where lua/user/ai/sandbox.lua looks for them"
  end
  -- (what gives a chat its tools has to be what the user typed: see `typed`)
  if locks.tool_tags then return locks.tool_tags end
  if not given[tool.name] then
    return "this chat was not given that tool. The user gives a chat a tool by naming it in a message: @{"
      .. tool.name
      .. "}"
  end
  local check
  if policy.class == "none" then
    return nil
  elseif policy.class == "refuse" then
    return policy.why
  elseif policy.class == "command" then
    return command_problem() -- (and again when the command starts: `sandboxed_command`)
  elseif policy.class == "network" then
    if locks.approval then return locks.approval end
    local opts = type(tool.opts) == "table" and tool.opts or {}
    if opts.require_approval_before ~= true or opts.protect ~= true then
      return "web tools only run when every call is approved, and that setting is missing (plugins/codecompanion.lua)"
    end
    local args = type(tool.args) == "table" and tool.args or {}
    local why = type(args.url) == "string" and address_problem(args.url)
    if why then return why end
    tool.output = type(tool.output) == "table" and tool.output or {}
    tool.output.prompt = function() return web_question(tool, args) end
    return nil
  elseif policy.class == "search" then
    local args = type(tool.args) == "table" and tool.args or {}
    local reads = tool.name ~= "file_search" -- (that one lists names, and a name is no secret)
    check = function() return search_problem() or (reads and secret_search(args, tool.opts) or nil) end
  elseif policy.class == "path" then
    local args = type(tool.args) == "table" and tool.args or {}
    local why, path = M.check_path(args[policy.arg], policy.write, policy.keep_link)
    if why then return why end
    -- a copy: the table is the model's own call, which stays in the conversation as it was written
    local checked = {}
    for key, value in pairs(args) do
      checked[key] = value
    end
    checked[policy.arg] = path
    tool.args = checked
    check = function()
      local again, now = M.check_path(path, policy.write, policy.keep_link)
      if again then return again end
      if now ~= path then
        return ("`%s` has changed since this tool call was checked: it now leads to %s"):format(path, tostring(now))
      end
      return policy.open and not_open(path) or nil
    end
  else
    return "its class in `M.policy` is not one the sandbox knows"
  end
  local why = check()
  if why then return why end
  for i, cmd in ipairs(type(tool.cmds) == "table" and tool.cmds or {}) do
    if type(cmd) ~= "function" then
      return "it is not built the way the sandbox expects (a command where a function belongs)"
    end
    tool.cmds[i] = function(...)
      local ok, again = pcall(check)
      if not ok then again = "its check failed (" .. tostring(again) .. ")" end
      if again then return { status = "error", data = ("The sandbox refused `%s`: %s"):format(tool.name, again) } end
      return cmd(...)
    end
  end
end

--- `text` without the parts that give a chat nothing: the lines of the selection it was opened with
--- (`selection`) and what is inside fenced code blocks. CodeCompanion reads `@{name}` anywhere in a message as
--- "give this chat the tool" and `#{name}` as "attach this" (every open buffer, for one): in code that is
--- pasted or selected, the one who wrote the code would be giving the chat its tools.
--- The selection is known by its lines, one by one: CodeCompanion's prompts put it into a message between two
--- fences, and the message comes back out of the chat buffer block by block, with other blank lines than it
--- went in with. A line of the selection gives nothing and ends no block, so that a selection with a fence in
--- it stays inside the one it was put in (and what follows it in the same message gives nothing either).
--- That holds for every message of the chat, which is the safe side: after a selection that had a line of
--- "```" in it, a block typed later is not ended by such a line, and a tag after it gives nothing.
local function typed(text, selection)
  local selected = {}
  if type(selection) == "string" then
    for line in selection:gmatch "[^\n]+" do
      selected[vim.trim(line)] = true
    end
    selected[""] = nil
  end
  local kept, fence = {}, nil
  for line in (text .. "\n"):gmatch "(.-)\n" do
    local inert = selected[vim.trim(line)]
    if fence then
      local closing = not inert and line:match("^ ? ? ?(" .. fence.mark .. "+)%s*$")
      if closing and #closing >= fence.length then fence = nil end
    else
      local opening = line:match "^ ? ? ?(```+)[^`]*$" or line:match "^ ? ? ?(~~~+)"
      if opening then
        fence = { mark = opening:sub(1, 1), length = #opening }
      elseif not inert then
        kept[#kept + 1] = line
      end
    end
  end
  return table.concat(kept, "\n")
end

-- The tags (`@{name}`, `#{name}`) that the user has said yes to, by conversation: the list of a chat's
-- messages, which a chat that is cleared starts anew (its tools are gone then as well)
local given_tags = setmetatable({}, { __mode = "k" })

--- Whether a tag that is new to a chat is asked about (<Leader>AS, "Tags in a message"): yes, unless that
--- was turned off.
local function asks_about_tags()
  local loaded, prefs = pcall(require, "user.ai.settings")
  return not (loaded and prefs.get "tag_question" == "off")
end

--- The tags out of `found` (the ones in a message) that `chat` gets what they stand for: the ones the user
--- has given it before, and after a question the rest. What was typed and what only reads as typed (a file's path, a
--- diagnostic or a line of a diff that a command of CodeCompanion put into the message, text that was
--- pasted) look the same from here: the question is what tells them apart.
local function user_gives(chat, found, question, notes)
  local talk = type(chat) == "table" and type(chat.messages) == "table" and chat.messages or nil
  local known = talk and given_tags[talk] or {}
  local new, listed = {}, {}
  for _, tag in ipairs(found) do
    if not known[tag] and not listed[tag] then
      listed[tag] = true
      new[#new + 1] = tag
    end
  end
  if #new == 0 or not asks_about_tags() then return found end
  table.sort(new)
  local shown = vim.tbl_map(function(tag)
    local note = type(notes) == "table" and notes[tag]
    return "  " .. spell_out(tag:gsub("%s+", " "), true) .. (note and "  (" .. note .. ")" or "")
  end, new)
  if vim.fn.confirm(question:format(table.concat(shown, "\n")), "&Yes\n&No", 2, "Question") ~= 1 then
    return vim.tbl_filter(function(tag) return known[tag] == true end, found)
  end
  for _, tag in ipairs(new) do
    known[tag] = true
  end
  if talk then given_tags[talk] = known end
  return found
end

--- The tags of the tools and groups that CodeCompanion finds in `message`, as they are written, and what
--- the question says about them (a group: the tools in it).
local function tool_tags_in(tools, message)
  local found, notes = {}, {}
  local names, groups = tools:find(message)
  for _, name in ipairs(names or {}) do
    found[#found + 1] = "@{" .. name .. "}"
  end
  for _, name in ipairs(groups or {}) do
    local tag = "@{" .. name .. "}"
    local members = vim.tbl_get(tools, "tools_config", "groups", name, "tools")
    found[#found + 1] = tag
    notes[tag] = type(members) == "table" and table.concat(vim.tbl_map(tostring, members), ", ") or "a group of tools"
  end
  return found, notes
end

--- The same for what it attaches (`#{buffer}`, `#{buffer:name}`), each with what follows it in braces: that
--- changes what is attached (`#{buffer}{diff}`), and CodeCompanion reads it the same way.
local function context_tags_in(context, message)
  local found = {}
  for _, instance in ipairs(context:find(message) or {}) do
    local tag = instance.target and ("#{%s:%s}"):format(instance.ctx, instance.target) or ("#{%s}"):format(instance.ctx)
    local params = message.content:match(vim.pesc(tag) .. "{([^}]*)}")
    found[#found + 1] = params and ("%s{%s}"):format(tag, params) or tag
  end
  return found
end

--- Chat:replace_user_inputs asks the tools and the editor context to `parse(chat, message)`: they get the
--- message as `typed` leaves it (a copy: the message itself goes to the model as it was written), and only
--- when the user gives the chat what its tags stand for. `tags_in`: the tags CodeCompanion finds in it.
local function typed_only(tags_in, question)
  return function(upstream)
    return function(self, chat, message, ...)
      if type(message) ~= "table" or type(message.content) ~= "string" then return false end
      local opened_with = type(chat) == "table" and type(chat.buffer_context) == "table" and chat.buffer_context.code
      local read, text = pcall(typed, message.content, opened_with)
      local copy = setmetatable({ content = read and text or "" }, { __index = message })
      local listed, found, notes = pcall(tags_in, self, copy)
      if not listed or type(found) ~= "table" then
        tell(
          "The sandbox could not tell what a message gives the chat (CodeCompanion finds tags in another way "
            .. "than lua/user/ai/sandbox.lua expects): the message gave it nothing."
        )
        return false
      end
      -- (nothing to give: CodeCompanion is not asked either)
      local given = #found > 0 and user_gives(chat, found, question, notes) or {}
      if #given == 0 then return false end
      -- (after a no to the new ones: the ones the chat had, as they are written and nothing else)
      if #given < #found then copy = setmetatable({ content = table.concat(given, "\n") }, { __index = message }) end
      return upstream(self, chat, copy, ...)
    end
  end
end

-- (what a question about tags ends with)
local not_typed =
  "\n\nIf you did not type that, it came in with other text: a file's path, a diagnostic, a diff, a paste.\n"

--- Why the link `link` of a message ({ destination, markdown }) attaches nothing to `chat`, or nil when it
--- does; "" when there is nothing to say about it. CodeCompanion attaches the file or fetches the page that
--- any link in a submitted message points to: `[x](~/.aws/credentials)` in text that was pasted, or in code
--- that was selected, would send that file to the provider. A file is attached when the file tools may read
--- it, a page after a question that shows its address, and nothing that the selection brought along.
local function link_problem(chat, link)
  local destination = type(link) == "table" and link.destination
  if type(destination) ~= "string" or destination == "" then return "" end
  local selection = type(chat) == "table" and type(chat.buffer_context) == "table" and chat.buffer_context.code
  if type(selection) == "string" and type(link.markdown) == "string" and selection:find(link.markdown, 1, true) then
    return "it is part of the code this chat was opened with"
  end
  -- CodeCompanion looks for a file first, by this path (to it `http://a/b` is the path `http:/a/b` as well),
  -- and for a page only when there is none: the same order here, so that what is checked is what it attaches.
  local path = vim.fs.abspath(vim.fs.normalize(destination))
  local stat = uv.fs_stat(path)
  if stat and stat.type ~= "directory" then return (M.check_path(path, false)) end
  -- (a link to something else is text and stays that)
  if not destination:find "^https?://." then return "" end
  local why = address_problem(destination)
  if why then return why end
  local question = ("A link in your message points to a page:\n\n  %s\n\nFetch it and attach it to the chat?"):format(
    (spell_out(destination, true))
  )
  return vim.fn.confirm(question, "&Fetch it\n&Leave it out", 2, "Question") ~= 1 and "you left it out" or nil
end

--- parser.context_paths lists the links of the message that is being submitted: only those that may attach
--- something go on to helpers.context_paths.attach, which calls it.
local function checked_links(upstream)
  return function(chat, ...)
    local links = upstream(chat, ...)
    if type(links) ~= "table" then return links end
    local kept = {}
    for _, link in ipairs(links) do
      local checked, why = pcall(link_problem, chat, link)
      if not checked then why = "its check failed (" .. tostring(why) .. ")" end
      if not why then
        kept[#kept + 1] = link
      elseif why ~= "" then
        local shown = spell_out(tostring(link.markdown):gsub("%s+", " "), true)
        if #shown > 120 then shown = shown:sub(1, 117) .. "..." end
        tell(
          ("A link in the message attached nothing to the chat: %s\n%s\n/file attaches a file, /fetch a page."):format(
            shown,
            why
          )
        )
      end
    end
    return #kept > 0 and kept or nil
  end
end

--- Every tool call passes through Tools:_resolve_and_prepare_tool before it is approved or run.
local function gate(upstream)
  return function(self, call)
    local tool, err, handled = upstream(self, call)
    if not tool then return tool, err, handled end
    local ok, why = pcall(vet, tool, vim.tbl_get(self, "chat", "tool_registry", "in_use"))
    if not ok then why = "its check failed (" .. tostring(why) .. ")" end
    if not why then return tool, err, handled end
    local msg = ("The sandbox refused `%s`: %s"):format(tostring(tool.name), why)
    -- CodeCompanion words an error it is handed as "tool not found", next to the list of tools that has the
    -- tool in it. The reason goes into the chat here instead, the way it reports arguments it cannot parse.
    local reported = pcall(function()
      self.chat:add_tool_output(tool, { content = msg })
      self.status = self.constants.STATUS_ERROR
    end)
    return nil, msg, reported
  end
end

---------------------------------------------------------------------------------------------------- install

local plugin = "lua/codecompanion/"
local hooks = {
  command = {
    module = "codecompanion.utils.os",
    field = "build_shell_command",
    caller = plugin .. "interactions/chat/tools/orchestrator.lua",
    call = "os_utils.build_shell_command(",
    wrap = function() return sandboxed_command end,
  },
  tools = {
    module = "codecompanion.interactions.chat.tools",
    field = "_resolve_and_prepare_tool",
    caller = plugin .. "interactions/chat/tools/init.lua",
    call = "self:_resolve_and_prepare_tool(",
    wrap = gate,
  },
  -- CodeCompanion asks this before it asks the user. A chat in "yolo" mode approves every tool, and "always
  -- accept" approves a tool for the rest of the chat: neither holds for the web tools, which ask each time.
  approval = {
    module = "codecompanion.interactions.chat.tools.approvals",
    field = "is_approved",
    caller = plugin .. "interactions/chat/tools/orchestrator.lua",
    call = "Approvals:is_approved(",
    wrap = function(upstream)
      return function(self, bufnr, args)
        local policy = type(args) == "table" and M.policy[args.tool_name]
        if policy and policy.class == "network" then return false end
        return upstream(self, bufnr, args)
      end
    end,
  },
  tool_tags = {
    module = "codecompanion.interactions.chat.tools",
    field = "parse",
    caller = plugin .. "interactions/chat/init.lua",
    call = "self.tools:parse(self, message)",
    wrap = typed_only(
      tool_tags_in,
      "A message gives this chat tools it did not have:\n\n%s" .. not_typed .. "Give the chat these tools?"
    ),
  },
  context_tags = {
    module = "codecompanion.interactions.shared.editor_context",
    field = "parse",
    caller = plugin .. "interactions/chat/init.lua",
    call = "self.editor_context:parse(self, message)",
    wrap = typed_only(
      context_tags_in,
      "A message attaches to this chat, for the first time:\n\n%s" .. not_typed .. "Attach it?"
    ),
  },
  link_list = {
    module = "codecompanion.interactions.chat.parser",
    field = "context_paths",
    caller = plugin .. "interactions/chat/helpers/context_paths.lua",
    call = "parser.context_paths(chat",
    wrap = checked_links,
  },
  links = {
    module = "codecompanion.interactions.chat.helpers.context_paths",
    field = "attach",
    caller = plugin .. "interactions/chat/init.lua",
    call = "context_paths.attach({",
    wrap = function(upstream)
      return function(...)
        -- (links that nothing checks attach nothing)
        if locks.link_list then return end
        return upstream(...)
      end
    end,
  },
  rules = {
    module = "codecompanion.interactions.shared.rules",
    field = "resolve_paths",
    caller = plugin .. "interactions/shared/rules/init.lua",
    call = "self:resolve_paths()",
    wrap = function(upstream)
      return function(...)
        local paths = upstream(...)
        local ok, kept = pcall(vet_rules, paths)
        return ok and kept or {}
      end
    end,
  },
}
M._hooks = hooks -- for tests
-- hook name -> the wrapper that was put in place. CodeCompanion's modules are loaded anew by `:Lazy reload`
-- (this one is not): a function that is not the wrapper is CodeCompanion's own and gets wrapped.
local ours = {}

--- Put the sandbox in place (again). Never fails. Returns whether the check on tool calls is in place, and
--- why not: without it the chat must not have tools (plugins/codecompanion.lua).
---@return boolean ok, string|nil why
function M.install()
  local function place(name, hook)
    local loaded, module = pcall(require, hook.module)
    local upstream = loaded and type(module) == "table" and module[hook.field]
    if type(upstream) ~= "function" then
      return ("CodeCompanion no longer has %s.%s, which lua/user/ai/sandbox.lua wraps"):format(hook.module, hook.field)
    end
    if upstream ~= ours[name] then
      ours[name] = hook.wrap(upstream)
      module[hook.field] = ours[name]
    end
    local src = vim.api.nvim_get_runtime_file(hook.caller, false)[1]
    local read, lines = pcall(vim.fn.readfile, src or "")
    if not read or not table.concat(lines, "\n"):find(hook.call, 1, true) then
      return ("CodeCompanion no longer calls %s where lua/user/ai/sandbox.lua expects it (%s)"):format(
        hook.field,
        hook.caller
      )
    end
  end
  for name, hook in pairs(hooks) do
    local ok, why = pcall(place, name, hook)
    locks[name] = not ok and ("the sandbox could not wrap %s: %s"):format(hook.field, tostring(why)) or why or nil
  end
  local consequence = {
    approval = "web tools do not run",
    command = "command tools do not run",
    tools = "the chat has no tools",
    rules = "rules files are not sent along with chats",
    tool_tags = "the chat's tools do not run",
    context_tags = "code that is pasted or selected can attach buffers to a chat (#{name})",
    link_list = "links in a message attach nothing",
    links = "links in a message attach files and pages unchecked",
  }
  for name, why in pairs(locks) do
    tell(("%s: %s until lua/user/ai/sandbox.lua is updated."):format(why, consequence[name]))
  end
  return locks.tools == nil, locks.tools
end

--- What is in place, for `:lua =require("user.ai.sandbox").status()`.
function M.status()
  local root = project_root()
  local wrapped = {}
  for name, hook in pairs(hooks) do
    local loaded, module = pcall(require, hook.module)
    wrapped[name] = loaded and ours[name] ~= nil and module[hook.field] == ours[name]
  end
  return {
    settings = M.settings_file,
    srt = srt_path() or false,
    project = root or false,
    wrapped = wrapped,
    locks = vim.deepcopy(locks),
    commands = M.command_problem() or "sandboxed",
    temp_exposed = M.temp_exposed() or false,
    hidden_variables = secret_variables(),
    project_rules = root and (M.rules_state(vim.fs.joinpath(root, M.project_rules))) or "missing",
  }
end

return M
