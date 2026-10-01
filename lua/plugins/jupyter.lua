-- Jupyter in Neovim, rendered in the terminal (kitty):
--   molten-nvim   runs a Jupyter kernel and shows output under the cell
--   image.nvim    draws plots/images through kitty's graphics protocol
--   `# %%` cells work in any plain .py file (cell runner in lua/user/jupyter.lua, no browser needed)
-- Needs ImageMagick plus the Python packages pynvim, jupyter_client and ipykernel in the Python Neovim uses.

---@type LazySpec
return {
  {
    "3rd/image.nvim",
    lazy = true, -- only molten needs it; loads with molten
    version = "^1.5",
    build = false, -- skip the luarocks build, the magick_cli processor only needs ImageMagick installed
    opts = {
      backend = "kitty",
      processor = "magick_cli",
      integrations = {}, -- molten draws its own images; leave image.nvim's document integrations off
      -- molten's recommended values: max_width/max_height must be set or huge images can crash the terminal
      max_width = 100,
      max_height = 12,
      max_height_window_percentage = math.huge,
      max_width_window_percentage = math.huge,
      window_overlap_clear_enabled = true,
      window_overlap_clear_ft_ignore = { "cmp_menu", "cmp_docs", "blink-cmp-menu", "blink-cmp-documentation", "" },
    },
  },
  {
    "benlubas/molten-nvim",
    version = "^1.0.0", -- stay below 2.0 to avoid breaking changes
    dependencies = { "3rd/image.nvim" },
    build = ":UpdateRemotePlugins",
    init = function()
      vim.g.molten_image_provider = "image.nvim"
      vim.g.molten_virt_text_output = true -- output stays visible under the cell
      vim.g.molten_auto_open_output = false -- use <leader>jo for the full output window
      vim.g.molten_wrap_output = true
      vim.g.molten_output_win_max_height = 20
      -- tint the `# %%` lines so cells are visible in a plain .py file (window-local, so drop it again when
      -- the window switches to another filetype)
      vim.api.nvim_create_autocmd({ "FileType", "BufWinEnter" }, {
        group = vim.api.nvim_create_augroup("jupyter_cell_markers", { clear = true }),
        callback = function(ev)
          local python = vim.bo[ev.buf].filetype == "python"
          if python and vim.w.jupyter_cell_hl == nil then
            vim.w.jupyter_cell_hl = vim.fn.matchadd("Folded", [[^# %%.*$]])
          elseif not python and vim.w.jupyter_cell_hl ~= nil then
            pcall(vim.fn.matchdelete, vim.w.jupyter_cell_hl)
            vim.w.jupyter_cell_hl = nil
          end
        end,
      })
    end,
    keys = {
      -- first press in a file: molten asks which kernel to start, then runs the cell
      {
        "<leader>J",
        function() require("user.jupyter").run_cell(true) end,
        desc = "Jupyter: run cell and move to next",
      },
      { "<leader>jc", function() require("user.jupyter").run_cell(false) end, desc = "Jupyter: run cell" },
      { "<leader>ja", function() require("user.jupyter").run_all() end, desc = "Jupyter: run all cells" },
      { "]j", function() require("user.jupyter").jump(1) end, desc = "Next cell" },
      { "[j", function() require("user.jupyter").jump(-1) end, desc = "Previous cell" },
      { "<leader>jv", ":<C-u>MoltenEvaluateVisual<CR>", mode = "x", silent = true, desc = "Jupyter: run selection" },
      { "<leader>jo", ":noautocmd MoltenEnterOutput<CR>", silent = true, desc = "Jupyter: open full output" },
      { "<leader>jh", "<cmd>MoltenHideOutput<CR>", desc = "Jupyter: hide output" },
      { "<leader>jd", "<cmd>MoltenDelete<CR>", desc = "Jupyter: delete cell output" },
      { "<leader>jr", "<cmd>MoltenRestart<CR>", desc = "Jupyter: restart kernel" },
      { "<leader>ji", function() require("user.jupyter").interrupt() end, desc = "Jupyter: interrupt running cell" },
      { "<leader>jq", function() require("user.jupyter").stop() end, desc = "Jupyter: stop kernel, clear outputs" },
    },
  },
}
