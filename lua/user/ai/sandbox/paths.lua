-- Paths for the tool sandbox: the one resolved spelling of a path, and whether an entry of srt-ai.json
-- covers it.
local M = {}

local uv = vim.uv

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

M.resolve = resolve
M.within = within
M.entry_path = entry_path
M.is_pattern = is_pattern
M.list = list
M.covered = covered
M.canonical = canonical

return M
