-- A JSON object kept in a file: the AI chosen (state.lua) and the AI settings (settings.lua).
local M = {}

--- The JSON object in the file `path`: an empty table when there is no file or it holds anything else.
function M.read(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  local decoded, data = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
  -- (`[]` is an empty table too: as good as no file)
  if decoded and type(data) == "table" and (next(data) == nil or not vim.islist(data)) then return data end
  return {}
end

--- Write `data` to the file `path` as a JSON object, and say whether that worked. It is written beside the
--- file and moved over it: another Neovim never reads half of it.
function M.write(path, data)
  local beside = ("%s.%d.tmp"):format(path, vim.uv.os_getpid())
  local ok, written = pcall(function()
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local json = vim.json.encode(next(data) and data or vim.empty_dict())
    -- (a failure of either may be a return value, not an error)
    return vim.fn.writefile({ json }, beside) == 0 and vim.uv.fs_rename(beside, path)
  end)
  if ok and written then return true end
  vim.uv.fs_unlink(beside)
  return false
end

return M
