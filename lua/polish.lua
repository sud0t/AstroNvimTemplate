-- Runs last in the setup: the place for plain Lua that fits none of the plugin specs.

-- Commenting is on <Leader>/ alone (plugins/astrocore.lua). Neovim offers its comment operator only through its
-- default gc/gcc mappings, with no public function behind them, so those mappings move to <Plug> names that
-- <Leader>/ runs, and the gc keys themselves are gone.
local function move_default_map(mode, lhs, new_lhs)
  local map = vim.fn.maparg(lhs, mode, false, true)
  assert(map.callback, ("Neovim's default mapping of %s in mode %s is missing"):format(lhs, mode))
  vim.keymap.set(mode, new_lhs, map.callback, { expr = map.expr == 1, desc = map.desc })
  vim.keymap.del(mode, lhs)
end

move_default_map("n", "gcc", "<Plug>(comment-line)")
move_default_map("x", "gc", "<Plug>(comment-operator)")
vim.keymap.del("n", "gc")
vim.keymap.del("o", "gc")
