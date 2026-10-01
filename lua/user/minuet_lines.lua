-- Step through a minuet ghost-text suggestion line by line:
--   accept()  inserts the next line of the suggestion (like minuet's accept_line) and remembers it
--   undo()    removes the last line inserted that way and shows the suggestion again from that point
-- minuet keeps its suggestion state private, so it is reached through upvalues of its public actions.
local M = {}

local api = vim.api
local history = {} -- per buffer: stack of { start, finish, text, suggestion }

local function upvalue(fn, name)
  for i = 1, math.huge do
    local n, v = debug.getupvalue(fn, i)
    if not n then return nil end
    if n == name then return v end
  end
end

-- minuet internals: get_ctx(bufnr) -> { suggestions, choice, shown_choices, last_pos } and update_preview(ctx)
local function internals()
  local action = require("minuet.virtualtext").action
  local get_ctx = upvalue(action.accept, "get_ctx")
  local advance = upvalue(action.next, "advance")
  local update_preview = advance and upvalue(advance, "update_preview")
  if get_ctx and update_preview then return get_ctx, update_preview end
end

local function current_suggestion()
  local get_ctx = internals()
  local ctx = get_ctx and get_ctx()
  return ctx and ctx.suggestions and ctx.choice and ctx.suggestions[ctx.choice]
end

function M.accept()
  local vt = require "minuet.virtualtext"
  if not vt.action.is_visible() then return end
  local buf = api.nvim_get_current_buf()
  local suggestion = current_suggestion()
  local start = api.nvim_win_get_cursor(0)
  vt.action.accept_line()
  -- minuet inserts the text in a scheduled callback; record what it inserted right after it
  vim.schedule(function()
    if not suggestion or api.nvim_get_current_buf() ~= buf then return end
    local finish = api.nvim_win_get_cursor(0)
    local text = api.nvim_buf_get_text(buf, start[1] - 1, start[2], finish[1] - 1, finish[2], {})
    history[buf] = history[buf] or {}
    table.insert(history[buf], { start = start, finish = finish, text = text, suggestion = suggestion })
  end)
end

function M.undo()
  local buf = api.nvim_get_current_buf()
  local stack = history[buf]
  local entry = stack and table.remove(stack)
  if not entry then return end
  local s, f = entry.start, entry.finish
  -- only undo if the inserted text is untouched and the cursor is still right after it
  local cursor = api.nvim_win_get_cursor(0)
  local ok, text = pcall(api.nvim_buf_get_text, buf, s[1] - 1, s[2], f[1] - 1, f[2], {})
  if not (ok and cursor[1] == f[1] and cursor[2] == f[2] and vim.deep_equal(text, entry.text)) then
    history[buf] = nil
    return
  end

  -- keep minuet from discarding the restored suggestion and requesting a new one on this cursor move
  local auto = vim.b[buf].minuet_virtual_text_auto_trigger
  vim.b[buf].minuet_virtual_text_auto_trigger = false
  api.nvim_buf_set_text(buf, s[1] - 1, s[2], f[1] - 1, f[2], { "" })
  api.nvim_win_set_cursor(0, s)

  local get_ctx, update_preview = internals()
  if get_ctx then
    local ctx = get_ctx(buf)
    ctx.suggestions, ctx.choice = { entry.suggestion }, 1
    ctx.shown_choices = {}
    update_preview(ctx)
    ctx.shown_choices = {} -- an empty table tells minuet the cursor move below is not "typing past" it
  end
  vim.defer_fn(function()
    if api.nvim_buf_is_valid(buf) then vim.b[buf].minuet_virtual_text_auto_trigger = auto end
  end, 50)
end

api.nvim_create_autocmd({ "InsertLeave", "BufDelete" }, {
  group = api.nvim_create_augroup("minuet_lines", { clear = true }),
  desc = "Forget accepted minuet lines",
  callback = function(args) history[args.buf] = nil end,
})

return M
