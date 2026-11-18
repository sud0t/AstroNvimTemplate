-- CodeCompanion (imported from AstroCommunity in community.lua). The chat uses the AI chosen with <Leader>As
-- (lua/user/ai/init.lua): Claude, another provider's model (lua/user/ai/providers.lua), or by default a local
-- Ollama model (<Leader>AS, Local model, changes which):
-- qwen3:4b-instruct (2.5GB), the same model <Leader>AR uses, so the two share one copy in memory. It mostly fits
-- in the T1000's 4GB next to the desktop (measured: ~70% of it on the GPU with 1.7GB of VRAM taken by other
-- programs, 7 tokens/s). qwen2.5-coder:7b (4.7GB) never fits: a third of it on the GPU, half that speed.
-- num_ctx is kept at 8k: enough for a ~600 line file, while the KV cache stays small enough
-- to leave most layers on the GPU (inline completion lives in plugins/minuet.lua).
-- <Leader>AR (review and fix in place) lives in lua/user/ai/review.lua and <Leader>Ai (inline prompt) in
-- lua/user/ai/inline.lua; both talk to the chosen provider directly, without CodeCompanion, and show the answer
-- while it is written (user/ai/stream.lua).
-- <Leader>Ac writes a commit message for the current diff: straight into the buffer when committing, in a chat
-- otherwise (lua/user/ai/commit.lua; the chat is "Commit message" in the prompt library below).
-- The chat's tools are sandboxed by lua/user/ai/sandbox.lua (rules in srt-ai.json): commands run under srt, file
-- tools stay inside the project and away from the keyring, the password vault, browser profiles and everything
-- that runs as code outside the sandbox (the editor's own files, .git, shell startup files). When the sandbox
-- cannot be put in place the chat starts without tools (`locked_down` below).
-- <Leader>AS (lua/user/ai/settings.lua) has the settings: the chat rules of the active provider, the local model,
-- how detailed commit messages are.

local prompt_library = {
  -- <Leader>Ac, `:CodeCompanion /commitmsg`; the diff comes from lua/user/ai/commit.lua
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
        content = function() return require("user.ai.commit").system "block" end,
      },
      { role = "user", content = function() return require("user.ai.commit").prompt() end },
    },
  },
}

-- The server-side tools of CodeCompanion's adapters, switched off in the options below and in `locked_down()`.
-- They run at the provider: past the sandbox and without asking, and the web tools among them would take the
-- place of the chat's own, which ask first. (tests/ai_sandbox.lua fails when an adapter has tools and no entry.)
local server_tools = {
  anthropic = { "code_execution", "memory", "web_fetch", "web_search" },
  gemini = { "web_search" },
  openai = { "web_search" },
  openrouter = { "fetch_webpage", "web_search" },
}

-- curl follows redirects for CodeCompanion's requests, and takes the key along to another host when it is in
-- a header of the provider's own (x-api-key, x-goog-api-key). An API does not redirect: no redirects.
local no_redirects = { "--max-redirs", "0" }

--- `available_tools` for the adapter `name`: every one of its server-side tools switched off.
local function no_server_tools(name)
  local tools = {}
  for _, tool in ipairs(server_tools[name] or {}) do
    tools[tool] = { enabled = false }
  end
  -- (and whatever else this version of CodeCompanion gives it)
  pcall(function()
    for tool in pairs(require("codecompanion.adapters.http." .. name).available_tools or {}) do
      tools[tool] = { enabled = false }
    end
  end)
  return tools
end

--- The local chat's adapter. (Read each time a chat resolves its adapter: a model changed in <Leader>AS
--- applies to the chats opened after it.)
local function ollama_adapter()
  local known, model = pcall(function() return require("user.ai").local_model() end)
  return require("codecompanion.adapters").extend("ollama", {
    schema = {
      model = { default = known and model or "qwen3:4b-instruct" },
      -- Ollama lists the model as able to think, so CodeCompanion would turn thinking on
      think = { default = false },
      num_ctx = { default = 8192 },
      temperature = { default = 0.2 }, -- focused answers for code review
      keep_alive = { default = "5m" }, -- give the VRAM back to the completion model when idle
    },
  })
end

