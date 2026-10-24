-- Python-only <Leader> mappings. AstroNvim and the astrocommunity python pack map the python terminal
-- (<Leader>tp) and the venv selector (<Leader>lv) globally, so which-key listed them in every buffer. They are
-- moved to buffer-local mappings in Python buffers here. The Jupyter keys (plugins/jupyter.lua) are buffer-local
-- the same way through lazy.nvim's `ft`; this only names their <Leader>j group.
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
