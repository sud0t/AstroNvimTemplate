-- Emacs-style multiple cursors on multicursor.nvim. <C-v> then <C-j>/<C-k> turns the block into one cursor per
-- line and adds one below/above the furthest. While there are cursors, the same keys add more from normal mode
-- (a count adds that many) and <Esc> clears them. New cursors keep the goal column the way j/k do: a line too
-- short for it gets a cursor just past its end, so the cursors stagger around short lines instead of skipping them.

local saved_ve -- 'virtualedit' from before the cursors existed, nil while there are none

-- Cursors on short lines sit one past the end (where Emacs puts them), so `i` inserts after the last character
local function allow_past_eol()
  if saved_ve then return end
  saved_ve = vim.o.virtualedit
  vim.opt.virtualedit:append "onemore"
  vim.api.nvim_create_autocmd("SafeState", {
    group = vim.api.nvim_create_augroup("multicursor_virtualedit", { clear = true }),
    desc = "Restore 'virtualedit' once the cursors are gone",
    callback = function()
      if require("multicursor-nvim").hasCursors() then return end
      vim.o.virtualedit = saved_ve
      saved_ve = nil
      -- back onto the last character, where normal mode keeps the cursor without onemore
      local len = #vim.api.nvim_get_current_line()
      if vim.fn.mode() == "n" and len > 0 and vim.fn.col "." > len then vim.fn.cursor(0, len) end
      return true -- delete this autocmd
    end,
  })
end

-- Byte column of virtual column `want` (1-based, as in getcurpos()) on line `lnum`, or one past the end of a line
-- too short to reach it
local function goal_col(lnum, want)
  if want >= vim.fn.virtcol { lnum, "$" } then return #vim.fn.getline(lnum) + 1 end
  return vim.fn.virtcol2col(0, lnum, want)
end

local function place(cursor, lnum, want)
  -- setpos() with a curswant keeps the goal column even where the line is shorter
  cursor:perform(function() vim.fn.setpos(".", { 0, lnum, goal_col(lnum, want), 0, want }) end)
end

local function add_cursors(direction)
  local count = vim.v.count1
  local visual = vim.fn.mode():find "^[vV\22]" ~= nil
  local anchor, cur = vim.fn.line "v", vim.fn.getcurpos()
  allow_past_eol()
  require("multicursor-nvim").action(function(ctx)
    if visual then
      -- the selection turns into one cursor per line, all at the cursor's column
      ctx:forEachCursor(function(cursor) cursor:setMode "n" end)
      local main = ctx:mainCursor()
      for lnum = math.min(anchor, cur[2]), math.max(anchor, cur[2]) do
        place(lnum == cur[2] and main or main:clone(), lnum, cur[5])
      end
    end
    for _ = 1, count do
      -- extend past the furthest cursor in that direction (so <C-k> after <C-j> adds above the top one, as in Emacs)
      local edge = direction > 0 and ctx:lastCursor() or ctx:firstCursor()
      local pos
      edge:perform(function() pos = vim.fn.getcurpos() end)
      local lnum = pos[2] + direction
      if lnum < 1 or lnum > vim.fn.line "$" then break end
      local cursor = edge:clone()
      place(cursor, lnum, pos[5])
      cursor:select() -- the real cursor follows the newest one, so the view scrolls along
    end
  end)
end

---@type LazySpec
return {
  "jake-stewart/multicursor.nvim",
  branch = "1.0",
  keys = {
    { "<C-j>", function() add_cursors(1) end, mode = "x", desc = "Add cursor below" },
    { "<C-k>", function() add_cursors(-1) end, mode = "x", desc = "Add cursor above" },
  },
  config = function()
    local mc = require "multicursor-nvim"
    mc.setup()
    -- only mapped while there are cursors, so <C-j>/<C-k> move between splits again afterwards
    mc.addKeymapLayer(function(set)
      set("n", "<C-j>", function() add_cursors(1) end, { desc = "Add cursor below" })
      set("n", "<C-k>", function() add_cursors(-1) end, { desc = "Add cursor above" })
      set("n", "<Esc>", function()
        if mc.cursorsEnabled() then
          mc.clearCursors()
        else
          mc.enableCursors()
        end
      end, { desc = "Clear cursors" })
    end)
  end,
}
