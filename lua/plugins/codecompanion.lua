-- CodeCompanion (imported from AstroCommunity in community.lua), running on a local Ollama model
-- qwen2.5-coder:7b (4.7GB) does not fit in the T1000's 4GB, so Ollama splits it between GPU and CPU.
-- num_ctx is kept at 8k: enough for a ~600 line file, while the KV cache stays small enough
-- to leave most layers on the GPU (inline completion lives in plugins/minuet.lua).
-- <Leader>AR (review and fix in place) lives in lua/user/review.lua and talks to Ollama directly.

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
        local review = function() require("user.review").run() end
        maps.n["<Leader>AR"] = { review, desc = "Review and fix inline (buffer)" }
        maps.x["<Leader>AR"] = { review, desc = "Review and fix inline (selection)" }
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
      },
    },
    opts = {
      log_level = "ERROR", -- DEBUG logged every request in full
    },
  },
}
