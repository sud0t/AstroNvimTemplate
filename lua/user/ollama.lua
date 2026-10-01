-- Keeps Ollama's models on the 4GB GPU. Ollama never moves a model back to the GPU once it was loaded partly on
-- the CPU, so models that got squeezed out are unloaded and reload fully on the GPU the next time they are used.
local M = {}

local url = "http://localhost:11434"

local function curl(args, on_exit)
  local cmd = vim.list_extend({ "curl", "-s", "--max-time", "2" }, args)
  if on_exit then return vim.system(cmd, { text = true }, on_exit) end
  return vim.system(cmd, { text = true }):wait()
end

--- Models currently loaded by Ollama (`/api/ps`), or an empty list if it is not reachable.
function M.loaded()
  local res = curl { url .. "/api/ps" }
  local ok, data = pcall(vim.json.decode, res.stdout or "")
  return ok and type(data) == "table" and data.models or {}
end

function M.unload(model, on_exit)
  return curl({ url .. "/api/generate", "-d", vim.json.encode { model = model, keep_alive = 0 } }, on_exit)
end

--- Unload every model except `keep` and wait (up to ~2s) until they are gone, so `keep` gets the whole GPU.
function M.make_room_for(keep)
  local waiting = false
  for _, m in ipairs(M.loaded()) do
    if m.name ~= keep then
      M.unload(m.name)
      waiting = true
    end
  end
  if not waiting then return end
  vim.wait(2000, function()
    for _, m in ipairs(M.loaded()) do
      if m.name ~= keep then return false end
    end
    return true
  end, 100)
end

--- Asynchronously unload models (other than `except`) that are running partly on the CPU.
function M.unload_spilled(except)
  curl({ url .. "/api/ps" }, function(res)
    local ok, data = pcall(vim.json.decode, res.stdout or "")
    if not ok or type(data) ~= "table" then return end
    for _, m in ipairs(data.models or {}) do
      if m.name ~= except and (m.size_vram or 0) < (m.size or 0) then M.unload(m.name, function() end) end
    end
  end)
end

return M
