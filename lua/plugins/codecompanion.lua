-- CodeCompanion (imported from AstroCommunity in community.lua), running on a local Ollama model
-- qwen2.5-coder:7b (4.7GB) does not fit in the T1000's 4GB, so Ollama splits it between GPU and CPU.
-- num_ctx is kept at 8k: enough for a ~600 line file, while the KV cache stays small enough
-- to leave most layers on the GPU (inline completion lives in plugins/minuet.lua).
-- <Leader>AR reviews with qwen3:4b-instruct instead: it fits entirely in VRAM (~36 tok/s) and, in testing, found
-- far more real bugs than qwen2.5-coder:3b with fewer false alarms.

local review_model = "qwen3:4b-instruct"

-- fits the review model's 6k context (~3.5 characters per token) next to the prompt and the answer
local max_review_chars = 15000

local function suggest_improvements()
  local mode = vim.fn.mode()
  if not mode:match "^[vV\22]" then
    local chars = vim.fn.wordcount().chars
    if chars > max_review_chars then
      vim.notify(
        ("Buffer is too large for the local model (%d chars, max ~%d). Select a region and try again."):format(
          chars,
          max_review_chars
        ),
        vim.log.levels.WARN
      )
      return
    end
  end
  -- the review model only fits on the GPU on its own; completion reloads afterwards (~1s, once)
  require("user.ollama").make_room_for(review_model)
  require("codecompanion").prompt "improve"
end

---@type LazySpec
return {
  "olimorris/codecompanion.nvim",
  -- the community module loads it on every opened file (~13ms); its commands, the <Leader>A mappings and
  -- require() already load it on demand
  event = function() return {} end,
  init = function()
    vim.api.nvim_create_autocmd("User", {
      pattern = "CodeCompanionRequestFinished",
      group = vim.api.nvim_create_augroup("ollama_vram", { clear = true }),
      desc = "Unload Ollama models pushed onto the CPU so they reload fully on the GPU",
      callback = function(args)
        local adapter = vim.tbl_get(args, "data", "adapter") or {}
        if vim.startswith(adapter.name or "", "ollama") then require("user.ollama").unload_spilled(adapter.model) end
      end,
    })
  end,
  specs = {
    {
      "AstroNvim/astrocore",
      opts = function(_, opts)
        local maps = opts.mappings
        maps.x = maps.x or {}
        -- visual-only (x): `v` mappings also apply in select mode, where typing a space into a snippet
        -- placeholder would start a <Leader> mapping
        for lhs, map in pairs(maps.v or {}) do
          if lhs:match "^<Leader>A" then
            maps.x[lhs], maps.v[lhs] = map, nil
          end
        end
        maps.n["<Leader>AR"] = { suggest_improvements, desc = "Suggest improvements (buffer)" }
        maps.x["<Leader>AR"] = { suggest_improvements, desc = "Suggest improvements (selection)" }
      end,
    },
  },
  opts = {
    interactions = {
      chat = { adapter = "ollama" },
      inline = { adapter = "ollama" },
    },
    adapters = {
      http = {
        ollama = function()
          return require("codecompanion.adapters").extend("ollama", {
            schema = {
              model = {
                default = "qwen2.5-coder:7b",
              },
              num_ctx = { default = 8192 },
              temperature = { default = 0.2 }, -- focused answers for code review
              keep_alive = { default = "5m" }, -- give the VRAM back to the completion model when idle
            },
          })
        end,
        -- used by <Leader>AR (prompts/improve.md)
        ollama_review = function()
          return require("codecompanion.adapters").extend("ollama", {
            name = "ollama_review",
            formatted_name = "Ollama (review)",
            schema = {
              model = { default = review_model },
              num_ctx = { default = 6144 }, -- KV cache is ~75KB/token here; 8k leaves too little VRAM headroom
              temperature = { default = 0.1 }, -- stick to the format and the code, no creative padding
              keep_alive = { default = "0s" }, -- unload as soon as it answers, handing the GPU back to completion
              num_gpu = { -- all layers on the GPU (Ollama's own estimate only places half of them)
                order = 13,
                mapping = "parameters.options",
                type = "number",
                optional = true,
                default = 99,
                desc = "Number of layers to offload to the GPU",
              },
              num_predict = { -- hard cap on answer length; 5 findings fit easily
                order = 14,
                mapping = "parameters.options",
                type = "number",
                optional = true,
                default = 1024,
                desc = "Maximum number of tokens to generate",
              },
            },
          })
        end,
      },
    },
    prompt_library = {
      markdown = {
        dirs = { vim.fn.stdpath "config" .. "/prompts" }, -- improve.md: <Leader>AR
      },
    },
    opts = {
      log_level = "ERROR", -- DEBUG logged every request in full
    },
  },
}
