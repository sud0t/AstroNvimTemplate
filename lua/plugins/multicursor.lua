-- Emacs-style multiple cursors on top of multicursor.nvim (`:h multicursor`)
-- <C-v> then <C-j>/<C-k>: the block becomes one cursor per line, plus a new cursor below/above the furthest one
-- (like mc/mark-next-lines and mc/mark-previous-lines). While there are cursors, <C-j>/<C-k> keep adding them from
-- normal mode too (they move between splits otherwise) and <Esc> clears them. A count adds that many lines.
-- New cursors keep the goal column the way j/k do: a line too short for it gets a cursor just past its end, and
-- longer lines after it get the goal column back, so the cursors stagger around short lines instead of skipping them.
-- Whatever is typed in insert mode shows up at every cursor as it's typed (see "Live insert" below).

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

-- Live insert ---------------------------------------------------------------------------------------------------------
-- multicursor.nvim only types at the other cursors once insert mode ends, by repeating the whole insert there with `.`.
-- Here they run the command that starts insert mode along with the main cursor (`o`, `A`, `ciw`, ...), and every change
-- the main cursor makes after that is copied to them as it happens. A change is found by diffing the text around the
-- main cursor, then redone with the same number of characters around each cursor, so it doesn't matter what made it
-- (typing, <BS>, <CR>, autopairs, completion, a paste). Moving the main cursor without typing moves the others along.
-- This reaches into multicursor.nvim's input and cursor managers, so it's tied to the commit in lazy-lock.json.

