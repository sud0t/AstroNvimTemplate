-- AstroNvim loads none-ls on every file (~35ms). Here it serves only the filetypes below (stylua, selene,
-- biome); a new Mason tool with a none-ls builtin needs its filetypes added.

---@type LazySpec
return {
  "nvimtools/none-ls.nvim",
  event = function() return {} end, -- drop AstroNvim's `User AstroFile`
  ft = {
    "lua",
    "luau",
    "css",
    "graphql",
    "javascript",
    "javascriptreact",
    "json",
    "jsonc",
    "typescript",
    "typescriptreact",
  },
}
