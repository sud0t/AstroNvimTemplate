-- diffview.nvim (imported from AstroCommunity in community.lua): side-by-side git diffs and file history.
-- Loaded on demand by its commands and the mappings below (the community module loads it in every git file).
--   <Leader>gv  toggle diff of the working tree (close with <Leader>gv, or q in its file panels)
--   <Leader>gh  history of the current file (visual: history of the selected lines)
--   <Leader>gH  history of the repository

local function toggle()
  if require("diffview.lib").get_current_view() then
    vim.cmd "DiffviewClose"
  else
    vim.cmd "DiffviewOpen"
  end
end

local close = { "n", "q", "<Cmd>DiffviewClose<CR>", { desc = "Close diffview" } }

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
  opts = {
    keymaps = { -- only in diffview's own panels (the diff panes are real file buffers, keep their q = macros)
      file_panel = { close },
      file_history_panel = { close },
    },
  },
}
