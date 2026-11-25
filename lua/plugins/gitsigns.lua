-- Git keys in a file buffer only look: preview and diff a hunk, blame, move between hunks. What changes the
-- repository or throws changes away is done from the file tree (plugins/neo-tree.lua), so AstroNvim's keys that
-- stage and reset hunks and buffers are taken out again.

-- by mode as AstroNvim maps them
local changes_state = {
  n = { "<Leader>gs", "<Leader>gS", "<Leader>gr", "<Leader>gR" },
  v = { "<Leader>gs", "<Leader>gr" },
}

---@type LazySpec
return {
  "lewis6991/gitsigns.nvim",
  opts = function(_, opts)
    local astronvim_keys = assert(opts.on_attach, "AstroNvim no longer maps its gitsigns keys in on_attach")
    opts.on_attach = function(bufnr)
      astronvim_keys(bufnr)
      for mode, keys in pairs(changes_state) do
        for _, lhs in ipairs(keys) do
          vim.keymap.del(mode, lhs, { buffer = bufnr })
        end
      end
    end
  end,
}
