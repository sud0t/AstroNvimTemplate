---@type LazySpec
return {
  {
    "WhoIsSethDaniel/mason-tool-installer.nvim",
    opts = {
      -- by the names `:Mason` lists them under
      ensure_installed = {
        -- language servers
        "lua-language-server",
        "bash-language-server",
        "basedpyright",
        "hyprls",
        "html-lsp",
        "lemminx",
        "json-lsp",
        "texlab",

        -- formatters
        "stylua",
        "biome",
        "shfmt",

        -- debuggers
        "debugpy",
        "local-lua-debugger-vscode", -- Lua scripts (configured in plugins/dap.lua)

        "tree-sitter-cli", -- nvim-treesitter builds its parsers with it
      },
    },
  },
}