-- For the Claude Code chat, whatever else is set: Claude Code reads ~/.claude/CLAUDE.md and the project's
-- CLAUDE.md files by itself, which is not for the editor's chat (see `rules` below). And it reads and writes
-- files itself, under ~/.claude/settings.json (sandbox, Read() deny rules): offering it the editor's file
-- access would let those requests bypass both, unchecked.
-- It does not get the other providers' API keys either, where they are in the environment: for the process
-- it runs in they are empty. (An empty value has to come from a function: CodeCompanion looks a string up.)
local function empty() return "" end
local claude_code = {
  env = {
    CLAUDE_CODE_DISABLE_CLAUDE_MDS = "1",
    OPENAI_API_KEY = empty,
    GEMINI_API_KEY = empty,
    GOOGLE_API_KEY = empty,
    OPENROUTER_API_KEY = empty,
  },
  parameters = { clientCapabilities = { fs = { readTextFile = false, writeTextFile = false } } },
}

-- What the chat is left with when its sandbox cannot be put in place (lua/user/ai/sandbox.lua does not load, a
-- CodeCompanion update took away what it wraps, or the options below fail): no tools, no rules files, the local
-- model, and <Leader>As leaves it there (`vim.g.ai_chat_locked`). Spelled out here, with nothing from
-- lua/user/ that is not asked for under pcall or only when it is used, so that it holds whatever else is broken.
local function locked_down()
  local tools = {}
  for _, name in ipairs {
    "ask_questions",
    "create_file",
    "delete_file",
    "edit_file",
    "fetch_webpage",
    "file_search",
    "get_changed_files",
    "get_diagnostics",
    "grep_search",
    "memory",
    "overwrite_file",
    "read_file",
    "run_command",
    "search_help",
    "web_search",
  } do
    tools[name] = { enabled = false }
  end
  -- (and whatever else this version of CodeCompanion has)
  pcall(function()
    for name in pairs(require("codecompanion.config").interactions.chat.tools) do
      if name ~= "opts" and name ~= "groups" then tools[name] = { enabled = false } end
    end
  end)
  -- their server-side tools are not the chat's tools: switching those off does not reach them. (The chat
  -- starts with the local model, but its adapter can be changed from inside a chat.)
  local adapters = { ollama = ollama_adapter }
  for name in pairs(server_tools) do
    adapters[name] = function()
      return require("codecompanion.adapters").extend(
        name,
        { available_tools = no_server_tools(name), raw = no_redirects }
      )
    end
  end
  -- (CodeCompanion asks Anthropic for its models with the key among curl's arguments, where every process on
  -- the machine can read it: here it gets a list without asking)
  adapters.anthropic = function()
    local model = { context_window = 1000000, max_tokens = 64000 }
    local known =
      { ["claude-opus-5-5"] = { formatted_name = "Claude Opus 5.5", meta = model, opts = { can_reason = true } } }
    pcall(function() known = require("user.ai.claude").chat_models(nil) end)
    return require("codecompanion.adapters").extend("anthropic", {
      available_tools = no_server_tools "anthropic",
      raw = no_redirects,
      schema = { model = { default = "claude-opus-5-5", choices = function() return known end } },
    })
  end
  return {
    interactions = {
      chat = { adapter = "ollama", tools = tools },
      inline = { adapter = "ollama" },
      code_review = { enabled = false },
    },
    adapters = {
      http = adapters,
      acp = {
        claude_code = function() return require("codecompanion.adapters").extend("claude_code", claude_code) end,
      },
    },
    rules = { opts = { chat = { enabled = false, autoload = {} }, inline = { autoload = {} }, show_presets = false } },
    prompt_library = prompt_library, -- (<Leader>Ac outside a commit buffer)
  }
end

