-- AstroCommunity: import any community modules here
-- We import this file in `lazy_setup.lua` before the `plugins/` folder.
-- This guarantees that the specs are processed before any user plugins.
-- Overrides for these modules belong in the `plugins/` folder.

---@type LazySpec
return {
  "AstroNvim/astrocommunity",
  -- Python
  { import = "astrocommunity.pack.python.base" },
  { import = "astrocommunity.pack.python.basedpyright" },
  -- ruff does the job of black and isort by itself
  -- { import = "astrocommunity.pack.python.black" },
  -- { import = "astrocommunity.pack.python.isort" },
  { import = "astrocommunity.pack.python.ruff" },
  -- Lua
  { import = "astrocommunity.pack.lua" },
  -- Biome
  { import = "astrocommunity.pack.biome" },
  -- Bash
  { import = "astrocommunity.pack.bash" },
  -- Rust (overridden in plugins/rust.lua)
  { import = "astrocommunity.pack.rust" },
  -- TypeScript
  { import = "astrocommunity.pack.typescript-all-in-one" },
  -- AI implementation >:( (overridden in plugins/codecompanion.lua)
  { import = "astrocommunity.ai.codecompanion-nvim" },
  -- local inline code completion (overridden in plugins/minuet.lua)
  { import = "astrocommunity.ai.minuet-ai-nvim" },
  -- Tools (keymaps adjusted in the matching plugins/ files)
  { import = "astrocommunity.diagnostics.trouble-nvim" },
  { import = "astrocommunity.editing-support.refactoring-nvim" },
  { import = "astrocommunity.git.diffview-nvim" },
}
