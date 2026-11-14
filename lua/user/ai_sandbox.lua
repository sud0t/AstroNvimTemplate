-- Keeps the CodeCompanion chat's own tools (the tools the Ollama and API-key Claude chats use) away from
-- secrets. The rules live in ~/.config/nvim/srt-ai.json:
--   * every shell command a tool runs (run_command, and any other command-line tool) runs under srt, Anthropic's
--     sandbox runtime (bubblewrap + seccomp): no network, no D-Bus (so no keyring through `secret-tool`), no
--     other Unix sockets (KeePassXC's browser socket), the denyRead paths hidden, and writes only inside the
--     directory Neovim runs in, minus denyWrite;
--   * the file tools (read_file, create_file, edit_file, overwrite_file, delete_file, get_diagnostics) run inside
--     Neovim, so they are checked here instead: only paths inside that directory, none under denyRead, and for
--     writes none under denyWrite either.
-- Fails closed: when srt or srt-ai.json is missing, or CodeCompanion stops running tool commands through the
-- function wrapped here, command tools refuse to run instead of running unsandboxed. srt-ai.json is read again
-- on every check, so edits to it apply right away.
-- The Claude Code chat (ACP) is not covered here and does not need to be: Claude Code applies
-- ~/.claude/settings.json itself (its sandbox for Bash and its Read() deny rules).
local M = {}

M.settings_file = vim.fn.stdpath "config" .. "/srt-ai.json"

local write_tools = { create_file = true, edit_file = true, overwrite_file = true, delete_file = true }
local orchestrator_file = "lua/codecompanion/interactions/chat/tools/orchestrator.lua"
local unwrapped -- set when CodeCompanion no longer runs commands through the wrapped function

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
  if path == "" then path = vim.uv.os_homedir() .. "/.local/bin/srt" end
  return vim.fn.executable(path) == 1 and path or nil
end

--- Why command tools cannot run sandboxed right now, or nil when they can.
local function command_problem()
  if unwrapped then return unwrapped end
  if not srt_path() then return "srt (the sandbox runtime) is not installed" end
  local _, why = settings()
  return why
end

---------------------------------------------------------------------------------------------------- paths

--- Absolute path with symbolic links resolved as far as it exists (a file about to be created resolves
--- through its existing parent directories).
local function resolve(path)
  local abs = vim.fs.abspath(vim.fs.normalize(path))
  local tail, dir = {}, abs
  while true do
    local real = vim.uv.fs_realpath(dir)
    if real then return #tail == 0 and real or vim.fs.joinpath(real, unpack(tail)) end
    local parent = vim.fs.dirname(dir)
    if parent == dir then return abs end
    table.insert(tail, 1, vim.fs.basename(dir))
    dir = parent
  end
end

local function within(path, dir) return path == dir or vim.startswith(path, dir == "/" and "/" or dir .. "/") end

--- Whether `path` (resolved) is `entry` or lies beneath it; `entry` may be a glob like /tmp/dbus-*.
local function covered(path, entry)
  if type(entry) == "table" then entry = entry.path end
  if type(entry) ~= "string" or entry == "" then return false end
  entry = vim.fs.normalize(entry)
  if not entry:find "[*?%[]" then return within(path, resolve(entry)) end
  local glob = vim.glob.to_lpeg(entry)
  local p = path
  while true do
    if glob:match(p) then return true end
    local parent = vim.fs.dirname(p)
    if parent == p then return false end
    p = parent
  end
end

--- Why a file tool may not use `path`, or nil when it may.
---@param path string
---@param write boolean
---@return string|nil
function M.check_path(path, write)
  local s, why = settings()
  if not s then return why end
  if type(path) ~= "string" or path == "" then return nil end -- the tool itself reports a missing path
  if vim.list_contains(vim.split(path, "[/\\]"), "..") then return ("`%s`: `..` is not allowed in paths"):format(path) end
  local target, root = resolve(path), resolve(vim.fn.getcwd())
  if not within(target, root) then
    return ("`%s` is outside the project directory %s; the AI's file tools only work inside it"):format(path, root)
  end
  local fs = s.filesystem
  for _, list in ipairs(write and { fs.denyRead, fs.denyWrite } or { fs.denyRead }) do
    for _, entry in ipairs(type(list) == "table" and list or {}) do
      if covered(target, entry) then
        return ("`%s` is protected (%s, in %s)"):format(path, type(entry) == "table" and entry.path or entry, M.settings_file)
      end
    end
  end
end

---------------------------------------------------------------------------------------------------- install

function M.install()
  if M.installed then return end
  M.installed = true

  -- 1. Commands: CodeCompanion turns every command-line tool's command into `sh -c <command>` through
  --    utils.os.build_shell_command; run it under srt instead.
  local os_utils = require "codecompanion.utils.os"
  os_utils.build_shell_command = function(args)
    local cmd = type(args) == "table" and table.concat(args, " ") or args
    local why = command_problem()
    if why then return { "sh", "-c", 'printf "%s\\n" "$1" >&2; exit 126', "sh", "Blocked by the sandbox: " .. why } end
    return { srt_path(), "--settings", M.settings_file, "-c", cmd }
  end
  local src = vim.api.nvim_get_runtime_file(orchestrator_file, false)[1]
  local ok, lines = pcall(vim.fn.readfile, src or "")
  if not ok or not table.concat(lines, "\n"):find("os_utils.build_shell_command(", 1, true) then
    unwrapped = "CodeCompanion no longer runs tool commands through utils.os.build_shell_command, which "
      .. "lua/user/ai_sandbox.lua wraps; update the sandbox before using command tools"
    vim.notify(unwrapped, vim.log.levels.WARN, { title = "AI sandbox" })
  end

  -- 2. Every tool call passes through Tools:_resolve_and_prepare_tool before it is approved or run; refusing
  --    there sends the reason back to the model as the tool's error.
  local Tools = require "codecompanion.interactions.chat.tools"
  local resolve_tool = Tools._resolve_and_prepare_tool
  Tools._resolve_and_prepare_tool = function(self, call)
    local tool, err, handled = resolve_tool(self, call)
    if not tool then return tool, err, handled end
    local args = type(tool.args) == "table" and tool.args or {}
    local why
    if tool.name == "run_command" then
      why = command_problem()
    elseif args.filepath ~= nil then
      why = M.check_path(args.filepath, write_tools[tool.name] == true)
    end
    if why then return nil, ("The sandbox refused `%s`: %s"):format(tool.name, why), false end
    return tool, err, handled
  end
end

return M
