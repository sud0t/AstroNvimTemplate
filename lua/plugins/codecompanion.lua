-- CodeCompanion (imported from AstroCommunity in community.lua). The chat uses the AI chosen with <Leader>As
-- (lua/user/ai.lua): Claude, or by default a local Ollama model:
-- qwen3:4b-instruct (2.5GB), the same model <Leader>AR uses, so the two share one copy in memory. It mostly fits
-- in the T1000's 4GB next to the desktop (measured: ~70% of it on the GPU with 1.7GB of VRAM taken by other
-- programs, 7 tokens/s). qwen2.5-coder:7b (4.7GB) never fits: a third of it on the GPU, half that speed.
-- num_ctx is kept at 8k: enough for a ~600 line file, while the KV cache stays small enough
-- to leave most layers on the GPU (inline completion lives in plugins/minuet.lua).
-- <Leader>AR (review and fix in place) lives in lua/user/review.lua and <Leader>Ai (inline prompt) in
-- lua/user/inline.lua; both talk to Ollama directly and show the answer while it is written (user/ai_stream.lua).
-- <Leader>Ac writes a commit message for the current diff: straight into the buffer when committing, in a chat
-- otherwise (lua/user/commit.lua; the chat is "Commit message" in the prompt library below).
-- The chat's tools are sandboxed by lua/user/ai_sandbox.lua (rules in srt-ai.json): commands run under srt, file
-- tools stay inside the project and away from the keyring, the password vault and browser profiles.

local prompt_library = {
  -- <Leader>Ac, `:CodeCompanion /commitmsg`; the diff comes from lua/user/commit.lua
  ["Commit message"] = {
    interaction = "chat",
    description = "Write a commit message for the staged (or all) changes",
    opts = {
      alias = "commitmsg",
      auto_submit = true,
      ignore_system_prompt = true, -- the general chat instructions only take context away from the diff
      stop_context_insertion = true,
    },
    prompts = {
      {
        role = "system",
        content = function()
          return require("user.commit").instructions
            .. "\n- Reply with the commit message inside one ``` code block and nothing else."
        end,
      },
      { role = "user", content = function() return require("user.commit").prompt() end },
    },
  },
}

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
        -- <Leader>Ai: prompt the model from inside the buffer (lua/user/inline.lua). It takes the place of
        -- CodeCompanion's inline assistant (visual <Leader>Aq), which had no normal mode key and does not show
        -- the answer while it is written.
        local inline = function() require("user.inline").run() end
        maps.n["<Leader>Ai"] = { inline, desc = "Inline prompt (write at cursor)" }
        maps.x["<Leader>Ai"] = { inline, desc = "Inline prompt (rewrite selection)" }
        maps.x["<Leader>Aq"] = nil
        -- no action palette: every entry in it that works with the local model has its own key
        maps.n["<Leader>Ap"], maps.x["<Leader>Ap"] = nil, nil
        maps.n["<Leader>As"] =
          { function() require("user.ai").select() end, desc = "Swap AI provider (local / Claude)" }
        local review = function() require("user.review").run() end
        maps.n["<Leader>AR"] = { review, desc = "Review and fix inline (buffer)" }
        maps.x["<Leader>AR"] = { review, desc = "Review and fix inline (selection)" }
      end,
    },
  },
  opts = function(_, opts)
    local ai = require "user.ai"
    require("user.ai_sandbox").install()
    -- the web tools can send anything the model has read to any address; by default they run without asking
    local ask_first = { opts = { require_approval_before = true, protect = true } } -- protect: auto mode asks too
    return require("astrocore").extend_tbl(opts, {
      interactions = {
        -- the chat follows the provider chosen with <Leader>As (lua/user/ai.lua changes it for new chats)
        chat = {
          adapter = (ai.chat_adapter()),
          tools = { fetch_webpage = ask_first, web_search = vim.deepcopy(ask_first) },
        },
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
          -- Claude with an API key ($ANTHROPIC_API_KEY or the system keyring) and the model chosen in <Leader>As
          anthropic = function()
            return require("codecompanion.adapters").extend("anthropic", {
              env = { api_key = function() return ai.api_key() end },
              schema = { model = { default = ai.claude_model_id() } },
            })
          end,
        },
        acp = {
          -- Claude through the Claude Code login. Claude Code reads ~/.claude/CLAUDE.md and the project's
          -- CLAUDE.md files by itself: not for the editor's chat (see `rules` below)
          claude_code = function()
            local path = ai.bridge_path() or "claude-agent-acp"
            return require("codecompanion.adapters").extend("claude_code", {
              commands = { default = { path }, yolo = { path, "--yolo" } },
              env = { CLAUDE_CODE_DISABLE_CLAUDE_MDS = "1" },
              -- Claude Code reads and writes files itself, under ~/.claude/settings.json (sandbox, Read() deny rules).
              -- Offering it the editor's file access would let those requests bypass both, unchecked.
              parameters = { clientCapabilities = { fs = { readTextFile = false, writeTextFile = false } } },
            })
          end,
        },
      },
      -- Instructions that go along with every chat. By default CodeCompanion attaches ~/.claude/CLAUDE.md and
      -- the project's CLAUDE.md/AGENTS.md/.cursorrules/...: written for coding agents with large contexts, they
      -- take up the local model's 8k context before the conversation starts. Only these two are attached
      -- instead, when they exist (keep them short):
      --   ~/.config/nvim/ai-rules.md   for every project
      --   .nvim-ai.md                  in a project's root (the directory Neovim was started in)
      -- The other files can still be added to a single chat by hand with /rules.
      rules = {
        editor = {
          description = "Short instructions for the editor's AI (ai-rules.md, .nvim-ai.md)",
          files = { vim.fn.stdpath "config" .. "/ai-rules.md", ".nvim-ai.md" },
        },
        opts = {
          chat = { autoload = "editor" },
          inline = { autoload = "editor" },
        },
      },
      prompt_library = prompt_library,
      opts = {
        log_level = "ERROR", -- DEBUG logged every request in full
      },
    })
  end,
}
