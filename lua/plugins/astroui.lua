---@type LazySpec
return {
  "AstroNvim/astroui",
  ---@type AstroUIOpts
  opts = {
    colorscheme = "astrodark",
    highlights = {
      init = { -- applies to every colorscheme
        -- parameter ghost text (lua/user/signature_ghost.lua); set here so it survives a colorscheme change
        SignatureGhost = { link = "LspInlayHint" },
      },
      astrodark = {},
    },
    icons = {
      LSPLoading1 = "⠋",
      LSPLoading2 = "⠙",
      LSPLoading3 = "⠹",
      LSPLoading4 = "⠸",
      LSPLoading5 = "⠼",
      LSPLoading6 = "⠴",
      LSPLoading7 = "⠦",
      LSPLoading8 = "⠧",
      LSPLoading9 = "⠇",
      LSPLoading10 = "⠏",
    },
  },
}
