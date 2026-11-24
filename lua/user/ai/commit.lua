-- <Leader>Ac: write a commit message for the current changes, with the AI chosen with <Leader>As (the local
-- model, Claude or another provider's model).
--   In the editor `git commit` opens (COMMIT_EDITMSG): the message for the whole commit is written straight into
--   the buffer as the model writes it, above git's comment lines. `u` takes it out again; pressing the key
--   again writes another one (or cancels the one being written).
--   Anywhere else: a CodeCompanion chat answers with the message in a code block (`gy` yanks it) and stays open
--   to ask for changes ("shorter", "mention the config change", ...). It describes the staged diff of the
--   repository the current file is in, or everything changed in the working tree when nothing is staged.
-- Both use the same instructions (M.system; the chat is the "Commit message" entry in plugins/codecompanion.lua).
-- How much is written follows the size of the change: one line for a small one, a few bullets of context below
-- it for a larger one. The size is measured here (`measure`, `tier_of`) and the model is told the format as a
-- fact: left to judge the size itself, the local model answers with one line for every change.
-- <Leader>AS, Commit detail, moves that: always one line, or one step more than the size calls for.
local M = {}

local instructions = [[
You write git commit messages. You are given the list of changed files, recent commit subjects of the repository and the diff of the whole commit.

Rules:
- The message covers the commit as a whole: say what the change achieves, not what happened in each file. Never write one line per file.
- First line: a summary of at most 60 characters, imperative mood, no trailing period. Follow the style of the recent commit subjects (prefixes, capitalisation); do not add a "feat:"/"fix:" prefix unless they use one.
- Describe only what the diff shows. Do not invent reasons, do not mention files that did not change.]]

-- What goes below the first line, per size of change: `bullets` is how many (none for a small change), `label`
-- names the message in the notification.
local tiers = {
  small = { label = "one-line" },
  medium = { label = "short", bullets = "2 or 3" },
  large = { label = "detailed", bullets = "3 to 5" },
}

local body_instructions = [[

- Below the first line: a blank line, then %s bullets starting with "- ", each under 72 characters.
- Each bullet names one part of the change and what it does, adding what the first line leaves out. Edits to several files that serve one purpose are one bullet; never start a bullet with a file name.]]

--- The size of a change out of `git diff --numstat`: { files, lines }, the lines being added plus removed. A
--- file without changed lines (a rename, a mode change) does not count; a binary file counts as a file.
local function measure(numstat)
  local files, lines = 0, 0
  for line in (numstat or ""):gmatch "[^\n]+" do
    local added, removed = line:match "^(%S+)\t(%S+)\t"
    if added == "-" then
      files = files + 1
    elseif added then
      local changed = (tonumber(added) or 0) + (tonumber(removed) or 0)
      if changed > 0 then
        files, lines = files + 1, lines + changed
      end
    end
  end
  return { files = files, lines = lines }
end

--- "small", "medium" or "large" for a size, moved by the Commit detail setting (`mode`).
-- Set against this repository's history (lock files left out): its small commits change 2 to 19 lines in 1 or 2
-- files, the middle ones 46 to 217 lines in 2 to 5 files, the big ones 403 lines and more. Many files only make
-- a change large with enough lines in them (ten files of one-line path edits are not), and a handful of lines
-- is small however many files they are in.
local function tier_of(size, mode)
  if size.lines == 0 or mode == "brief" then return "small" end -- (no lines: nothing in the diff to describe)
  local tier = "medium"
  if size.lines <= 10 or (size.files <= 2 and size.lines <= 40) then
    tier = "small"
  elseif size.lines >= 300 or (size.files >= 6 and size.lines >= 100) then
    tier = "large"
  end
  if mode == "detailed" then return tier == "small" and "medium" or "large" end
  return tier
end

-- What fits the local model's 8k context next to the instructions and the answer (~3 characters per token for
-- diffs); a provider's model (<Leader>As) takes far more
local function max_prompt_chars() return require("user.ai").is_local() and 18000 or 300000 end
-- generated files: they are in the summary of changed files, their content only crowds out the real changes
local noise = { ":(exclude)*.lock", ":(exclude)*-lock.json", ":(exclude)*.lock.json", ":(exclude)*.min.js" }

local changes -- what `M.open` found, for the prompt that it starts

