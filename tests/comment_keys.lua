-- Commenting inside the whole configuration: <Leader>/ is the only comment key. lua/polish.lua moves Neovim's
-- default gc/gcc mappings to <Plug> names and lua/plugins/astrocore.lua points <Leader>/ at those.
--   tests/run.sh comment_keys
-- Run it after changing either file and after a Neovim update: the move depends on Neovim's default mappings.

local harness = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/harness.lua")
harness.whole_config()
local ok = harness.ok

local function press(keys) vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false) end
local function lines() return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "|") end

local run, err = xpcall(function()
  for _, map in ipairs { { "n", "gc" }, { "x", "gc" }, { "o", "gc" }, { "n", "gcc" }, { "n", "gco" }, { "n", "gcO" } } do
    local mode, lhs = map[1], map[2]
    ok(("%s is unmapped in mode %s"):format(lhs, mode), vim.fn.maparg(lhs, mode) == "", vim.fn.maparg(lhs, mode))
  end

  vim.cmd "enew"
  vim.bo.filetype = "lua"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local a = 1", "local b = 2", "local c = 3" })

  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  press "<Leader>/"
  ok("<Leader>/ comments the line", lines() == "-- local a = 1|local b = 2|local c = 3", lines())
  press "<Leader>/"
  ok("<Leader>/ again uncomments it", lines() == "local a = 1|local b = 2|local c = 3", lines())

  press "2<Leader>/"
  ok("a count comments that many lines", lines() == "-- local a = 1|-- local b = 2|local c = 3", lines())
  press "."
  ok("the dot repeats it", lines() == "local a = 1|local b = 2|local c = 3", lines())

  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  press "Vj<Leader>/"
  ok("<Leader>/ comments a selection", lines() == "local a = 1|-- local b = 2|-- local c = 3", lines())

  ok("nothing reported an error", vim.v.errmsg == "", vim.v.errmsg)
end, debug.traceback)

harness.finish(run, err)
