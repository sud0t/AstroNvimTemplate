-- The test keys inside the whole configuration: a <Leader>T key that starts a run or a watch also opens neotest's
-- summary, and still runs what the neotest pack mapped to it (lua/plugins/neotest.lua).
--   tests/run.sh neotest_keys
-- Run it after changing that file and after an update of AstroCommunity or neotest: the keys are the pack's, the
-- summary and its window are neotest's. The functions of neotest that the keys call are stand-ins here, so no test
-- process starts: a run with a real adapter is left to check by hand.

local harness = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/harness.lua")
harness.whole_config()
local ok = harness.ok

local run_keys = { "t", "d", "f", "p", "Wt", "Wf", "Wp" }
-- The pack's other <Leader>T keys, which start no run. A key the pack adds is in neither list, and fails the test
-- until someone has put it in one: a new run key would otherwise open no summary without a check saying so.
local other_keys = { "<CR>", "o", "O", "WS" }

local function press(keys) vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false) end

local function summary_windows()
  return vim.tbl_filter(
    function(win) return vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "neotest-summary" end,
    vim.api.nvim_tabpage_list_wins(0)
  )
end
--- `<Leader>T<CR>` toggles in a task of neotest's, so the window is waited for.
local function summary_becomes(count)
  return vim.wait(5000, function() return #summary_windows() == count end, 20)
end

--- The normal-mode mappings as the pack alone makes them, before lua/plugins/neotest.lua wraps them
local function pack_mappings()
  local opts = { mappings = { n = {} } }
  for _, dependency in ipairs(require("astrocommunity.test.neotest").dependencies) do
    if dependency[1] == "AstroNvim/astrocore" then dependency.opts(nil, opts) end
  end
  return opts.mappings.n
end

local dir = vim.fn.tempname()
local started_in = vim.fn.getcwd()
local run, err = xpcall(function()
  vim.fn.mkdir(dir)
  vim.fn.writefile({ "one", "two", "three" }, dir .. "/a.txt")
  vim.cmd.cd(dir)
  vim.cmd.edit "a.txt"
  vim.api.nvim_win_set_cursor(0, { 2, 1 })
  local code_window = vim.api.nvim_get_current_win()

  local neotest = require "neotest"
  local calls
  local function stand_in(name)
    return function(...) calls[#calls + 1] = { name, ... } end
  end
  neotest.run.run = stand_in "run.run"
  neotest.watch.toggle = stand_in "watch.toggle"
  neotest.output.open = stand_in "output.open"

  local pack = pack_mappings()
  local unsorted = {}
  for lhs, map in pairs(pack) do
    local key = lhs:match "^<Leader>T(.+)$"
    local known = vim.list_contains(run_keys, key) or vim.list_contains(other_keys, key)
    if key and type(map) == "table" and type(map[1]) == "function" and not known then unsorted[#unsorted + 1] = lhs end
  end
  table.sort(unsorted)
  ok(
    "every <Leader>T key of the pack is known as one that starts a run or as one that does not",
    #unsorted == 0,
    table.concat(unsorted, " ")
  )

  for _, key in ipairs(run_keys) do
    local lhs = "<Leader>T" .. key
    calls = {}
    pack[lhs][1]()
    local expected = calls

    calls = {}
    press(lhs)
    ok(
      lhs .. " calls neotest once, as the pack's mapping does",
      #calls == 1 and vim.deep_equal(calls, expected),
      vim.inspect { called = calls, expected = expected }
    )
    ok(lhs .. " opens the summary", #summary_windows() == 1, #summary_windows())
    ok("and leaves the focus in the code", vim.api.nvim_get_current_win() == code_window)
    local cursor = vim.api.nvim_win_get_cursor(code_window)
    ok("and the cursor where it was", vim.deep_equal(cursor, { 2, 1 }), vim.inspect(cursor))

    press(lhs)
    ok(lhs .. " leaves one summary when it is open", #summary_windows() == 1, #summary_windows())
    neotest.summary.close()
  end

  press "<Leader>T<CR>"
  ok("<Leader>T<CR> opens the summary", summary_becomes(1))
  press "<Leader>T<CR>"
  ok("<Leader>T<CR> again closes it", summary_becomes(0))

  calls = {}
  press "<Leader>To"
  ok("<Leader>To shows the output", #calls == 1 and calls[1][1] == "output.open", vim.inspect(calls))
  ok("and opens no summary", #summary_windows() == 0)

  ok("nothing reported an error", vim.v.errmsg == "", vim.v.errmsg)
end, debug.traceback)

vim.cmd.cd(started_in)
vim.fn.delete(dir, "rf")
harness.finish(run, err)
