-- LaTeX notes with the PDF beside the editor:
--   vimtex    compiles with latexmk in continuous mode and drives zathura (SyncTeX both ways)
--   zathura   opens as its own window, Hyprland tiles it next to kitty and it reloads on every rebuild
--   texlab    LSP for completion/diagnostics (installed through Mason in plugins/mason.lua)
--   math autosnippets live in luasnippets/tex.lua
-- Opening a .tex file starts the compiler, the PDF opens after the first successful build.
-- Changes are written on InsertLeave/TextChanged so the PDF follows along without :w.
-- In zathura, ctrl+click jumps Neovim to that line, ,lv jumps the PDF to the cursor.

---@type LazySpec
return {
  {
    "lervag/vimtex", -- base spec and which-key descriptions come from astrocommunity (lua/community.lua)
    init = function()
      -- zathura_simple skips xdotool window tracking (X11 only), SyncTeX still works on Wayland
      vim.g.vimtex_view_method = "zathura_simple"
      vim.g.vimtex_quickfix_open_on_warning = false -- only pop the quickfix list for real errors
      vim.g.vimtex_quickfix_ignore_filters = { "Underfull", "Overfull" }

      local group = vim.api.nvim_create_augroup("latex_notes", { clear = true })
      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "VimtexEventInitPost",
        desc = "Start continuous compilation when a LaTeX file opens",
        callback = function() vim.cmd "VimtexCompile" end,
      })
      vim.api.nvim_create_autocmd({ "InsertLeave", "TextChanged" }, {
        group = group,
        pattern = "*.tex",
        desc = "Write LaTeX buffers so latexmk rebuilds the PDF",
        callback = function(ev)
          if vim.bo[ev.buf].modified and vim.bo[ev.buf].buftype == "" then
            vim.api.nvim_buf_call(ev.buf, function() vim.cmd "silent! update" end)
          end
        end,
      })
    end,
  },
  {
    "L3MON4D3/LuaSnip",
    opts = { enable_autosnippets = true }, -- math snippets in luasnippets/tex.lua expand without a trigger key
  },
}
