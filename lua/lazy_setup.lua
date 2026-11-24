require("lazy").setup({
  {
    "AstroNvim/AstroNvim",
    version = "^6", -- without it lazy.nvim tracks AstroNvim's nightly
    import = "astronvim.plugins",
    opts = { -- AstroNvim options must be set here with the `import` key
      -- the leaders are set here because they have to exist before lazy.nvim sets up any mapping
      mapleader = " ",
      maplocalleader = ",",
      icons_enabled = true, -- needs a Nerd Font
      pin_plugins = nil, -- nil: pinned for as long as AstroNvim itself is tracked by `version`
      update_notifications = true, -- the reminder that pinned plugins need a second `:Lazy update`
    },
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