local function git(dir, args)
  -- A repository's own configuration can name programs for git to run. These calls read a repository that may
  -- be someone else's, so the hooks that would run here are off: core.fsmonitor and the signature check of
  -- `git log` (which runs gpg.program) here, external diff drivers and textconv filters where the diffs are
  -- made. (Not all of them can be: a `filter` still runs.)
  local cmd = vim.list_extend({ "git", "-c", "core.fsmonitor=false", "-c", "log.showSignature=false", "-C", dir }, args)
  local res = vim.system(cmd, { text = true }):wait()
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
local function fit(diff, max)
  if #diff <= max then return diff, false end
  local files = vim.split("\n" .. diff, "\ndiff --git ", { plain = true })
  table.remove(files, 1)
  local order = {}
  for i in ipairs(files) do
    files[i] = "diff --git " .. files[i]
    order[i] = i
  end
  table.sort(order, function(a, b) return #files[a] < #files[b] end)
  local left = max
  for n, i in ipairs(order) do
    local share = math.floor(left / (#order - n + 1))
    if #files[i] > share then
      files[i] = files[i]:sub(1, share):gsub("\n[^\n]*$", "") .. "\n[... the rest of this file's diff is left out ...]"
    end
    left = math.max(left - #files[i], 0)
  end
  return table.concat(files, "\n"), true
end

--- The changes to describe: { staged, stat, diff, log, truncated, size, tier }, or nil and the reason there
--- are none.
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
    base = { "diff", "--no-ext-diff", "--staged", "--no-textconv" }
    local typed = vim.trim(table.concat(message_lines(bufnr), "\n"))
    if typed ~= "" and typed == git(root, { "log", "-1", "--format=%B" }) and git(root, { "rev-parse", "HEAD~1" }) then
      table.insert(base, "HEAD~1")
    end
  else
    local staged = git(root, { "diff", "--no-ext-diff", "--no-textconv", "--staged", "--stat" }) ~= ""
    base = staged and { "diff", "--no-ext-diff", "--staged", "--no-textconv" }
      or { "diff", "--no-ext-diff", "HEAD", "--no-textconv" }
  end
  local staged = base[3] == "--staged"
  local stat = git(root, vim.list_extend(vim.deepcopy(base), { "--stat" }))
  if not stat or stat == "" then
    if committing then return nil, "Nothing is staged for this commit" end
    local untracked = git(root, { "ls-files", "--others", "--exclude-standard" })
    return nil, untracked ~= "" and "Only untracked files: stage them first (git add)" or "No changes to commit"
  end
  local function without_noise(option)
    return git(root, vim.list_extend(vim.list_extend(vim.deepcopy(base), { option, "--" }), noise))
  end
  local log = git(root, { "log", "-8", "--format=%s" }) or ""
  -- the file list grows with the commit: the diff gets what it and the subjects leave of the budget
  local diff, truncated = fit(without_noise "--patch" or "", math.max(max_prompt_chars() - #stat - #log, 2000))
  local size = measure(without_noise "--numstat")
  return {
    staged = staged,
    stat = stat,
    diff = diff,
    truncated = truncated,
    log = log,
    size = size,
    tier = tier_of(size, require("user.ai.settings").get "commit_detail"),
  }
end

--- The instructions for the size of these changes. `reply`: "plain" for the commit buffer, which takes the
--- message as it is, "block" for the chat.
function M.system(reply)
  local c = changes or collect()
  local tier = c and c.tier or "small"
  local bullets = tiers[tier].bullets
  local parts = { instructions }
  if bullets then
    parts[#parts + 1] = body_instructions:format(bullets)
    if tier == "large" then parts[#parts + 1] = "\n- Leave out minor edits (formatting, comments, renames)." end
  else
    parts[#parts + 1] = "\n- This is a small change: write the first line only, nothing below it."
  end
  parts[#parts + 1] = reply == "block"
      and "\n- Reply with the commit message inside one ``` code block and nothing else."
    or "\n- Reply with the commit message only: no code block, no explanation."
  return table.concat(parts)
end

--- Text out of the repository (file names, commit subjects, the diff) as a code block of a chat message.
--- Outside a commit buffer the message goes through CodeCompanion's chat, which reads `@{name}` anywhere in a
--- message as "give this chat the tool" and `#{name}` as "attach this" (every open buffer, for one), and
--- attaches the files and pages that links outside a code block point to. A repository could ask for all of
--- that with a file name or a commit subject. So: a space takes the meaning of `@{` and `#{` away (and changes
--- nothing a commit message is about), and the fence is one backtick longer than any run of them in the
--- text, so nothing in it ends the block early. `as_it_is`: without the space, for a message that goes to the
--- model directly (in a commit buffer), where `HEAD@{1}` should stay what it is.
local function block(text, info, as_it_is)
  if not as_it_is then text = text:gsub("([@#]){", "%1 {") end
  local longest = 2
  for run in text:gmatch "`+" do
    longest = math.max(longest, #run)
  end
  local fence = ("`"):rep(longest + 1)
  return { fence .. (info or ""), text, fence }
end

--- The user message of the prompt. `reply`: as for `M.system`; anything but "plain" is a message for the chat.
function M.prompt(reply)
  local c = changes or collect()
  if not c then return "There are no changes to commit; say so." end
  local direct = reply == "plain"
  local parts = { "Write the commit message for these changes.", "", "Changed files:" }
  vim.list_extend(parts, block(c.stat, nil, direct))
  if c.log ~= "" then
    vim.list_extend(parts, { "", "Recent commit subjects in this repository, for the style:" })
    vim.list_extend(parts, block(c.log, nil, direct))
  end
  vim.list_extend(parts, {
    "",
    c.truncated and "The diff (long files are cut short; the file list above is complete):" or "The diff:",
  })
  vim.list_extend(parts, block(c.diff, "diff", direct))
  vim.list_extend(parts, {
    "",
    -- said again after the diff: what a small model read last is what it follows
    tiers[c.tier].bullets and ("Format: the first line, a blank line, then %s bullets."):format(tiers[c.tier].bullets)
      or "Format: one line only.",
  })
  return table.concat(parts, "\n")
end

--- The message out of the model's answer (also a partial one, while it is being written): without code
--- fences, reasoning or surrounding blank lines.
local function clean(text)
  text = text:gsub("<think>.-</think>", ""):gsub("\r", "")
  local lines = vim.split(vim.trim(text), "\n", { plain = true })
  if lines[1]:find "^```" then table.remove(lines, 1) end
  if lines[#lines] and lines[#lines]:find "^```%s*$" then table.remove(lines) end
  local out = {}
  for _, line in ipairs(lines) do
    line = line:gsub("%s+$", ""):gsub("^%* ", "- "):gsub("^• ", "- ")
    -- no blank line at the start, and one at most between two lines
    if line ~= "" or (#out > 0 and out[#out] ~= "") then out[#out + 1] = line end
  end
  if out[#out] == "" then table.remove(out) end
  if #out == 0 then out[1] = "" end
  -- git wants a blank line between the subject and the body
  if out[2] and out[2] ~= "" then table.insert(out, 2, "") end
  return out
end

--- `subject` with the bullets out of `lines` below it: for an answer that was asked for the bullets alone.
--- Whatever else it holds (the first line again, a remark) is dropped; without bullets it is the subject alone.
local function with_body(subject, lines)
  local out = { subject }
  for _, line in ipairs(lines) do
    if line:find "^%- %S" then
      if #out == 1 then out[2] = "" end
      out[#out + 1] = line
    elseif #out > 1 and line:find "^%s+%S" then
      out[#out + 1] = line -- a wrapped bullet
    end
  end
  return out
end

--- What to ask for when the first answer does not have the form its tier calls for, and whether that asks for
--- the bullets alone (the first line is kept); nil when the answer is fine.
local function retry_prompt(lines, tier)
  local bullets = tiers[tier].bullets
  -- a commit with many changes tempts the model to list them all in the first line
  local length = vim.fn.strchars(lines[1])
  if length > 72 then
    if not bullets then
      return (
        "The first line is %d characters long. Rewrite the message as one line of at most 60 characters "
        .. "that names the main change."
      ):format(length),
        false
    end
    return (
      "The first line is %d characters long. Rewrite the message: a first line of at most 60 characters that "
      .. "names the main change, a blank line, then %s short bullets for the parts of the change."
    ):format(length, bullets),
      false
  end
  -- The first line alone for a larger change. Asking to "keep the first line and add bullets" gets the bullets
  -- without the line as often as not: ask for the bullets only and put them below the line here.
  if bullets and lines[1] ~= "" and not lines[2] then
    return (
      'Now write only the bullets that go below that line: %s bullets starting with "- ", one part of the '
      .. "change each, under 72 characters. Do not repeat the first line."
    ):format(bullets),
      true
  end
end

local writing = {} -- bufnr -> the request that is running for it

--- Write the message for the commit into its COMMIT_EDITMSG buffer, as the model writes it.
local function write(bufnr, found)
  local function notify(msg, level) vim.notify(msg, level or vim.log.levels.INFO, { title = "Commit message" }) end
  if writing[bufnr] then
    writing[bufnr].cancel()
    writing[bufnr] = nil
    return notify "Cancelled"
  end
  local ai = require "user.ai"
  local is_local = ai.is_local()
  changes = found
  local request = {
    system = M.system "plain",
    messages = { { role = "user", content = M.prompt "plain" } },
    -- (the providers: a ceiling, not a target. A model's thinking counts towards it, and a low one can end
    -- the answer before any text)
    max_tokens = is_local and 320 or 16000,
    -- keep_alive as the CodeCompanion chat: the two share the loaded model
    ollama = { keep_alive = "5m", options = { num_ctx = 8192, temperature = 0.2 } },
  }
  changes = nil

  local stream = require "user.ai.stream"
  -- replaces what is above git's comments: an earlier attempt, or the empty line git starts with
  local _, count = message_lines(bufnr)
  local comments_follow = count < vim.api.nvim_buf_line_count(bufnr)
  local region = stream.region(bufnr, 0, count)
  local first -- the first answer's lines, once a second one is asked for
  local subject -- its first line, while the second answer is the bullets alone
  local function message(text) return subject and with_body(subject, clean(text)) or clean(text) end
  local function show(lines)
    if lines[1] == "" then return end -- nothing yet: the buffer stays as it is
    lines = vim.list_slice(lines)
    if comments_follow then lines[#lines + 1] = "" end
    region:set(lines)
  end

  local size = found.size
  -- (generated files are not measured: a commit of nothing else has no size to name)
  local measured = size.files == 0 and ""
    or (" (%d file%s, %d line%s)"):format(
      size.files,
      size.files == 1 and "" or "s",
      size.lines,
      size.lines == 1 and "" or "s"
    )
  notify(
    ("Writing a %s message for this commit%s with %s... (<Leader>Ac cancels)"):format(
      tiers[found.tier].label,
      measured,
      ai.label()
    )
  )
  local function release_gpu()
    if is_local then require("user.ai.ollama").unload_spilled(ai.local_model()) end
  end
  local function send()
    local handle
    handle = ai.chat(request, function(text) show(message(text)) end, function(answer, info)
      writing[bufnr] = nil
      if not vim.api.nvim_buf_is_loaded(bufnr) then return release_gpu() end -- the commit was closed meanwhile
      local lines = message(answer)
      local kept -- why the first answer stands, when the second one brought nothing
      if first then
        if info.error then
          kept = "asking again failed: " .. info.error
        elseif lines[1] == "" or (subject and not lines[2]) then
          kept = subject and "the model added no bullets" or "the model gave no shorter message"
        end
        if kept then
          lines, info = first, {}
        elseif not subject and not lines[2] and tiers[found.tier].bullets then
          lines = with_body(lines[1], first) -- rewritten as the first line alone: the bullets it had stay
        end
      elseif not info.error then
        -- Not the form the size of the change calls for: ask once more, with the rest of the conversation
        -- (the diff is already evaluated, so this takes a few seconds).
        local again, bullets_only = retry_prompt(lines, found.tier)
        if again then
          first, subject = lines, bullets_only and lines[1] or nil
          vim.list_extend(
            request.messages,
            { { role = "assistant", content = answer }, { role = "user", content = again } }
          )
          return send()
        end
      end
      if not info.error then show(lines) end -- (also puts the first answer back)
      region:release()
      release_gpu()
      if info.error then return notify("Request failed: " .. info.error, vim.log.levels.ERROR) end
      if lines[1] == "" then return notify("The model gave no message", vim.log.levels.WARN) end
      for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
        vim.api.nvim_win_set_cursor(win, { 1, 0 })
      end
      local notes = {}
      if kept then notes[#notes + 1] = "kept the first answer, " .. kept end
      if vim.fn.strchars(lines[1]) > 72 then notes[#notes + 1] = "the first line is long" end
      if info.done_reason == "length" then notes[#notes + 1] = "it was cut off at the length limit" end
      if found.truncated then notes[#notes + 1] = "the diff was long: check that nothing is missing" end
      notify(
        #notes == 0 and "Done" or ("Done (%s)"):format(table.concat(notes, "; ")),
        (kept or info.done_reason == "length") and vim.log.levels.WARN or vim.log.levels.INFO
      )
    end)
    -- pressing the key again: while the second answer is being written, the first one comes back
    writing[bufnr] = {
      cancel = function()
        handle.cancel()
        if first then show(first) end
        region:release()
      end,
    }
  end
  send()
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

-- for tests
M._measure, M._tier_of, M._clean, M._with_body, M._retry_prompt = measure, tier_of, clean, with_body, retry_prompt
M._block = block

return M
