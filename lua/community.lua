-- AstroCommunity: import any community modules here
-- We import this file in `lazy_setup.lua` before the `plugins/` folder.
-- This guarantees that the specs are processed before any user plugins.

---@type LazySpec
return {
  "AstroNvim/astrocommunity",
  -- Python
  { import = "astrocommunity.pack.python.base" },
  { import = "astrocommunity.pack.python.basedpyright" },
  -- { import = "astrocommunity.pack.python.black" },
  -- { import = "astrocommunity.pack.python.isort" },
  -- ruff does the job of black and isort by itself
  { import = "astrocommunity.pack.python.ruff" },
  -- Lua
  { import = "astrocommunity.pack.lua" },
  -- Biome
  { import = "astrocommunity.pack.biome" },
  -- Bash
  { import = "astrocommunity.pack.bash" },
  -- Rust
  { import = "astrocommunity.pack.rust" },
  -- import/override with your plugins folder
}
