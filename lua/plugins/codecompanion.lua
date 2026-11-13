-- CodeCompanion (imported from AstroCommunity in community.lua), running on a local Ollama model:
-- qwen3:4b-instruct (2.5GB), the same model <Leader>AR uses, so the two share one copy in memory. It mostly fits
-- in the T1000's 4GB next to the desktop (measured: ~70% of it on the GPU with 1.7GB of VRAM taken by other
-- programs, 7 tokens/s). qwen2.5-coder:7b (4.7GB) never fits: a third of it on the GPU, half that speed.
-- The model supports tool calling, which CodeCompanion's inline assistant (visual <Leader>Aq) needs to edit.
-- num_ctx is kept at 8k: enough for a ~600 line file, while the KV cache stays small enough
-- to leave most layers on the GPU (inline completion lives in plugins/minuet.lua).
-- <Leader>AR (review and fix in place) lives in lua/user/review.lua and talks to Ollama directly.
-- <Leader>Ac writes a commit message for the current diff ("Commit message" in the prompt library below).

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
        -- <Leader>Ac writes a commit message for the current diff (lua/user/commit.lua); the chat toggle the
        -- community module has there moves to <Leader>AC
        maps.n["<Leader>AC"], maps.x["<Leader>AC"] = maps.n["<Leader>Ac"], maps.x["<Leader>Ac"]
        maps.x["<Leader>Ac"] = nil
        maps.n["<Leader>Ac"] = { function() require("user.commit").open() end, desc = "Write commit message (diff)" }
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
                default = "qwen3:4b-instruct",
              },
              -- Ollama lists the model as able to think, so CodeCompanion would turn thinking on
              think = { default = false },
              num_ctx = { default = 8192 },
              temperature = { default = 0.2 }, -- focused answers for code review
              keep_alive = { default = "5m" }, -- give the VRAM back to the completion model when idle
            },
          })
        end,
      },
    },
    prompt_library = {
      -- <Leader>Ac, `:CodeCompanion /commitmsg`; the diff comes from lua/user/commit.lua
      ["Commit message"] = {
        interaction = "chat",
        description = "Write a commit message for the staged (or all) changes",
        opts = {
          alias = "commitmsg",
          auto_submit = true,
          ignore_system_prompt = true, -- the general chat instructions only take context away from the diff
          stop_context_insertion = true,
          -- The right model of the ones installed: reading a diff and summarising it in prose is an instruct
          -- task, and qwen3:4b-instruct is the only one that mostly fits on the GPU (the 7b/8b models run at
          -- half its speed). Named here so the prompt keeps it even if the chat default changes.
          adapter = { name = "ollama", model = "qwen3:4b-instruct" },
        },
        prompts = {
          {
            role = "system",
            content = [[
You write git commit messages. You are given the list of changed files, recent commit subjects of the repository and the diff.

Rules:
- First line: a summary of at most 60 characters, imperative mood, no trailing period. Follow the style of the recent commit subjects (prefixes, capitalisation); do not add a "feat:"/"fix:" prefix unless they use one.
- If the change needs explaining, add a blank line and then a short body: what changed and why, as plain sentences or "- " bullets, wrapped at 72 characters. Leave the body out for small changes.
- Describe only what the diff shows. Do not invent reasons, do not mention files that did not change, do not describe the diff line by line.
- Reply with the commit message inside one ``` code block and nothing else.]],
          },
          { role = "user", content = function() return require("user.commit").prompt() end },
        },
      },
    },
    opts = {
      log_level = "ERROR", -- DEBUG logged every request in full
    },
  },
}
