-- AstroCommunity modules. lazy_setup.lua imports this file before `plugins/`, so the specs there can override
-- what these set.

---@type LazySpec
return {
  "AstroNvim/astrocommunity",
  { import = "astrocommunity.pack.python.base" },
  { import = "astrocommunity.pack.python.basedpyright" },
  -- no black or isort packs: ruff does both jobs
  { import = "astrocommunity.pack.python.ruff" },
  { import = "astrocommunity.pack.lua" },
  { import = "astrocommunity.pack.biome" },
  { import = "astrocommunity.pack.bash" },
  { import = "astrocommunity.pack.rust" }, -- overridden in plugins/rust.lua
  { import = "astrocommunity.pack.go" }, -- adjusted in plugins/go.lua
  -- <Leader>T; the language packs add their adapters to it
  { import = "astrocommunity.test.neotest" },
  { import = "astrocommunity.pack.typescript" },
  { import = "astrocommunity.pack.json" },
  { import = "astrocommunity.ai.codecompanion-nvim" }, -- overridden in plugins/codecompanion.lua
  -- off until that file turns it on: without it the chat would run on the module's defaults, with no sandbox
  { "olimorris/codecompanion.nvim", enabled = false },
  { import = "astrocommunity.git.diffview-nvim" }, -- keymaps adjusted in plugins/diffview.lua
}
