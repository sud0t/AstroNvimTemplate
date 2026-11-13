-- Keeps Ollama's models on the 4GB GPU. Ollama never moves a model back to the GPU once it was loaded partly on
-- the CPU, so models that got squeezed out are unloaded and reload fully on the GPU the next time they are used.
local M = {}

local url = "http://localhost:11434"

local function curl(args, on_exit)
  return vim.system(vim.list_extend({ "curl", "-s", "--max-time", "2" }, args), { text = true }, on_exit)
end

function M.unload(model, on_exit)
  return curl({ url .. "/api/generate", "-d", vim.json.encode { model = model, keep_alive = 0 } }, on_exit)
end

--- Unload every model except `keep`, then call `on_done` (on the main loop) once they are gone, or after ~2s,
--- or right away when Ollama is not reachable. Nothing here blocks the editor.
function M.make_room_for(keep, on_done)
  local deadline = vim.uv.now() + 2000
  local function poll(first)
    curl({ url .. "/api/ps" }, function(res)
      local ok, data = pcall(vim.json.decode, res.stdout or "")
      local others = {}
      for _, m in ipairs(ok and type(data) == "table" and data.models or {}) do
        if m.name ~= keep then others[#others + 1] = m.name end
      end
      if #others == 0 or (not first and vim.uv.now() >= deadline) then return vim.schedule(on_done) end
      if first then
        for _, name in ipairs(others) do
          M.unload(name, function() end)
        end
      end
      vim.schedule(function()
        vim.defer_fn(function() poll(false) end, 100)
      end)
    end)
  end
  poll(true)
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
