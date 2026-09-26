---@diagnostic disable: trailing-space
---@type LazySpec
-- Put custom plugins and plugin overrides here
return {

  -- rust-analyzer setup
  {
    "mrcjkb/rustaceanvim",
    opts = function(_, opts)
      opts.server = opts.server or {}
      opts.server.cmd = function()
        local ra_path = vim.fn.system("rustup which rust-analyzer"):gsub("%s+$", "")
        return { ra_path }
      end
      return opts
    end,
  },
  -- precognition to help with my nvim motions
  {
  "tris203/precognition.nvim",
      event = "VeryLazy",
      opts = {
      -- startVisible = true,
      -- debounceMs = 0,
      showBlankVirtLine = false,
      -- highlightFullVirtLine = false,
      -- highlightColor = { link = "Comment" },
      -- targetedMotionHighlightColor = { link = "PrecognitionTargetedMotionDefault" },
      -- textObjectHighlightColors = {
      --     { link = "DiffText" },
      --     { link = "DiffChange" },
      --     { link = "Visual" },
      -- },
      -- targetedMotionHints = {
      --     enabled = true,
      --     prio = 1,
      -- },
      -- hints = {
      --      Caret = { text = "^", prio = 2 },
      --      Dollar = { text = "$", prio = 1 },
      --      MatchingPair = { text = "%", prio = 5 },
      --      Zero = { text = "0", prio = 1 },
      --      w = { text = "w", prio = 10 },
      --      b = { text = "b", prio = 9 },
      --      e = { text = "e", prio = 8 },
      --      W = { text = "W", prio = 7 },
      --      B = { text = "B", prio = 6 },
      --      E = { text = "E", prio = 5 },
      -- },
      gutterHints = {
          G = { text = "G", prio = 0 },
          gg = { text = "gg", prio = 0 },
          PrevParagraph = { text = "{", prio = 8 },
          NextParagraph = { text = "}", prio = 8 },
      },
      -- disabled_fts = {
      --     "startify",
      -- },
      },
  },

  -- My plugin overrides here:
  {
    "olimorris/codecompanion.nvim",
    opts = {
      interactions = {
        chat = {
          adapter = "anthropic",
          model = "claude-sonnet-5"
        },
      },
      opts = {
        log_level = "DEBUG",
      },
    },
  },

  -- customize dashboard options
  {
    "folke/snacks.nvim",
    opts = {
      dashboard = {
        preset = {
          header = table.concat({
            "███    ██ ██    ██ ██ ███    ███",
            "████   ██ ██    ██ ██ ████  ████",
            "██ ██  ██ ██    ██ ██ ██ ████ ██",
            "██  ██ ██  ██  ██  ██ ██  ██  ██",
            "██   ████   ████   ██ ██      ██",
          }, "\n"),
        },
      },
    },
  },
  -- You can also easily customize additional setup of plugins that is outside of the plugin's setup call
}
