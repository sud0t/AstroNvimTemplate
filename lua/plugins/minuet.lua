-- Local inline (ghost text) code completion with minuet-ai.nvim (imported from AstroCommunity in community.lua)
-- Model: qwen2.5-coder:1.5b-base through Ollama. A base model with FIM support, small enough to stay entirely
-- in the T1000's 4GB of VRAM next to the 7b chat model, so suggestions arrive in about a second.
-- Toggled globally with <Leader>Aq (off at startup). While a suggestion is shown in insert mode:
--   <A-A> accept all, <A-l> accept line, <A-h> un-accept that line, <A-z> accept n lines,
--   <A-]>/<A-[> next/prev, <A-e> dismiss

local enabled = false

-- minuet only knows a per-buffer switch (`vim.b.minuet_virtual_text_auto_trigger`), so apply it to every buffer
local function set_auto_trigger(buf)
  if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
    vim.b[buf].minuet_virtual_text_auto_trigger = enabled
  end
end

local function toggle()
  enabled = not enabled
  require "minuet" -- make sure it is set up before touching its buffer state
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    set_auto_trigger(buf)
  end
  local group = vim.api.nvim_create_augroup("minuet_global_auto_trigger", { clear = true })
  if enabled then
    vim.api.nvim_create_autocmd("BufEnter", {
      group = group,
      desc = "Enable minuet auto trigger in new buffers",
      callback = function(args) set_auto_trigger(args.buf) end,
    })
  else
    require("minuet.virtualtext").action.dismiss()
  end
  vim.notify("AI inline completion " .. (enabled and "enabled" or "disabled"))
end

---@type LazySpec
return {
  "milanglacier/minuet-ai.nvim",
  cmd = "Minuet",
  specs = {
    {
      "AstroNvim/astrocore",
      opts = function(_, opts)
        -- replaces CodeCompanion's inline prompt (from the community module) on this key
        opts.mappings.n["<Leader>Aq"] = { toggle, desc = "Toggle AI inline completion" }
      end,
    },
  },
  opts = {
    provider = "openai_fim_compatible",
    n_completions = 1, -- one request per trigger; every extra completion is another full model run
    -- characters around the cursor sent to the model (~600 tokens); prompt processing dominates latency on a T1000
    context_window = 2500,
    context_ratio = 0.75,
    throttle = 1000,
    debounce = 400,
    request_timeout = 4, -- streaming: a slow answer is cut short instead of dropped
    notify = "error",
    provider_options = {
      openai_fim_compatible = {
        api_key = "TERM", -- Ollama needs no key, but minuet requires the named env var to be set
        name = "Ollama",
        end_point = "http://localhost:11434/v1/completions",
        model = "qwen2.5-coder:1.5b-base",
        stream = true,
        optional = {
          max_tokens = 64,
          top_p = 0.9,
          temperature = 0.2,
        },
      },
    },
    virtualtext = {
      auto_trigger_ft = {}, -- auto trigger is driven by the <Leader>Aq toggle above
      keymap = {
        accept = "<A-A>",
        accept_n_lines = "<A-z>",
        next = "<A-]>",
        prev = "<A-[>",
        dismiss = "<A-e>",
      },
      show_on_completion_menu = false,
    },
  },
  config = function(_, opts)
    require("minuet").setup(opts)
    -- line by line stepping with undo (lua/user/minuet_lines.lua)
    vim.keymap.set(
      "i",
      "<A-l>",
      function() require("user.minuet_lines").accept() end,
      { desc = "Accept suggestion line" }
    )
    vim.keymap.set(
      "i",
      "<A-h>",
      function() require("user.minuet_lines").undo() end,
      { desc = "Un-accept suggestion line" }
    )
  end,
}
