-- What the parts of the tool sandbox share, each of them once: where its files are, the reader of
-- srt-ai.json, the srt program, which hooks are switched off (`locks`: `install` in init.lua writes
-- it, the checks read it when they are asked) and the warning that is shown once.
local M = {}

local uv = vim.uv

M.settings_file = vim.fn.stdpath "config" .. "/srt-ai.json"
-- instructions for the chat in a project's root (the rule groups in plugins/codecompanion.lua)
M.project_rules = ".nvim-ai.md"

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

M.locks = locks
M.tell = tell
M.settings = settings
M.srt_path = srt_path

return M
