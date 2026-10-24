-- none-ls (null-ls) only serves a few filetypes here: stylua/selene for Lua and biome for the web languages
-- (mason-null-ls registers sources for the Mason tools that have a none-ls builtin). AstroNvim loads it, with
-- mason-null-ls, on every opened file (`User AstroFile`, ~35ms), so load it on those filetypes instead.
-- Add the filetypes of any new Mason formatter/linter with a none-ls builtin here.

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
