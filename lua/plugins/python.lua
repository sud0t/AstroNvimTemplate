-- The python terminal (<Leader>tp) and venv selector (<Leader>lv) are mapped globally by AstroNvim and the
-- python pack; here they exist in Python buffers only, with the <Leader>j group name for Jupyter.
local python_only = { "<Leader>lv", "<Leader>tp" }

---@type LazySpec
return {
  "AstroNvim/astrocore",
  opts = function(_, opts)
    local maps = opts.mappings.n
    local python_maps = { n = { ["<Leader>j"] = { desc = "Jupyter" } } }
    for _, lhs in ipairs(python_only) do
      if maps[lhs] then
        python_maps.n[lhs] = maps[lhs]
        maps[lhs] = false -- `false` drops the global mapping
      end
    end
    opts.autocmds = opts.autocmds or {}
    opts.autocmds.python_mappings = {
      {
        event = "FileType",
        pattern = "python",
        desc = "Python-only <Leader> mappings",
        callback = function(ev) require("astrocore").set_mappings(python_maps, { buffer = ev.buf }) end,
      },
    }
  end,
}
