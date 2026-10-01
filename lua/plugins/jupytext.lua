-- jupytext.nvim: open .ipynb notebooks as plain text with `# %%` cells ("hydrogen" style), the same format as
-- the molten cell runner in plugins/jupyter.lua (<Leader>J, <Leader>j...). Saving writes the .ipynb back,
-- keeping its outputs. Needs the jupytext CLI (`pipx install jupytext`).
--
-- Two gaps in the plugin (unmaintained since 2024) are covered here:
--   * notebooks without `metadata.kernelspec` (made by jupytext, VS Code, some exports) crashed on open
--   * opening a notebook that does not exist yet crashed; it now starts an empty `# %%` buffer and the
--     notebook is created on the first :w

local language_extensions = { python = "py", julia = "jl", r = "r", R = "r", bash = "sh" }

-- language/extension of a notebook, with fallbacks for missing metadata
local function notebook_metadata(filename)
  local f = io.open(filename, "r")
  local ok, nb = pcall(vim.json.decode, f and f:read "a" or "")
  if f then f:close() end
  local meta = ok and type(nb) == "table" and nb.metadata or {}
  local kernel, info = meta.kernelspec or {}, meta.language_info or {}
  local language = kernel.language or info.name or "python"
  local extension = language_extensions[language] or (info.file_extension or ""):gsub("^%.", "")
  return { language = language, extension = extension ~= "" and extension or "py" }
end

-- a notebook that does not exist yet: edit `# %%` cells, create the .ipynb on the first write
local function new_notebook(ev)
  local buf, file = ev.buf, vim.fn.fnamemodify(ev.match, ":p")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# %%", "" })
  vim.bo[buf].filetype = "python"
  vim.bo[buf].modified = false
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    once = true,
    callback = function()
      local tmp = vim.fn.tempname() .. ".py"
      vim.fn.writefile(vim.api.nvim_buf_get_lines(buf, 0, -1, false), tmp)
      local res = vim.system({ "jupytext", "--from", "py:percent", "--to", "ipynb", "--output", file, tmp }):wait()
      vim.fn.delete(tmp)
      if res.code ~= 0 then
        return vim.notify("jupytext: " .. (res.stderr or ""), vim.log.levels.ERROR, { title = "jupytext" })
      end
      vim.bo[buf].modified = false
      vim.cmd.edit { bang = true } -- reopen through jupytext.nvim, now that the notebook exists
    end,
  })
end

---@type LazySpec
return {
  "GCBallesteros/jupytext.nvim",
  -- not lazy: its BufReadCmd handler for *.ipynb has to exist before a notebook is read (it is tiny)
  lazy = false,
  cond = vim.fn.executable "jupytext" == 1,
  opts = {
    style = "hydrogen",
    output_extension = "auto",
  },
  config = function(_, opts)
    require("jupytext.utils").get_ipynb_metadata = notebook_metadata
    require("jupytext").setup(opts)
    -- let the plugin read existing notebooks only; missing ones are handled by `new_notebook`
    for _, au in ipairs(vim.api.nvim_get_autocmds { group = "jupytext-nvim", event = "BufReadCmd" }) do
      local read = au.callback
      vim.api.nvim_del_autocmd(au.id)
      vim.api.nvim_create_autocmd("BufReadCmd", {
        group = "jupytext-nvim",
        pattern = au.pattern,
        desc = "Open notebook through jupytext",
        callback = function(ev)
          if vim.fn.filereadable(ev.match) == 1 then
            read(ev)
          else
            new_notebook(ev)
          end
          -- BufReadCmd replaces the read, so there is no BufReadPost and AstroNvim never sees a "real file" here:
          -- send its `User AstroFile` event itself, which loads the LSP & co. when a notebook is the first file
          -- (re-running BufReadPost instead would re-detect the filetype as json)
          if not vim.b[ev.buf].astrofile_checked then
            vim.b[ev.buf].astrofile_checked = true
            require("astrocore").event "File"
          end
        end,
      })
    end
  end,
}
