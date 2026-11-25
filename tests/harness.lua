-- What the tests in this directory share. A test loads it first, by a path relative to itself:
--   local harness = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/harness.lua")
-- makes its checks with `ok`, and ends with `report()`, or with `finish()` when its checks run under xpcall.
-- A test that runs inside the whole configuration also calls `whole_config()` before anything else.
-- tests/run.sh has the command lines, and gives such a test directories of its own to write in.
local M = {}

-- The configuration tree this file is in. (Found now: this file is loaded by a path that may be relative, and a
-- test may change the working directory.)
local tree = vim.fs.dirname(vim.fs.dirname(assert(vim.uv.fs_realpath(debug.getinfo(1, "S").source:sub(2)))))

local failures, count = {}, 0

-- No test reaches the system keyring or a provider: `secret-tool` and `curl` are not started, whatever asks for
-- them, and `report()` fails the test in which something did. A test gives the code that asks a stand-in for
-- the answer.
local refused = {}
local system = vim.system
---@diagnostic disable-next-line: duplicate-set-field
vim.system = function(cmd, ...)
  if cmd[1] == "secret-tool" or cmd[1] == "curl" then
    refused[#refused + 1] = ("%s ... %s"):format(cmd[1], tostring(cmd[#cmd]))
    error("a test starts no " .. cmd[1], 0)
  end
  return system(cmd, ...)
end

--- One check: when `cond` is false or nil, the report names it, with `detail` below the name.
function M.ok(name, cond, detail)
  count = count + 1
  if not cond then failures[#failures + 1] = name .. (detail ~= nil and ("\n      " .. tostring(detail)) or "") end
end

--- For a test inside the whole configuration, before anything else. Ends Neovim with 1 when the configuration
--- that runs is not the tree this file is in: the test would pass or fail on another tree's code.
function M.whole_config()
  -- AstroNvim saves "Last Session" and the directory's session into the data directory when Neovim exits.
  -- tests/run.sh gives a test a data directory of its own; a test started without it has the user's, and would
  -- replace the sessions saved there. This comes first because Neovim exits right below.
  require("astrocore").config.sessions.autosave = { last = false, cwd = false }

  local running = vim.uv.fs_realpath(vim.fn.stdpath "config")
  if running ~= tree then
    io.stderr:write(
      ("this test is in %s, but Neovim runs the configuration in %s: use tests/run.sh\n"):format(
        tree,
        tostring(running)
      )
    )
    vim.cmd "cq"
  end
end

--- Ends the test and Neovim: prints "ok: N checks" and exits with 0, or prints the failed checks and exits
--- with 1. A test without a check has not passed: it exits with 1 as well. tests/run.sh takes a test that ends
--- in any other way as failed.
function M.report()
  if #refused > 0 then
    M.ok("the test starts neither secret-tool nor curl", false, table.concat(refused, "\n      "))
  end
  if count == 0 then
    io.stderr:write "the test made no check\n"
    vim.cmd "cq"
  end
  if #failures > 0 then
    io.stderr:write(("%d of %d checks failed:\n"):format(#failures, count))
    for _, failure in ipairs(failures) do
      io.stderr:write("  - " .. failure .. "\n")
    end
    vim.cmd "cq"
  end
  print(("ok: %d checks"):format(count))
  vim.cmd "qa!"
end

--- `report()` for a test whose checks run inside `xpcall(..., debug.traceback)`, with what that returned: an
--- error that ended the checks early is a failed check.
function M.finish(ran, err)
  if not ran then M.ok("the test itself failed:\n" .. tostring(err), false) end
  M.report()
end

return M
