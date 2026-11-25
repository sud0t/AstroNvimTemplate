---@type LazySpec
return {
  "WhoIsSethDaniel/mason-tool-installer.nvim",
  opts = {
    -- what the packs in community.lua do not install, by the names `:Mason` lists them under
    ensure_installed = {
      "hyprls",
      "html-lsp",
      "lemminx",
      "clangd", -- configured in plugins/astrolsp.lua
      "local-lua-debugger-vscode", -- Lua scripts (configured in plugins/dap.lua)
    },
  },
}