local api = vim.api
local ns = api.nvim_create_namespace "multicursor_live_insert"
local CAPTURE = "<Plug>(multicursor-live-capture)"
-- Keys that start insert mode, taken over while there are cursors so the other cursors run them before the main one
-- does: run from inside insert mode, a nested `o` truncates its line (the main cursor's autoindent state leaks into it).
-- A count on the ones marked true repeats the insert on <Esc>, which is left to multicursor.nvim.
local KEYS = { i = true, a = true, I = true, A = true, o = true, O = true, s = false, S = false, C = false }

local live -- the insert in progress
local prepared -- the cursors one of KEYS got ready, for the insert mode it's about to start
local captured -- { row, col, line } of where a replayed command left a cursor in insert mode

local function line_at(row) return api.nvim_buf_get_lines(0, row, row + 1, true)[1] end

local function is_cont(byte) return byte ~= nil and byte >= 0x80 and byte < 0xC0 end -- a UTF-8 continuation byte

local function nchars(s) return select(2, s:gsub("[^\128-\191]", "")) end

-- (row, col) moved `n` characters back (n < 0) or forward, a line break counting as one unless `stay` on the line
local function walk(row, col, n, stay)
  local line = line_at(row)
  while n < 0 do
    if col > 0 then
      repeat
        col = col - 1
      until col == 0 or not is_cont(line:byte(col + 1))
    elseif row > 0 and not stay then
      row = row - 1
      line = line_at(row)
      col = #line
    else
      break
    end
    n = n + 1
  end
  while n > 0 do
    if col < #line then
      repeat
        col = col + 1
      until col == #line or not is_cont(line:byte(col + 1))
    elseif row < api.nvim_buf_line_count(0) - 1 and not stay then
      row, col = row + 1, 0
      line = line_at(row)
    else
      break
    end
    n = n - 1
  end
  return row, col
end

-- How `a` with the cursor at byte `ca` became `b` with it at `cb`: the `back` characters before the cursor and `ahead`
-- after it were replaced with `text`, which the cursor is now `at` bytes into. The change is kept around the cursor,
-- so typing a letter next to the same letter is an insert at the cursor rather than one further along.
local function diff(a, ca, b, cb)
  local p, max = 0, math.min(ca, cb)
  while p < max and a:byte(p + 1) == b:byte(p + 1) do
    p = p + 1
  end
  while is_cont(a:byte(p + 1)) do -- not halfway into a character
    p = p - 1
  end
  local s, la, lb = 0, #a, #b
  max = math.min(la - ca, lb - cb)
  while s < max and a:byte(la - s) == b:byte(lb - s) do
    s = s + 1
  end
  while is_cont(a:byte(la - s + 1)) do
    s = s - 1
  end
  return nchars(a:sub(p + 1, ca)), nchars(a:sub(ca + 1, la - s)), b:sub(p + 1, lb - s), cb - p
end

local function text_between(srow, scol, erow, ecol)
  return table.concat(api.nvim_buf_get_text(0, srow, scol, erow, ecol, {}), "\n")
end

local function mark_pos(id)
  local mark = api.nvim_buf_get_extmark_by_id(0, ns, id, {})
  return mark[1], mark[2]
end

-- Draw a cursor the way multicursor.nvim does: over the character it's on, or just past the end of the line
local function draw(c, row, col)
  local line = line_at(row)
  local opts = { id = c.id, priority = 20000, undo_restore = false, strict = false }
  if col < #line then
    opts.hl_group, opts.end_col = "MultiCursorCursor", select(2, walk(row, col, 1, true))
  else
    opts.virt_text, opts.virt_text_pos = { { " ", "MultiCursorCursor" } }, "overlay"
  end
  c.id = api.nvim_buf_set_extmark(0, ns, row, col, opts)
end

-- Remember the text from the line above the main cursor to the line below it, to diff the next change against.
-- The edges are marks, so a change elsewhere (like an LSP adding an import) shifts them instead of showing up.
local function snap()
  local pos = api.nvim_win_get_cursor(0)
  local row, col = pos[1] - 1, pos[2]
  local top, bot = math.max(row - 1, 0), math.min(row + 1, api.nvim_buf_line_count(0) - 1)
  local bot_col = #line_at(bot)
  live.top = api.nvim_buf_set_extmark(0, ns, top, 0, { id = live.top, right_gravity = false })
  live.bot = api.nvim_buf_set_extmark(0, ns, bot, bot_col, { id = live.bot })
  live.text, live.off = text_between(top, 0, bot, bot_col), #text_between(top, 0, row, col)
  live.row, live.col, live.tick = row, col, api.nvim_buf_get_changedtick(0)
end

-- Cursors that ran into each other (or into the main one) would type everything twice from then on, so only the first
-- carries on; the rest still follow the text and get merged into it when insert mode ends
local function settle()
  local pos = api.nvim_win_get_cursor(0)
  local seen, active = { [pos[1] - 1 .. ":" .. pos[2]] = true }, {}
  for _, c in ipairs(live.cursors) do
    local row, col = mark_pos(c.id)
    local key = row .. ":" .. col
    if seen[key] then
      api.nvim_buf_set_extmark(0, ns, row, col, { id = c.id }) -- no longer drawn
    else
      seen[key] = true
      active[#active + 1] = c
    end
  end
  live.cursors = active
end

local function edit(back, ahead, text, at)
  local lines = vim.split(text, "\n", { plain = true })
  local head = vim.split(text:sub(1, at), "\n", { plain = true })
  -- into the undo block of the change being copied, even when it ended with one (nvim-autopairs ends pairs with <Left>)
  pcall(vim.cmd.undojoin)
  for _, c in ipairs(live.cursors) do
    local row, col = mark_pos(c.id)
    local srow, scol = walk(row, col, -back)
    local erow, ecol = walk(row, col, ahead)
    api.nvim_buf_set_text(0, srow, scol, erow, ecol, lines) -- Neovim moves the main cursor along with the text
    c.want = nil
    draw(c, srow + #head - 1, (#head == 1 and scol or 0) + #head[#head])
  end
end

local function move(row, col)
  local rows, chars, edge = row - live.row, 0, nil
  if rows == 0 then
    local line = line_at(row)
    chars = nchars(line:sub(math.min(col, live.col) + 1, math.max(col, live.col)))
    if col < live.col then chars = -chars end
    -- a jump to either end of the line (<Home>, <End>) takes the other cursors to the same end of theirs
    if math.abs(chars) > 1 and (col == 0 or col == #line) then edge = col == 0 and "start" or "end" end
  end
  for _, c in ipairs(live.cursors) do
    local r, cc = mark_pos(c.id)
    if rows == 0 then
      c.want = nil
      if edge then
        cc = edge == "start" and 0 or #line_at(r)
      else
        r, cc = walk(r, cc, chars, true)
      end
    else
      -- up and down keep each cursor's own goal column, like j/k
      c.want = c.want or vim.fn.strdisplaywidth(line_at(r):sub(1, cc)) + 1
      r = math.min(math.max(r + rows, 0), api.nvim_buf_line_count(0) - 1)
      cc = goal_col(r + 1, c.want) - 1
    end
    draw(c, r, cc)
  end
end

-- Copy whatever the main cursor did since the last call to the other cursors. `row`/`col` (0-based) stand in for the
-- main cursor when `leaving` insert mode, where Neovim has already stepped it back.
local function sync(row, col, leaving)
  if api.nvim_get_current_buf() ~= live.buf then return end
  if not row then
    local pos = api.nvim_win_get_cursor(0)
    row, col = pos[1] - 1, pos[2]
  end
  if api.nvim_buf_get_changedtick(0) ~= live.tick then
    local top = api.nvim_buf_get_extmark_by_id(0, ns, live.top, {})
    local bot = api.nvim_buf_get_extmark_by_id(0, ns, live.bot, {})
    if (row > top[1] or row == top[1] and col >= top[2]) and (row < bot[1] or row == bot[1] and col <= bot[2]) then
      local now = text_between(top[1], top[2], bot[1], bot[2])
      local back, ahead, text, at = diff(live.text, live.off, now, #text_between(top[1], top[2], row, col))
      if back > 0 or ahead > 0 or text ~= "" then edit(back, ahead, text, at) end
    end
  elseif leaving or (row == live.row and col == live.col) then
    return
  else
    move(row, col)
  end
  if not leaving then
    settle()
    snap()
  end
end

-- Run `keys` at each other cursor up to where they start insert mode (`:normal` then leaves it), and keep track of
-- where that left them
local function prepare(keys)
  local session = { buf = api.nvim_get_current_buf(), cursors = {}, by = {} }
  keys = keys .. vim.keycode(CAPTURE)
  local ve = vim.o.virtualedit
  vim.opt.virtualedit:append "onemore" -- normal mode would pull a cursor `A` put past the end of the line back onto it
  local cm = require "multicursor-nvim.cursor-manager"
  cm:dirty()
  require("multicursor-nvim.input-manager"):performAction(function()
    cm:action(function(ctx)
      ctx:forEachCursor(function(cursor)
        captured = nil
        cursor:perform(function()
          -- noautocmd: completion, autopairs and the like have no business with these inserts
          vim.cmd { cmd = "normal", args = { keys }, mods = { keepjumps = true, noautocmd = true } }
          if not captured then return end
          local row, col, line = unpack(captured)
          -- leaving insert mode took away the autoindent of a line nothing was typed on yet
          if line_at(row) ~= line then api.nvim_buf_set_lines(0, row, row + 1, true, { line }) end
          api.nvim_win_set_cursor(0, { row + 1, col })
        end)
        if captured then
          local row, col = captured[1], captured[2]
          local c = {
            id = api.nvim_buf_set_extmark(0, ns, row, col, {}),
            start = api.nvim_buf_set_extmark(0, ns, row, col, { right_gravity = false }), -- where the insert began
          }
          session.cursors[#session.cursors + 1] = c
          session.by[cursor] = c
        end
      end)
    end, { excludeMainCursor = true, allowUndo = false, fixWindow = false }) -- fixWindow would feed keys
  end)
  vim.o.virtualedit = ve
  return session
end

local function begin(session)
  if #session.cursors == 0 then return end
  live = session
  -- multicursor.nvim's highlights for the cursors would stay behind as the text moves, these are drawn instead
  local mc_ns = api.nvim_create_namespace "multicursor-nvim"
  for _, mark in ipairs(api.nvim_buf_get_extmarks(0, mc_ns, 0, -1, { details = true })) do
    local hl = mark[4].hl_group
    if hl == "MultiCursorCursor" or hl == "MultiCursorVisual" then api.nvim_buf_del_extmark(0, mc_ns, mark[1]) end
  end
  for _, c in ipairs(session.cursors) do
    draw(c, mark_pos(c.id))
  end
  settle()
  snap()
end

-- Insert mode is over: hand the cursors back to multicursor.nvim where the typing left them
local function finish()
  local session = live
  if api.nvim_get_current_buf() == session.buf then
    -- anything since the last sync, like what was typed before <C-c> (which skips InsertLeavePre)
    if session.tick and api.nvim_buf_get_changedtick(0) ~= session.tick then
      local mark = api.nvim_buf_get_mark(0, "^")
      sync(mark[1] - 1, mark[2], true)
    end
    live = nil
    local cm = require "multicursor-nvim.cursor-manager"
    cm:dirty()
    cm:action(function(ctx)
      ctx:forEachCursor(function(cursor)
        local c = session.by[cursor]
        cursor:perform(function() -- (which also redraws the cursors that never made it into insert mode)
          if not c then return end
          local row, col = mark_pos(c.id)
          row, col = walk(row, col, -1, true) -- like <Esc>, back onto the last character typed
          api.nvim_win_set_cursor(0, { row + 1, col })
          local srow, scol = mark_pos(c.start)
          vim.fn.setpos("'[", { 0, srow + 1, scol + 1, 0 }) -- where `u` puts the cursor
        end)
        -- multicursor.nvim shifts that by how far its own mark of the cursor moved, which here is the typing itself
        if c then cursor._drift = { 0, 0 } end
      end)
    end, { excludeMainCursor = true, allowUndo = false, fixWindow = false })
  end
  live = nil
  api.nvim_buf_clear_namespace(session.buf, ns, 0, -1)
  -- Keys typed faster than multicursor.nvim looks at them (it waits for SafeState) are all replayed at the cursors in
  -- one go. That's the insert's keys too, unless it's told the insert happened, and only keys after it are new.
  local input = require "multicursor-nvim.input-manager"
  input._wasMode, input._keys, input._typed = vim.fn.mode(), "", ""
end

local function usable()
  local mc = require "multicursor-nvim"
  return not require("multicursor-nvim.input-manager")._applying -- not while multicursor.nvim is replaying keys
    and vim.fn.reg_executing() == ""
    and mc.hasCursors()
    and mc.numEnabledCursors() > 1
    and vim.bo.modifiable
end

-- One of KEYS: the other cursors run it first, then the main cursor does (without the mapping)
local function enter(key)
  local count, reg = vim.v.count > 0 and vim.v.count or "", vim.v.register
  if usable() and not (KEYS[key] and count ~= "") and (reg == '"' or reg == "+" or reg == "*") then
    prepared = prepare(count .. vim.keycode("<Plug>(multicursor-live-" .. key .. ")"))
  end
  -- ahead of anything typed after it
  api.nvim_feedkeys((reg ~= '"' and '"' .. reg or "") .. count .. key, "ni", false)
end

local function setup_live_insert()
  vim.keymap.set("i", CAPTURE, function()
    local pos = api.nvim_win_get_cursor(0)
    captured = { pos[1] - 1, pos[2], api.nvim_get_current_line() }
  end)
  for key in pairs(KEYS) do
    vim.keymap.set("n", "<Plug>(multicursor-live-" .. key .. ")", key) -- the built-in key, for `:normal` to run
  end

  local group = api.nvim_create_augroup("multicursor_live_insert", { clear = true })
  api.nvim_create_autocmd("InsertEnter", {
    group = group,
    desc = "Start copying the main cursor's changes to the other cursors",
    callback = function()
      if prepared then
        local session = prepared
        prepared = nil
        return begin(session)
      end
      -- any other way into insert mode (`c` with a motion, `gi`, ...): the main cursor ran its command already, run it at
      -- the others now. Not from visual mode, with a count, or for `.` and macros, which multicursor.nvim replays itself.
      local input = require "multicursor-nvim.input-manager"
      local typed = input._typed
      if
        live
        or vim.v.insertmode ~= "i"
        or vim.v.count > 0
        or input._wasMode ~= "n"
        or typed == ""
        or typed:find "^%d*%.$"
        or not usable()
      then
        return
      end
      local before = api.nvim_win_get_cursor(0)
      local session = prepare(typed)
      -- Insert mode puts the main cursor back where it was before InsertEnter unless v:char is set, but the other
      -- cursors' changes may have moved it (multicursor.nvim keeps it on the same text)
      if not vim.deep_equal(api.nvim_win_get_cursor(0), before) then vim.v.char = " " end
      begin(session)
    end,
  })
  api.nvim_create_autocmd({ "CursorMovedI", "TextChangedI", "TextChangedP", "InsertLeavePre" }, {
    group = group,
    desc = "Copy the main cursor's changes to the other cursors",
    callback = function()
      if live then sync() end
    end,
  })
  api.nvim_create_autocmd("ModeChanged", {
    group = group,
    pattern = "i*:*",
    desc = "Hand the cursors back to multicursor.nvim",
    callback = function()
      -- not for completion modes or <C-o>, which comes back to the same insert
      if live and not vim.v.event.new_mode:find "^n?i" then
        require("multicursor-nvim.input-manager"):performAction(finish)
      end
    end,
  })
  api.nvim_create_autocmd("SafeState", {
    group = group,
    desc = "Hand over cursors whose insert mode ended unnoticed",
    callback = function()
      if vim.fn.mode() ~= "n" then return end
      if prepared then -- the main cursor never made it into insert mode
        live, prepared = prepared, nil
      end
      if live then require("multicursor-nvim.input-manager"):performAction(finish) end
    end,
  })

  local input = require "multicursor-nvim.input-manager"
  local exit_insert = input._handleExitInsertMode
  function input:_handleExitInsertMode(...)
    if not live then return exit_insert(self, ...) end -- (it's still on during <C-o>)
  end
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
    setup_live_insert()
    -- only mapped while there are cursors, so <C-j>/<C-k> move between splits again afterwards
    mc.addKeymapLayer(function(set)
      set("n", "<C-j>", function() add_cursors(1) end, { desc = "Add cursor below" })
      set("n", "<C-k>", function() add_cursors(-1) end, { desc = "Add cursor above" })
      for key in pairs(KEYS) do
        set("n", key, function() enter(key) end, { desc = "Insert at every cursor" })
      end
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
