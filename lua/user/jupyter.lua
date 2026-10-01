-- Minimal `# %%` cell runner on top of molten-nvim (used by the <leader>J / <leader>j keymaps in plugins/jupyter.lua).
-- A cell is everything between two `# %%` lines; code above the first marker is the first cell.
local jupyter = {}

local function is_marker(line)
  return vim.trim(line:sub(1, 5)) == "# %%" -- "# %%", "# %% Title", "# %% [md]"; not magics like "# %%timeit"
end

local function is_markdown(marker_line)
  return vim.startswith(marker_line, "# %% [md") or vim.startswith(marker_line, "# %% [markdown")
end

--- Code range (1-based, inclusive) of the cell containing `row`; nil if it is empty or a markdown cell.
local function cell_range(lines, row)
  local first, marker = 1, nil
  for i = row, 1, -1 do
    if is_marker(lines[i]) then
      first, marker = i + 1, lines[i]
      break
    end
  end
  local last = #lines
  for i = row + 1, #lines do
    if is_marker(lines[i]) then
      last = i - 1
      break
    end
  end
  while last >= first and lines[last]:match "^%s*$" do
    last = last - 1
  end -- output sits right under the code
  if last < first or (marker and is_markdown(marker)) then return nil end
  return first, last
end

-- With no kernel yet, molten itself asks which one to start and then runs the cell.
local function run_range(first, last)
  local ok, err = pcall(vim.fn.MoltenEvaluateRange, first, last)
  if not ok then vim.notify("Jupyter: " .. tostring(err), vim.log.levels.ERROR) end
  return ok
end

--- Jump to the next (dir = 1) or previous (dir = -1) `# %%` line. Returns false if there is none.
function jupyter.jump(dir, onto_code)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  for i = row + dir, dir > 0 and #lines or 1, dir do
    if is_marker(lines[i]) then
      vim.api.nvim_win_set_cursor(0, { math.min(i + (onto_code and 1 or 0), #lines), 0 })
      return true
    end
  end
  return false
end

function jupyter.run_cell(move_on)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local first, last = cell_range(lines, vim.api.nvim_win_get_cursor(0)[1])
  if first then
    if not run_range(first, last) then return end
  else
    vim.notify "Jupyter: nothing to run in this cell"
  end
  if move_on then jupyter.jump(1, true) end
end

function jupyter.run_all()
  if #vim.fn.MoltenRunningKernels(true) == 0 then
    vim.notify("Jupyter: no kernel in this buffer yet. Run a cell with <leader>J first.", vim.log.levels.WARN)
    return
  end
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local row = 1
  while row <= #lines do
    local first, last = cell_range(lines, row)
    if first and not run_range(first, last) then return end
    local next_marker
    for i = row + 1, #lines do
      if is_marker(lines[i]) then
        next_marker = i
        break
      end
    end
    if not next_marker then break end
    row = next_marker
  end
end

--- Shut down the kernel(s) of this buffer and clear their outputs: back to a plain Python file.
function jupyter.stop()
  if #vim.fn.MoltenRunningKernels(true) == 0 then
    vim.notify "Jupyter: no kernel running in this buffer"
    return
  end
  vim.cmd "MoltenDeinit"
  vim.notify "Jupyter: kernel stopped"
end

--- Stop the cell that is running (keyboard interrupt); the kernel and its variables stay.
function jupyter.interrupt()
  if #vim.fn.MoltenRunningKernels(true) == 0 then
    vim.notify "Jupyter: no kernel running in this buffer"
    return
  end
  vim.cmd "MoltenInterrupt"
end

return jupyter
