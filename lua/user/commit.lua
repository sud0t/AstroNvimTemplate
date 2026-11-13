-- <Leader>Ac: write a commit message for the current changes with the local model.
--   In the editor `git commit` opens (COMMIT_EDITMSG): the message for the whole commit is written straight into
--   the buffer, above git's comment lines. `u` takes it out again; pressing the key again writes another one.
--   Anywhere else: a CodeCompanion chat answers with the message in a code block (`gy` yanks it) and stays open
--   to ask for changes ("shorter", "mention the config change", ...). It describes the staged diff of the
--   repository the current file is in, or everything changed in the working tree when nothing is staged.
-- Both use the same model and instructions (M.model, M.instructions; the chat is the "Commit message" entry in
-- plugins/codecompanion.lua).
local M = {}

-- The right model of the ones installed: reading a diff and summarising it in prose is an instruct task, and
-- qwen3:4b-instruct is the only one that mostly fits on the GPU (the 7b/8b models run at half its speed).
M.model = "qwen3:4b-instruct"

M.instructions = [[
You write git commit messages. You are given the list of changed files, recent commit subjects of the repository and the diff of the whole commit.

Rules:
- The message covers the commit as a whole: say what the change achieves, not what happened in each file. Never write one line per file.
- First line: a summary of at most 60 characters, imperative mood, no trailing period. Follow the style of the recent commit subjects (prefixes, capitalisation); do not add a "feat:"/"fix:" prefix unless they use one.
- Stop after the first line when it says everything. Only when the commit contains several distinct changes, add a blank line and at most four "- " bullets, one per change, each under 72 characters.
- Describe only what the diff shows. Do not invent reasons, do not mention files that did not change.]]

-- What fits the model's 8k context next to the instructions and the answer (~3 characters per token for diffs)
local max_diff_chars = 18000
-- generated files: they are in the summary of changed files, their content only crowds out the real changes
local noise = { ":(exclude)*.lock", ":(exclude)*-lock.json", ":(exclude)*.lock.json", ":(exclude)*.min.js" }

local changes -- what `M.open` found, for the prompt that it starts

local function git(dir, args)
  local res = vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true }):wait()
  return res.code == 0 and vim.trim(res.stdout or "") or nil
end

local function is_commit_buffer(bufnr)
  return vim.bo[bufnr].filetype == "gitcommit" and vim.fs.basename(vim.api.nvim_buf_get_name(bufnr)) == "COMMIT_EDITMSG"
end

