-- Jupyter in the terminal (kitty): molten-nvim runs a kernel and shows the output under the cell, image.nvim draws
-- the plots through kitty's graphics protocol. The cells are the `# %%` blocks of any .py file (user/jupyter.lua).
-- Needs ImageMagick, and the Python packages pynvim, jupyter_client and ipykernel in the Python Neovim uses.

---@type LazySpec
return {
  {
    "3rd/image.nvim",
    lazy = true, -- only molten needs it; loads with molten
    version = "^1.5",
    build = false, -- no luarocks build: magick_cli, the default processor, only needs ImageMagick installed
    opts = {
      -- molten draws its own images, so image.nvim draws in no document. Each integration that is on by default
      -- is named: image.nvim merges this table into its defaults, and an empty one would change nothing.
      integrations = {
        markdown = { enabled = false },
        asciidoc = { enabled = false },
        typst = { enabled = false },
        neorg = { enabled = false },
        syslang = { enabled = false },
      },
      -- molten's recommended values: max_width/max_height must be set or huge images can crash the terminal
      max_width = 100,
      max_height = 12,
      max_height_window_percentage = math.huge,
      max_width_window_percentage = math.huge,
      window_overlap_clear_enabled = true,
      window_overlap_clear_ft_ignore = { "blink-cmp-menu", "blink-cmp-documentation", "" },
    },
  },
  {
    "benlubas/molten-nvim",
    version = "^1.0.0",
    dependencies = { "3rd/image.nvim" },
    build = ":UpdateRemotePlugins", -- lazy.nvim loads the plugin first, so `config` has defined the command
    -- molten is a Python remote plugin: its commands and functions come from the remote plugin manifest, which is
    -- no longer sourced at startup (`rplugin` is disabled in lazy_setup.lua) but here, when molten is first used
    cmd = { "MoltenInit", "MoltenInfo", "MoltenLoad", "MoltenImportOutput", "MoltenEvaluateLine" },
    config = function() vim.cmd "runtime! plugin/rplugin.vim" end,
    init = function()
      vim.g.molten_image_provider = "image.nvim"
      vim.g.molten_virt_text_output = true -- output stays visible under the cell
      vim.g.molten_auto_open_output = false -- use <leader>jo for the full output window
      vim.g.molten_wrap_output = true
      vim.g.molten_output_win_max_height = 20
      -- Tints the `# %%` lines, so that cells show in a plain .py file. A match belongs to its window: a split
      -- (WinNew) copies none, and a window that changes to another filetype has to drop its own.
      vim.api.nvim_create_autocmd({ "FileType", "BufWinEnter", "WinNew" }, {
        group = vim.api.nvim_create_augroup("jupyter_cell_markers", { clear = true }),
        callback = function()
          -- the buffer shown in the current window, which is not always the event's buffer (FileType also
          -- fires for buffers loaded in the background)
          local python = vim.bo.filetype == "python"
          if python and vim.w.jupyter_cell_hl == nil then
            vim.w.jupyter_cell_hl = vim.fn.matchadd("Folded", [[^# %%.*$]])
          elseif not python and vim.w.jupyter_cell_hl ~= nil then
            pcall(vim.fn.matchdelete, vim.w.jupyter_cell_hl)
            vim.w.jupyter_cell_hl = nil
          end
        end,
      })
    end,
    -- buffer-local to Python buffers (lazy.nvim's `ft`), so which-key lists them nowhere else
    keys = function()
      local keys = {
        -- first press in a file: molten asks which kernel to start, then runs the cell
        { "<leader>jc", function() require("user.jupyter").run_cell() end, desc = "Jupyter: run cell" },
        { "<leader>ja", function() require("user.jupyter").run_all() end, desc = "Jupyter: run all cells" },
        { "<leader>jv", ":<C-u>MoltenEvaluateVisual<CR>", mode = "x", silent = true, desc = "Jupyter: run selection" },
        { "<leader>jo", ":noautocmd MoltenEnterOutput<CR>", silent = true, desc = "Jupyter: open full output" },
        { "<leader>jh", "<cmd>MoltenHideOutput<CR>", desc = "Jupyter: hide output" },
        { "<leader>jd", "<cmd>MoltenDelete<CR>", desc = "Jupyter: delete cell output" },
        { "<leader>jr", "<cmd>MoltenRestart<CR>", desc = "Jupyter: restart kernel" },
        { "<leader>ji", function() require("user.jupyter").interrupt() end, desc = "Jupyter: interrupt running cell" },
        { "<leader>jq", function() require("user.jupyter").stop() end, desc = "Jupyter: stop kernel, clear outputs" },
      }
      for _, key in ipairs(keys) do
        key.ft = "python"
      end
      return keys
    end,
  },
}
