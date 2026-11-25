-- What the AI windows (<Leader>As, <Leader>AS) share: the picker each of them is and, for the settings windows,
-- their notes, their name for a file and how they open one for editing.
local M = {}

--- vim.ui.select with the cursor on `row` (snacks, AstroNvim's picker, starts on the first row; other
--- pickers ignore the extra option)
function M.choose(items, opts, row, on_choice)
  if row and row > 1 then
    opts.snacks = {
      on_show = function(picker)
        pcall(function() picker.list:view(row) end)
      end,
    }
  end
  vim.ui.select(items, opts, on_choice)
end

--- `choose` for a `list` of { label, value }: `on_value(value)`, with nil when the window was left with <Esc>.
function M.options(prompt, list, row, on_value)
  M.choose(
    list,
    { prompt = prompt, format_item = function(option) return option[1] end },
    row,
    function(option) on_value(option and option[2]) end
  )
end

--- A note of the settings windows. (The provider window's notes have a title of their own.)
function M.notify(msg, level) vim.notify(msg, level or vim.log.levels.INFO, { title = "AI settings" }) end

--- `path` as the settings windows name it.
function M.short(path) return vim.fn.fnamemodify(path, ":~") end

--- Open `path` for editing; `note` is shown when the file does not exist yet. Returns whether it is open.
function M.edit(path, note)
  local ok, err = pcall(function()
    if vim.bo.buftype ~= "" then
      -- not over a chat (Claude Code's is a terminal, CodeCompanion's has no file): in a window of this tab
      -- that shows a file, or a new one
      local other = vim.iter(vim.api.nvim_tabpage_list_wins(0)):find(
        function(win)
          return vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "" and vim.api.nvim_win_get_config(win).relative == ""
        end
      )
      if other then
        vim.api.nvim_set_current_win(other)
      else
        vim.cmd "topleft vnew"
      end
    end
    vim.cmd.edit(vim.fn.fnameescape(path))
  end)
  if not ok then
    M.notify(("Could not open %s: %s"):format(M.short(path), err), vim.log.levels.ERROR)
    return false
  end
  if note and vim.fn.filereadable(path) == 0 then M.notify(note) end
  return true
end

return M