--- The lines of a commit buffer before git's comments (the message typed so far) and how many there are.
local function message_lines(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local count = #lines
  for i, line in ipairs(lines) do
    if line:find "^#" then
      count = i - 1
      break
    end
  end
  return vim.list_slice(lines, 1, count), count
end

--- A diff that is too long, cut down so that every file is still in it: small files whole, and the long ones
--- share what is left (cutting the end off instead would leave the last files of the commit out entirely).
local function fit(diff)
  if #diff <= max_diff_chars then return diff, false end
  local files = vim.split("\n" .. diff, "\ndiff --git ", { plain = true })
  table.remove(files, 1)
  local order = {}
  for i in ipairs(files) do
    files[i] = "diff --git " .. files[i]
    order[i] = i
  end
  table.sort(order, function(a, b) return #files[a] < #files[b] end)
  local left = max_diff_chars
  for n, i in ipairs(order) do
    local share = math.floor(left / (#order - n + 1))
    if #files[i] > share then
      files[i] = files[i]:sub(1, share):gsub("\n[^\n]*$", "") .. "\n[... the rest of this file's diff is left out ...]"
    end
    left = math.max(left - #files[i], 0)
  end
  return table.concat(files, "\n"), true
end

--- The changes to describe: { staged, stat, diff, log, truncated }, or nil and the reason there are none.
local function collect()
  local bufnr = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  local dir = vim.bo.buftype == "" and name ~= "" and vim.fs.dirname(name) or vim.fn.getcwd()
  local committing = is_commit_buffer(bufnr)
  -- COMMIT_EDITMSG is inside the git directory, which is not part of the work tree: git started the editor in
  -- the repository (and the git directory of a worktree or submodule is somewhere else entirely)
  if committing then dir = vim.fn.getcwd() end
  if vim.fn.isdirectory(dir) == 0 then dir = vim.fn.getcwd() end
  local root = git(dir, { "rev-parse", "--show-toplevel" })
  if not root and committing and vim.fs.basename(vim.fs.dirname(name)) == ".git" then
    root = git(vim.fs.dirname(vim.fs.dirname(name)), { "rev-parse", "--show-toplevel" })
  end
  if not root then return nil, "Not in a git repository" end

  local base
  if committing then
    -- What is being committed is the index (git points GIT_INDEX_FILE at the right one for `commit -a` and
    -- `commit <paths>`). With --amend the buffer starts with the message of HEAD, and the commit replaces it.
    base = { "diff", "--no-ext-diff", "--staged" }
    local typed = vim.trim(table.concat(message_lines(bufnr), "\n"))
    if typed ~= "" and typed == git(root, { "log", "-1", "--format=%B" }) and git(root, { "rev-parse", "HEAD~1" }) then
      table.insert(base, "HEAD~1")
    end
  else
    local staged = git(root, { "diff", "--staged", "--stat" }) ~= ""
    base = staged and { "diff", "--no-ext-diff", "--staged" } or { "diff", "--no-ext-diff", "HEAD" }
  end
  local staged = base[3] == "--staged"
  local stat = git(root, vim.list_extend(vim.deepcopy(base), { "--stat" }))
  if not stat or stat == "" then
    if committing then return nil, "Nothing is staged for this commit" end
    local untracked = git(root, { "ls-files", "--others", "--exclude-standard" })
    return nil, untracked ~= "" and "Only untracked files: stage them first (git add)" or "No changes to commit"
  end
  local diff, truncated = fit(git(root, vim.list_extend(vim.list_extend(vim.deepcopy(base), { "--" }), noise)) or "")
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
    c.truncated and "The diff (long files are cut short; the file list above is complete):" or "The diff:",
    "`````diff",
    c.diff,
    "`````",
  })
  return table.concat(parts, "\n")
end

--- The message out of the model's answer: without code fences, reasoning or surrounding blank lines.
local function clean(text)
  text = text:gsub("<think>.-</think>", ""):gsub("\r", "")
  local fenced = ("\n" .. text):match "\n```[^\n]*\n(.-)\n```"
  local lines = vim.split(vim.trim(fenced or text), "\n", { plain = true })
  for i, line in ipairs(lines) do
    lines[i] = line:gsub("%s+$", "")
  end
  -- git wants a blank line between the subject and the body
  if lines[2] and lines[2] ~= "" then table.insert(lines, 2, "") end
  return lines
end

local writing = {} -- bufnr -> the request that is running for it

--- Write the message for the commit into its COMMIT_EDITMSG buffer.
local function write(bufnr, found)
  if writing[bufnr] then
    return vim.notify("Already writing a message", vim.log.levels.INFO, { title = "Commit message" })
  end
  local function notify(msg, level) vim.notify(msg, level or vim.log.levels.INFO, { title = "Commit message" }) end
  changes = found
  local request = {
    model = M.model,
    stream = false,
    think = false,
    keep_alive = "5m", -- as the CodeCompanion chat: the two share the loaded model
    options = { num_ctx = 8192, temperature = 0.2, num_predict = 320 },
    messages = {
      {
        role = "system",
        content = M.instructions .. "\n- Reply with the commit message only: no code block, no explanation.",
      },
      { role = "user", content = M.prompt() },
    },
  }
  changes = nil
  notify "Writing the message for this commit..."
  local send
  local function receive(res, retried)
    local ok, data = pcall(vim.json.decode, res.stdout or "")
    if res.code ~= 0 or not ok or type(data) ~= "table" then
      return notify("No answer from Ollama (is it running?)", vim.log.levels.ERROR)
    end
    if data.error then return notify("Ollama: " .. tostring(data.error), vim.log.levels.ERROR) end
    local answer = vim.tbl_get(data, "message", "content") or ""
    local lines = clean(answer)
    if lines[1] == nil or lines[1] == "" then return notify("The model gave no message", vim.log.levels.WARN) end
    -- A commit with many changes tempts the model to list them all in the first line. Ask once for a shorter
    -- one, with the rest of the conversation (the diff is already evaluated, so this takes a few seconds).
    if #lines[1] > 72 and not retried then
      vim.list_extend(request.messages, {
        { role = "assistant", content = answer },
        {
          role = "user",
          content = (
            "The first line is %d characters long. Rewrite the message: a first line of at most 60 "
            .. "characters that names the main change, and the other changes as a few short bullets below it."
          ):format(#lines[1]),
        },
      })
      return send(true)
    end
    if not vim.api.nvim_buf_is_loaded(bufnr) then return end
    -- replaces what is above git's comments: an earlier attempt, or the empty line git starts with
    local _, count = message_lines(bufnr)
    if count < vim.api.nvim_buf_line_count(bufnr) then table.insert(lines, "") end
    vim.api.nvim_buf_set_lines(bufnr, 0, count, false, lines)
    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
    end
    notify(found.truncated and "Done (the diff was long: check that nothing is missing)" or "Done")
  end
  send = function(retried)
    writing[bufnr] = vim.system(
      { "curl", "-s", "--max-time", "300", "http://localhost:11434/api/chat", "-d", "@-" },
      { text = true, stdin = vim.json.encode(request) },
      vim.schedule_wrap(function(res)
        writing[bufnr] = nil
        receive(res, retried)
        if not writing[bufnr] then require("user.ollama").unload_spilled(M.model) end
      end)
    )
  end
  send(false)
end

--- <Leader>Ac
function M.open()
  local bufnr = vim.api.nvim_get_current_buf()
  local found, reason = collect()
  if not found then return vim.notify(reason, vim.log.levels.WARN, { title = "Commit message" }) end
  if is_commit_buffer(bufnr) then return write(bufnr, found) end
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
