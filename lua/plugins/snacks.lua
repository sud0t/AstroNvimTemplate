---@type LazySpec
return {
  "folke/snacks.nvim",
  opts = function(_, opts)
    local preset = opts.dashboard.preset
    preset.header = table.concat({
      "███    ██ ██    ██ ██ ███    ███",
      "████   ██ ██    ██ ██ ████  ████",
      "██ ██  ██ ██    ██ ██ ██ ████ ██",
      "██  ██ ██  ██  ██  ██ ██  ██  ██",
      "██   ████   ████   ██ ██      ██",
    }, "\n")
    -- AstroNvim's New File entry presses <Leader>n, which is unmapped here (plugins/astrocore.lua)
    for _, entry in ipairs(preset.keys) do
      if entry.action == "<Leader>n" then entry.action = ":enew" end
    end
  end,
}
