-- The local model, through Ollama: the AI actions' request, and keeping the models on the 4GB GPU. Ollama
-- never moves a model back to the GPU once it was loaded partly on the CPU, so models that got squeezed out
-- are unloaded and reload fully on the GPU the next time they are used.
local M = {}

local stream = require "user.ai.stream"

M.url = "http://localhost:11434"

-- The model of the local actions and the local chat, by Ollama's full name (the housekeeping below compares
-- names). Of the models installed here it is the only one that mostly fits on the GPU: the 7b/8b ones run
-- at half its speed. The actions' context sizes and length limits were measured for it.
M.model = "qwen3:4b-instruct"

-- num_ctx of the inline prompt, the commit message and the local chat (the review has its own)
M.context = 8192

local function curl(args, on_exit)
  return vim.system(vim.list_extend({ "curl", "-s", "--max-time", "2" }, args), { text = true }, on_exit)
end

function M.unload(model) curl { M.url .. "/api/generate", "-d", vim.json.encode { model = model, keep_alive = 0 } } end

--- The models Ollama has loaded, as /api/ps lists them (none when it is not reachable): `on_models(models)`,
--- off the main loop.
local function running(on_models)
  curl({ M.url .. "/api/ps" }, function(res)
    local data = stream.decode(res.stdout or "")
    on_models(data and type(data.models) == "table" and data.models or {})
  end)
end

--- Unload every model except `keep`, then call `on_done` (on the main loop) once they are gone, or after ~2s,
--- or right away when Ollama is not reachable. Nothing here blocks the editor.
function M.make_room_for(keep, on_done)
  local deadline = vim.uv.now() + 2000
  local function poll(first)
    running(function(models)
      local others = {}
      for _, m in ipairs(models) do
        if m.name ~= keep then others[#others + 1] = m.name end
      end
      if #others == 0 or (not first and vim.uv.now() >= deadline) then return vim.schedule(on_done) end
      if first then
        for _, name in ipairs(others) do
          M.unload(name)
        end
      end
      vim.schedule(function()
        vim.defer_fn(function() poll(false) end, 100)
      end)
    end)
  end
  poll(true)
end

--- Unload the models (other than `except`) that run partly on the CPU. Does not wait for it.
function M.unload_spilled(except)
  running(function(models)
    for _, m in ipairs(models) do
      if m.name ~= except and (m.size_vram or 0) < (m.size or 0) then M.unload(m.name) end
    end
  end)
end

--- Send `body` (an /api/chat request) and stream the answer: `on_text`, `on_done` and the handle are those of
--- stream.run. No key, and the stream's end is the answer's: Ollama reports its errors inside the stream.
function M.chat(body, on_text, on_done)
  local function take(state, line)
    local data = stream.decode(line)
    if not data then return end
    if data.error then state.fail(tostring(data.error)) end
    if data.done_reason then state.info.done_reason = data.done_reason end
    local piece = vim.tbl_get(data, "message", "content")
    if type(piece) == "string" and piece ~= "" then state.add(piece) end
  end
  local function finish(state, res)
    if res.code ~= 0 then state.fail "no answer from Ollama (is it running?)" end
    M.unload_spilled(body.model)
  end
  local cmd = { "curl", "-sN", "--max-time", "600", M.url .. "/api/chat", "-d", "@-" }
  local opts = { stdin = vim.json.encode(vim.tbl_extend("force", body, { stream = true })) }
  return stream.run(cmd, opts, take, on_text, finish, on_done)
end

return M
