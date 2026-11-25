-- The names the AI's file tools do not write (run as code, or obeyed by an agent) and the names of
-- files that hold secrets.
local M = {}

local State = require "user.ai.sandbox.state"
local Paths = require "user.ai.sandbox.paths"

local within = Paths.within

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
  State.project_rules,
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
  -- runs its settings file (Perl). Not all of it: see "Not covered" in docs/ai-sandbox.md.
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
local secret_names = {
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
local secret_directories = { ".ssh", ".gnupg", ".aws" }
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
for _, name in ipairs(secret_names) do
  secret[name] = true
end
for _, name in ipairs(secret_directories) do
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

M.protected_name = protected_name
M.secret_name = secret_name

return M