--- Put the sandbox in place: true, or false and the reason.
local function install_sandbox()
  local loaded, sandbox = pcall(require, "user.ai.sandbox")
  if not loaded then return false, "lua/user/ai/sandbox.lua does not load: " .. tostring(sandbox) end
  local called, ok, why = pcall(sandbox.install)
  if not called then return false, tostring(ok) end
  return ok, why
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
        if vim.startswith(adapter.name or "", "ollama") then require("user.ai.ollama").unload_spilled(adapter.model) end
      end,
    })
    vim.api.nvim_create_autocmd("User", {
      pattern = "CodeCompanionRequestFinished",
      group = vim.api.nvim_create_augroup("ai_request_headers", { clear = true }),
      desc = "Remove the files with a request's headers (the API key) that CodeCompanion leaves behind",
      callback = function()
        -- (a little later: a file that is some seconds old has been read by the curl it was written for)
        vim.defer_fn(function()
          pcall(function() require("user.ai.sandbox").remove_request_headers(10) end)
        end, 15000)
      end,
    })
    vim.api.nvim_create_autocmd("User", {
      pattern = "CodeCompanionChatCreated",
      group = vim.api.nvim_create_augroup("ai_sandbox", { clear = true }),
      desc = "Make sure the chat's tools are still sandboxed (a plugin reload loads CodeCompanion's modules anew)",
      callback = function(args)
        if install_sandbox() then return end
        -- the options were set with the sandbox in place and it is gone: take the tools away where they are,
        -- from this chat too
        local tools = require("codecompanion.config").interactions.chat.tools
        for name, tool in pairs(locked_down().interactions.chat.tools) do
          if type(tools[name]) == "table" then tools[name].enabled = tool.enabled end
        end
        pcall(function()
          local chat = require("codecompanion").buf_get_chat(args.data.bufnr)
          chat.tools:refresh { adapter = chat.adapter }
        end)
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
        -- <Leader>Ac writes a commit message for the current diff (lua/user/ai/commit.lua); the chat toggle the
        -- community module has there moves to <Leader>AC
        maps.n["<Leader>AC"], maps.x["<Leader>AC"] = maps.n["<Leader>Ac"], maps.x["<Leader>Ac"]
        maps.x["<Leader>Ac"] = nil
        maps.n["<Leader>Ac"] = { function() require("user.ai.commit").open() end, desc = "Write commit message (diff)" }
        -- <Leader>Ai: prompt the model from inside the buffer (lua/user/ai/inline.lua). It takes the place of
        -- CodeCompanion's inline assistant (visual <Leader>Aq), which had no normal mode key and does not show
        -- the answer while it is written.
        local inline = function() require("user.ai.inline").run() end
        maps.n["<Leader>Ai"] = { inline, desc = "Inline prompt (write at cursor)" }
        maps.x["<Leader>Ai"] = { inline, desc = "Inline prompt (rewrite selection)" }
        maps.x["<Leader>Aq"] = nil
        -- no action palette: every entry in it that works with the local model has its own key
        maps.n["<Leader>Ap"], maps.x["<Leader>Ap"] = nil, nil
        maps.n["<Leader>As"] = { function() require("user.ai").select() end, desc = "AI provider and model" }
        maps.n["<Leader>AS"] =
          { function() require("user.ai.settings").open() end, desc = "AI settings (rules, model, commit detail)" }
        local review = function() require("user.ai.review").run() end
        maps.n["<Leader>AR"] = { review, desc = "Review and fix inline (buffer)" }
        maps.x["<Leader>AR"] = { review, desc = "Review and fix inline (selection)" }
      end,
    },
  },
  opts = function(_, opts)
    -- first: nothing below may leave the chat's tools without it
    local sandboxed, why = install_sandbox()
    local configured, result = pcall(function()
      if not sandboxed then error(why, 0) end
      local sandbox = require "user.ai.sandbox"
      local ai = require "user.ai"
      --- The chat adapter of a provider in lua/user/ai/providers.lua: its key (never an argument of a
      --- command: CodeCompanion hands it to curl in a file), the model chosen in <Leader>As, no server-side
      --- tools.
      local function provider_adapter(id)
        local provider = require("user.ai.providers").list[id]
        return function()
          return require("codecompanion.adapters").extend(provider.chat, {
            env = { api_key = function() return (ai.key(id)) end },
            schema = { model = { default = ai.model_id(id) } },
            available_tools = no_server_tools(provider.chat),
            raw = no_redirects,
          })
        end
      end
      -- the web tools can send anything the model has read to any address; by default they run without asking
      local ask_first = { opts = { require_approval_before = true, protect = true } } -- protect: auto mode asks too
      local off = function() return { enabled = false } end
      return require("astrocore").extend_tbl(opts, {
        interactions = {
          -- the chat follows the provider chosen with <Leader>As (lua/user/ai/init.lua changes it for new chats)
          chat = {
            adapter = (ai.chat_adapter()),
            tools = {
              fetch_webpage = ask_first,
              web_search = vim.deepcopy(ask_first),
              -- runs git outside the sandbox, and git runs what a repository's configuration names (a model
              -- can still ask to run `git diff` as a command, which is sandboxed)
              get_changed_files = off(),
              -- what it stores is obeyed by later chats, and it reads and writes files unchecked
              memory = off(),
              -- in a chat set to "auto", commands that begin with one of these run without asking: by default
              -- also `ls` and `git status`, with any arguments the model adds
              run_command = { opts = { safe_commands = { "pwd" } } },
            },
          },
          inline = { adapter = "ollama" },
          -- it runs `git add --all` and more outside the sandbox each time a chat is submitted, in whatever
          -- repository Neovim is in (<Leader>AR is this configuration's own review: lua/user/ai/review.lua)
          code_review = { enabled = false },
        },
        adapters = {
          http = {
            ollama = ollama_adapter,
            -- Claude with an API key ($ANTHROPIC_API_KEY or the system keyring) and the model chosen in <Leader>As
            anthropic = function()
              local claude = require "user.ai.claude"
              -- What the models can do, asked from the API with the key on curl's stdin (lua/user/ai/claude.lua).
              -- CodeCompanion's own request for it has the key among curl's arguments, where every process on
              -- the machine can read it. Asked here, before a chat takes its settings from the answer;
              -- CodeCompanion asks `choices` several times per chat, which never waits for the keyring.
              claude.chat_models(ai.api_key(), { async = false })
              return require("codecompanion.adapters").extend("anthropic", {
                env = { api_key = function() return ai.api_key() end },
                schema = {
                  model = {
                    default = ai.claude_model_id(),
                    choices = function(_, request) return claude.chat_models(ai.known_key "claude", request) end,
                  },
                },
                -- (its memory tool is the one switched off above)
                available_tools = no_server_tools "anthropic",
                raw = no_redirects,
              })
            end,
            openai = provider_adapter "openai",
            gemini = provider_adapter "gemini",
            openrouter = provider_adapter "openrouter",
          },
          acp = {
            -- Claude through the Claude Code login
            claude_code = function()
              local path = ai.bridge_path() or "claude-agent-acp"
              return require("codecompanion.adapters").extend(
                "claude_code",
                vim.tbl_extend("error", claude_code, {
                  commands = { default = { path }, yolo = { path, "--yolo" } },
                  -- the model chosen in <Leader>As, by the name Claude Code lists it under ("fable", "opus",
                  -- ...), asked for when a chat's session starts. A model Claude Code does not offer this login
                  -- is not asked for: the chat then runs Claude Code's default model, and only CodeCompanion's
                  -- log says so.
                  defaults = { session_config_options = { model = function() return ai.claude_model() end } },
                })
              )
            end,
          },
        },
        -- Instructions that go along with every chat. By default CodeCompanion attaches ~/.claude/CLAUDE.md and
        -- the project's CLAUDE.md/AGENTS.md/.cursorrules/...: written for coding agents with large contexts, they
        -- take up the local model's 8k context before the conversation starts. Only these are attached instead,
        -- when they exist (<Leader>AS opens them):
        --   ~/.config/nvim/ai-rules-local.md    for every project, in chats with the local model (keep it short)
        --   ~/.config/nvim/ai-rules-cloud.md    for every project, in chats with a provider's model
        --   .nvim-ai.md                         in a project's root (the directory Neovim was started in), once
        --                                       you have approved what it says (<Leader>AS, Project rules: a
        --                                       repository can bring one along)
        -- A chat gets the group of the model it talks to (lua/user/ai/init.lua, `rules_group`: asked for each
        -- new chat). CodeCompanion's own groups (CLAUDE.md and the like, which can pull in any file they name)
        -- are not offered by /rules.
        rules = {
          editor_local = {
            description = "Short instructions for the local model (ai-rules-local.md, .nvim-ai.md)",
            files = { ai.rules_files.editor_local, sandbox.project_rules },
          },
          editor_cloud = {
            description = "Instructions for the providers' models (ai-rules-cloud.md, .nvim-ai.md)",
            files = { ai.rules_files.editor_cloud, sandbox.project_rules },
          },
          opts = {
            -- (nothing when the sandbox cannot check the files it is about to send)
            chat = { autoload = function() return sandbox.rules_locked() and {} or ai.rules_group() end },
            -- (the inline adapter is always the local model)
            inline = { autoload = function() return sandbox.rules_locked() and {} or "editor_local" end },
            show_presets = false,
          },
        },
        prompt_library = prompt_library,
        -- Skills (`/skills`) from your own directories only. CodeCompanion also offers those a project brings
        -- (.claude/skills, .codecompanion/skills), ahead of yours of the same name: picking one gives the chat
        -- tools and the project's instructions, which is what .nvim-ai.md needs your approval for.
        skills = { dirs = { "~/.config/codecompanion/skills", "~/.agents/skills", "~/.claude/skills" } },
        opts = {
          log_level = "ERROR", -- DEBUG logged every request in full
        },
      })
    end)
    vim.g.ai_chat_locked = not configured or nil
    if configured then return result end
    vim.schedule(
      function()
        vim.notify(
          "The AI chat is local, without tools and rules files: its sandbox is not in place.\n" .. tostring(result),
          vim.log.levels.ERROR,
          { title = "AI sandbox" }
        )
      end
    )
    return vim.tbl_deep_extend("force", opts or {}, locked_down())
  end,
}
