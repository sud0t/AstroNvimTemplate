-- <Leader>Ac: write a commit message for the current changes with CodeCompanion.
-- Takes the staged diff of the repository the current file is in (everything changed in the working tree when
-- nothing is staged), and opens a chat that answers with the message in a code block: `gy` in the chat yanks it,
-- and the chat stays open to ask for changes ("shorter", "mention the config change", ...).
-- The prompt itself (model, instructions) is the "Commit message" entry in plugins/codecompanion.lua.
local M = {}

-- What fits the model's 8k context next to the instructions and the answer (~3 characters per token for diffs)
local max_diff_chars = 18000
-- generated files: they are in the summary of changed files, their content only crowds out the real changes
local noise = { ":(exclude)*.lock", ":(exclude)*-lock.json", ":(exclude)*.lock.json", ":(exclude)*.min.js" }

local changes -- what `M.open` found, for the prompt that it starts

local function git(dir, args)
  local res = vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true }):wait()
  return res.code == 0 and vim.trim(res.stdout or "") or nil
end

--- The changes to describe: { staged, stat, diff, log, truncated }, or nil and the reason there are none.
local function collect()
  local name = vim.api.nvim_buf_get_name(0)
  local dir = vim.bo.buftype == "" and name ~= "" and vim.fs.dirname(name) or vim.fn.getcwd()
  if vim.fn.isdirectory(dir) == 0 then dir = vim.fn.getcwd() end
  local root = git(dir, { "rev-parse", "--show-toplevel" })
  if not root then return nil, "Not in a git repository" end

  local staged = git(root, { "diff", "--staged", "--stat" }) ~= ""
  local base = staged and { "diff", "--no-ext-diff", "--staged" } or { "diff", "--no-ext-diff", "HEAD" }
  local stat = git(root, vim.list_extend(vim.deepcopy(base), { "--stat" }))
  if not stat or stat == "" then
    local untracked = git(root, { "ls-files", "--others", "--exclude-standard" })
    return nil, untracked ~= "" and "Only untracked files: stage them first (git add)" or "No changes to commit"
  end
  local diff = git(root, vim.list_extend(vim.list_extend(vim.deepcopy(base), { "--" }), noise)) or ""
  local truncated = #diff > max_diff_chars
  if truncated then diff = diff:sub(1, max_diff_chars):gsub("\n[^\n]*$", "") end
  return {
    staged = staged,
    stat = stat,
    diff = diff,
    truncated = truncated,
    log = git(root, { "log", "-8", "--format=%s" }) or "",
  }
end

--- The user message of the prompt.
function M.prompt()
  local c = changes or collect()
  if not c then return "There are no changes to commit; say so." end
  local parts = {
    "Write the commit message for these changes.",
    "",
    "Changed files:",
    "```",
    c.stat,
    "```",
  }
  if c.log ~= "" then
    vim.list_extend(parts, { "", "Recent commit subjects in this repository, for the style:", "```", c.log, "```" })
  end
  vim.list_extend(parts, {
    "",
    c.truncated and "The diff (cut off, it is too long to show whole; the file list above is complete):" or "The diff:",
    "`````diff",
    c.diff,
    "`````",
  })
  return table.concat(parts, "\n")
end

--- <Leader>Ac
function M.open()
  local found, reason = collect()
  if not found then return vim.notify(reason, vim.log.levels.WARN, { title = "Commit message" }) end
  if not found.staged then
    vim.notify("Nothing is staged: describing all changes in the working tree", vim.log.levels.INFO, {
      title = "Commit message",
    })
  end
  changes = found
  local ok, err = pcall(function() require("codecompanion").prompt "commitmsg" end)
  changes = nil
  if not ok then error(err, 0) end
end

return M
