-- A float that takes the focus of the windows it covers while it is open: the cursor of a window behind a float
-- is drawn on the float, as if what is typed went there. The message window of a commit is such a float
-- (user/git_commit.lua). A move into a covered window ends in the float; a move out of the float ends in the
-- window used last outside of it, never in one behind it. The file tree and other floats take the focus as always.
local M = {}

--- The screen cells of a window, its border included: top, left, bottom and right, the last two exclusive.
---@param win integer
---@return integer top, integer left, integer bottom, integer right
local function cells(win)
  local top, left = unpack(vim.api.nvim_win_get_position(win))
  local height, width = vim.api.nvim_win_get_height(win), vim.api.nvim_win_get_width(win)
  local border = vim.api.nvim_win_get_config(win).border
  if border and border ~= "none" then
    height, width = height + 2, width + 2
  end
  return top, left, top + height, left + width
end

---@param win integer
local function is_float(win) return vim.api.nvim_win_get_config(win).relative ~= "" end

--- The file tree is never behind a float: a commit is staged with the tree's keys, and a wide float covers part of it.
---@param win integer
local function is_file_tree(win) return vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "neo-tree" end

--- Makes `previous` the window that <C-w>p, <C-w>h and its like, and the closing of a float lead to from the
--- current window, which stays the current one. No autocommand sees the way there and back.
---@param previous integer
local function set_previous_window(previous)
  local current = vim.api.nvim_get_current_win()
  vim.cmd(("noautocmd call win_gotoid(%d) | noautocmd call win_gotoid(%d)"):format(previous, current))
end

--- Gives `float`, which is the current window, the focus of the windows it covers until it is closed.
---@param float integer
function M.take_priority(float)
  local tabpage = vim.api.nvim_win_get_tabpage(float)

  ---@param win integer
  local function behind(win)
    local elsewhere = vim.api.nvim_win_get_tabpage(win) ~= tabpage
    if win == float or is_float(win) or is_file_tree(win) or elsewhere then return false end
    local top, left, bottom, right = cells(win)
    local float_top, float_left, float_bottom, float_right = cells(float)
    return top < float_bottom and float_top < bottom and left < float_right and float_left < right
  end

  local function previous_window() return vim.fn.win_getid(vim.fn.winnr "#") end
  ---@param win integer
  local function is_outside(win) return win ~= 0 and win ~= float and not is_float(win) and not behind(win) end

  local rested = float -- where the last command left the focus
  local outside = is_outside(previous_window()) and previous_window() or nil -- and the last such window outside

  local function settle()
    -- Neovim lets nothing leave its command-line window (q:), which opens over the float on a short screen
    if not vim.api.nvim_win_is_valid(float) or vim.fn.getcmdwintype() ~= "" then return end
    if behind(vim.api.nvim_get_current_win()) then
      -- smart-splits moves from a float by way of its previous window: a move that left the float, and went on
      -- from the window outside into one behind the float, ends outside
      local left_float = rested == float and previous_window() ~= float
      if left_float and outside and vim.api.nvim_win_is_valid(outside) then
        vim.api.nvim_set_current_win(outside)
      else
        vim.api.nvim_set_current_win(float)
        if outside and vim.api.nvim_win_is_valid(outside) then set_previous_window(outside) end
      end
    end
    rested = vim.api.nvim_get_current_win()
    if is_outside(rested) then outside = rested end
  end

  local group = vim.api.nvim_create_augroup("user.float_focus." .. float, { clear = true })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    -- once the command that moved the focus has ended: smart-splits and a closing picker pass through windows
    callback = function() vim.schedule(settle) end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(float),
    callback = function() vim.api.nvim_del_augroup_by_id(group) end,
  })
end

return M
