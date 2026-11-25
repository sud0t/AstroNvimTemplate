require("lazy").setup({
  {
    "AstroNvim/AstroNvim",
    version = "^6", -- without it lazy.nvim tracks AstroNvim's nightly
    import = "astronvim.plugins",
  },
  { import = "community" },
  { import = "plugins" },
} --[[@as LazySpec]], {
  install = { colorscheme = { "astrotheme", "habamax" } },
  ui = { backdrop = 100 },
  performance = {
    rtp = {
      disabled_plugins = {
        "gzip",
        "netrwPlugin",
        "rplugin", -- the remote plugin manifest (~2.5ms); molten is the only one and sources it when it loads
        "tarPlugin",
        "tohtml",
        "zipPlugin",
      },
    },
  },
} --[[@as LazyConfig]])
