-- Customize Treesitter
-- --------------------
-- Treesitter customizations are handled with AstroCore
-- as nvim-treesitter simply provides a download utility for parsers

---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@type AstroCoreOpts
  opts = {
    treesitter = {
      -- vimtex needs its own syntax highlighting (math zone detection for the snippets) and indent,
      -- so treesitter stays off for LaTeX
      highlight = function(lang) return lang ~= "latex" end, -- enable/disable treesitter based highlighting
      indent = function(lang) return lang ~= "latex" end, -- enable/disable treesitter based indentation
      auto_install = true, -- enable/disable automatic installation of detected languages
      ensure_installed = {
        "lua",
        "vim",
        "python",
        "bash",
        "hyprlang",
        "html",
        "xml",
        "json",
        -- add more arguments for adding more treesitter parsers
      },
    },
  },
}
