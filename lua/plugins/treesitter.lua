-- Treesitter is configured through AstroCore: nvim-treesitter itself only downloads parsers.

---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@type AstroCoreOpts
  opts = {
    treesitter = {
      -- vimtex needs its own syntax highlighting (math zone detection for the snippets) and indent,
      -- so treesitter stays off for LaTeX
      highlight = function(lang) return lang ~= "latex" end,
      indent = function(lang) return lang ~= "latex" end,
      auto_install = true,
      ensure_installed = {
        "lua",
        "vim",
        "python",
        "bash",
        "hyprlang",
        "html",
        "xml",
        "json",
      },
    },
  },
}
