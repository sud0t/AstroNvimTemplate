-- Approving the project's rules (.nvim-ai.md), from <Leader>AS. A repository can bring that file along and a
-- chat obeys it, so chats only get the text the owner approved: by saving it from the buffer `edit` opens, or
-- by reading it in the window of `review`. The sandbox (`user.ai.sandbox`) keeps the record of what was approved.
local M = {}

local windows = require "user.ai.windows"

local notify, short = windows.notify, windows.short

--- The sha256 of what writing `bufnr` puts on disk (two, where it is one of them), or nil when that cannot be
--- told here (an encoding other than UTF-8).
local function written(bufnr)
  local bo = vim.bo[bufnr]
  if bo.fileencoding ~= "" and bo.fileencoding ~= "utf-8" then return nil end
  local eol = ({ unix = "\n", dos = "\r\n", mac = "\r" })[bo.fileformat]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines, eol)
  if bo.endofline or (bo.fixendofline and not bo.binary) then text = text .. eol end
  local bom = bo.bomb and "\239\187\191" or ""
  local hashes = { vim.fn.sha256(bom .. text) }
  -- (a buffer without a line is written as an empty file, and looks like one with an empty line)
  if #lines == 1 and lines[1] == "" then hashes[2] = vim.fn.sha256(bom) end
  return hashes
end

--- Open the project's rules file. Saving from this buffer approves what was saved: the chat's tools cannot
--- save it. Once the buffer is loaded again from a file that changed on disk (a command of the chat, `git
--- checkout`), it shows text nobody approved: saving stops approving, and the file waits in <Leader>AS.
function M.edit(path)
  local problem = require("user.ai.sandbox").rules_problem(path)
  if problem then
    return notify(("%s is not opened as the project's rules: %s."):format(short(path), problem), vim.log.levels.WARN)
  end
  local note = "New file: what is in it goes along with every chat opened in this directory, with any provider."
  -- (the file's own modeline could fold lines away or stop them from wrapping, and what is saved is approved)
  local modeline = vim.go.modeline
  vim.go.modeline = false
  local opened = windows.edit(path, note)
  vim.go.modeline = modeline
  if not opened then return end
  for option, value in pairs { wrap = true, conceallevel = 0, foldenable = false } do
    vim.wo[0][0][option] = value
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local group = vim.api.nvim_create_augroup("ai_project_rules_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "FileChangedShellPost" }, {
    buffer = bufnr,
    group = group,
    desc = "Stop approving the project's AI rules on save once they changed on disk",
    callback = function()
      if require("user.ai.sandbox").rules_state(path) ~= "unapproved" then return end
      vim.api.nvim_clear_autocmds { group = group }
      notify(
        ("%s changed on disk: chats do not get it until you have read and approved it (<Leader>AS, Project rules)."):format(
          short(path)
        ),
        vim.log.levels.WARN
      )
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    buffer = bufnr,
    group = group,
    desc = "Approve the project's AI rules as they were just saved",
    callback = function(args)
      -- (`:w other-name` from this buffer is not the rules file)
      local saved = vim.uv.fs_realpath(args.match)
      if not saved or saved ~= vim.uv.fs_realpath(path) then return end
      -- what is approved is this buffer's text: not what something else made of the file in the same moment
      local shown = written(args.buf)
      local ok, err = false, "its encoding is not UTF-8: approve it in <Leader>AS, Project rules"
      if shown then
        ok, err = require("user.ai.sandbox").approve_rules(path, shown)
      end
      if not ok then notify("The project rules were saved but not approved: " .. err, vim.log.levels.WARN) end
    end,
  })
end

--- Show the project's rules exactly as on disk (a scratch buffer: no modeline, folds or conceal; blanks are
--- marked). `a` approves the text shown, once every line has been on screen in full and after a question
--- (`a` is pressed by habit); `q` closes. `back()` after either.
function M.review(path, back)
  local sandbox = require "user.ai.sandbox"
  local text, hash = sandbox.read_rules(path)
  if not text then
    notify(("%s is not approved: %s."):format(short(path), hash), vim.log.levels.WARN)
    return back()
  end
  local lines = vim.split(text, "\n", { plain = true })
  if #lines > 1 and lines[#lines] == "" then table.remove(lines) end
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].bufhidden = "wipe"
  vim.cmd "botright split"
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, bufnr)
  local bar = ("%s as it is on disk, %d line%s    a: approve it (once all of it was on screen)    q: close"):format(
    short(path),
    #lines,
    #lines == 1 and "" or "s"
  )
  for option, value in pairs {
    wrap = true,
    list = true,
    number = true,
    conceallevel = 0,
    foldenable = false,
    smoothscroll = true, -- (a line that is longer than the window is scrolled through, not over)
    winbar = bar:gsub("%%", "%%%%"),
  } do
    vim.wo[win][0][option] = value
  end
  -- What is approved has been on screen, all of it: empty lines keep text off the first screen, a jump to
  -- the end off the last. A line counts once its first and its last character were on screen at one time:
  -- moving down a line that is longer than the window shows its start and its end, never the middle.
  local seen, unseen = {}, #lines
  local function look()
    if not vim.api.nvim_win_is_valid(win) then return end
    for row = math.max(vim.fn.line("w0", win), 1), math.min(vim.fn.line("w$", win) + 1, #lines) do
      if
        not seen[row]
        and vim.fn.screenpos(win, row, 1).row > 0
        and vim.fn.screenpos(win, row, math.max(#lines[row], 1)).row > 0
      then
        seen[row], unseen = true, unseen - 1
      end
    end
  end
  local group = vim.api.nvim_create_augroup("ai_project_rules_review_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", { group = group, buffer = bufnr, callback = look })
  vim.api.nvim_create_autocmd("WinScrolled", { group = group, pattern = tostring(win), callback = look })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    once = true,
    callback = function() pcall(vim.api.nvim_del_augroup_by_id, group) end,
  })
  local function close()
    if not vim.api.nvim_win_is_valid(win) then return end
    -- (the last window of a tab page cannot be closed: it gets an empty buffer)
    if not pcall(vim.api.nvim_win_close, win, true) then pcall(vim.cmd.enew) end
  end
  vim.keymap.set("n", "q", function()
    close()
    back()
  end, { buffer = bufnr, nowait = true, desc = "Close without approving" })
  vim.keymap.set("n", "a", function()
    -- (where the window is, is only settled when it is drawn)
    pcall(vim.cmd.redraw)
    look()
    if unseen > 0 then
      local first = 1
      while seen[first] do
        first = first + 1
      end
      return notify(
        (
          "Not approved yet: %d of its %d lines have not been on screen in full (the first: line %d). Scroll "
          .. "through all of it; a line that is longer than the window needs a larger window."
        ):format(unseen, #lines, first),
        vim.log.levels.WARN
      )
    end
    windows.options(
      "Project rules, read to the end",
      { { "Approve these rules: chats in this directory get them", true }, { "Not yet", false } },
      2,
      function(approved)
        if not approved then return end
        local ok, err = sandbox.approve_rules(path, hash)
        notify(
          ok and ("Approved: chats opened in this directory get " .. short(path) .. ".") or ("Not approved: " .. err),
          ok and vim.log.levels.INFO or vim.log.levels.ERROR
        )
        close()
        back()
      end
    )
  end, { buffer = bufnr, nowait = true, desc = "Approve the project's AI rules as shown here" })
end

return M
