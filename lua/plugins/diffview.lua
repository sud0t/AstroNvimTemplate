-- diffview.nvim (imported from AstroCommunity in community.lua): side-by-side git diffs and file history.
-- Loaded on demand by its commands and the mappings below (the community module loads it in every git file).
--   <Leader>gv  toggle diff of the working tree (close with <Leader>gv, or q in its file panels)
--   <Leader>gh  history of the current file (visual: history of the selected lines)
--   <Leader>gH  history of the repository
-- Enter on a commit in the commit pickers (<Leader>gc, <Leader>gC) opens it here as well (plugins/snacks.lua).

local function toggle()
  if require("diffview.lib").get_current_view() then
    vim.cmd "DiffviewClose"
  else
    vim.cmd "DiffviewOpen"
  end
end

local close = { "n", "q", "<Cmd>DiffviewClose<CR>", { desc = "Close diffview" } }

--- Diffview only looks: what changes the repository is done from the file tree (plugins/neo-tree.lua). These take
--- out its panel keys that stage, unstage and restore files.
---@param keys string[]
local function without(keys)
  return vim.tbl_map(function(lhs) return { "n", lhs, false } end, keys)
end

---@type LazySpec
return {
  "sindrets/diffview.nvim",
  event = function() return {} end,
  cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewToggleFiles", "DiffviewFocusFiles", "DiffviewFileHistory" },
  specs = {
    {
      "AstroNvim/astrocore",
      opts = function(_, opts)
        local maps = opts.mappings
        maps.x = maps.x or {}
        maps.n["<Leader>gv"] = { toggle, desc = "Diffview toggle" }
        maps.n["<Leader>gh"] = { "<Cmd>DiffviewFileHistory %<CR>", desc = "Diffview file history" }
        maps.x["<Leader>gh"] = { ":DiffviewFileHistory<CR>", desc = "Diffview line history" }
        maps.n["<Leader>gH"] = { "<Cmd>DiffviewFileHistory<CR>", desc = "Diffview repo history" }
      end,
    },
  },
  opts = function(_, opts)
    -- only in diffview's own panels (the diff panes are real file buffers, keep their q = macros)
    opts.keymaps = {
      file_panel = vim.list_extend({ close }, without { "-", "s", "S", "U", "X" }),
      file_history_panel = vim.list_extend({ close }, without { "X" }),
    }
    local community_hook = opts.hooks.diff_buf_read
    opts.hooks.diff_buf_read = function(bufnr, ...)
      community_hook(bufnr, ...)
      -- the index and the commits as buffers: writing the index one would stage what was changed in it
      if vim.api.nvim_buf_get_name(bufnr):find "^diffview://" then vim.bo[bufnr].modifiable = false end
    end
  end,
}
