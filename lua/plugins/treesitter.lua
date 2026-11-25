-- Treesitter is configured through AstroCore: nvim-treesitter itself only downloads parsers.

---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@type AstroCoreOpts
  opts = {
    treesitter = { ensure_installed = { "hyprlang", "html", "xml" } },
  },
}
