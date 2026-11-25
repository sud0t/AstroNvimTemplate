-- <Leader>Ac in the editor `git commit` opens (COMMIT_EDITMSG): write the commit's message with the AI chosen
-- with <Leader>As, into the buffer as the model writes it, above git's comment lines. `u` takes it out again;
-- the key again writes another one (or cancels the one being written).
-- How much is written follows the size of the change (`measure`, `tier_of`): one line for a small one, a few
-- bullets below it for a larger one. The model is told the format as a fact: left to judge the size itself,
-- the local model answers with one line for every change.
local M = {}

local instructions = [[
You write git commit messages. You are given the list of changed files, recent commit subjects of the repository and the diff of the whole commit.

Rules:
- The message covers the commit as a whole: say what the change achieves, not what happened in each file. Never write one line per file.
- First line: a summary of at most 60 characters, imperative mood, no trailing period. Follow the style of the recent commit subjects (prefixes, capitalisation); do not add a "feat:"/"fix:" prefix unless they use one.
- Describe only what the diff shows. Do not invent reasons, do not mention files that did not change.]]

-- What goes below the first line per size of change: how many `bullets`; `label` is its name in the note.
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

--- "small", "medium" or "large" for a size.
-- Thresholds from this repository's history: small commits are 2-19 lines in 1-2 files, large ones 400+.
-- Many files only make a change large when they hold enough lines.
local function tier_of(size)
  if size.lines <= 10 or (size.files <= 2 and size.lines <= 40) then return "small" end
  if size.lines >= 300 or (size.files >= 6 and size.lines >= 100) then return "large" end
  return "medium"
end

-- What fits the local model's 8k context next to the instructions and the answer (~3 characters per token for
-- diffs); a provider's model (<Leader>As) takes far more
local function max_prompt_chars() return require("user.ai").is_local() and 18000 or 300000 end
-- generated files: they are in the summary of changed files, their content only crowds out the real changes
local noise = { ":(exclude)*.lock", ":(exclude)*-lock.json", ":(exclude)*.lock.json", ":(exclude)*.min.js" }

local function notify(msg, level) vim.notify(msg, level or vim.log.levels.INFO, { title = "Commit message" }) end

local function git(dir, args)
  -- The repository may be someone else's: switch off what its configuration can make git run (fsmonitor,
  -- gpg through showSignature; external diff and textconv at the diff calls). A `filter` still runs.
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

--- The changes the commit of the COMMIT_EDITMSG buffer `bufnr` makes: { stat, diff, log, truncated, size,
--- tier }, or nil and the reason there are none.
local function collect(bufnr)
  -- COMMIT_EDITMSG is in the git directory, which is not part of the work tree (and that of a worktree or
  -- submodule is somewhere else entirely): git started the editor in the repository
  local root = git(vim.fn.getcwd(), { "rev-parse", "--show-toplevel" })
  local git_dir = vim.fs.dirname(vim.api.nvim_buf_get_name(bufnr))
  if not root and vim.fs.basename(git_dir) == ".git" then
    root = git(vim.fs.dirname(git_dir), { "rev-parse", "--show-toplevel" })
  end
  if not root then return nil, "Not in a git repository" end

  -- What is being committed is the index (git points GIT_INDEX_FILE at the right one for `commit -a` and
  -- `commit <paths>`). With --amend the buffer starts with the message of HEAD, and the commit replaces it.
  local base = { "diff", "--no-ext-diff", "--staged", "--no-textconv" }
  local typed = vim.trim(table.concat(message_lines(bufnr), "\n"))
  if typed ~= "" and typed == git(root, { "log", "-1", "--format=%B" }) and git(root, { "rev-parse", "HEAD~1" }) then
    table.insert(base, "HEAD~1")
  end
  local stat = git(root, vim.list_extend(vim.deepcopy(base), { "--stat" }))
  if not stat or stat == "" then return nil, "Nothing is staged for this commit" end
  local function without_noise(option)
    return git(root, vim.list_extend(vim.list_extend(vim.deepcopy(base), { option, "--" }), noise))
  end
  local log = git(root, { "log", "-8", "--format=%s" }) or ""
  -- the file list grows with the commit: the diff gets what it and the subjects leave of the budget
  local diff, truncated = fit(without_noise "--patch" or "", math.max(max_prompt_chars() - #stat - #log, 2000))
  local size = measure(without_noise "--numstat")
  return { stat = stat, diff = diff, truncated = truncated, log = log, size = size, tier = tier_of(size) }
end

--- The instructions for a change of the size `tier`.
local function system(tier)
  local bullets = tiers[tier].bullets
  local parts = { instructions }
  if bullets then
    parts[#parts + 1] = body_instructions:format(bullets)
    if tier == "large" then parts[#parts + 1] = "\n- Leave out minor edits (formatting, comments, renames)." end
  else
    parts[#parts + 1] = "\n- This is a small change: write the first line only, nothing below it."
  end
  parts[#parts + 1] = "\n- Reply with the commit message only: no code block, no explanation."
  return table.concat(parts)
end

--- `text` from the repository as a fenced block, the fence longer than any run of backticks in the text.
local function block(text, info)
  local longest = 2
  for run in text:gmatch "`+" do
    longest = math.max(longest, #run)
  end
  local fence = ("`"):rep(longest + 1)
  return { fence .. (info or ""), text, fence }
end

--- The user message for the changes `c` (from `collect`).
local function prompt(c)
  local parts = { "Write the commit message for these changes.", "", "Changed files:" }
  vim.list_extend(parts, block(c.stat))
  if c.log ~= "" then
    vim.list_extend(parts, { "", "Recent commit subjects in this repository, for the style:" })
    vim.list_extend(parts, block(c.log))
  end
  vim.list_extend(parts, {
    "",
    c.truncated and "The diff (long files are cut short; the file list above is complete):" or "The diff:",
  })
  vim.list_extend(parts, block(c.diff, "diff"))
  vim.list_extend(parts, {
    "",
    -- said again after the diff: what a small model read last is what it follows
    tiers[c.tier].bullets and ("Format: the first line, a blank line, then %s bullets."):format(tiers[c.tier].bullets)
      or "Format: one line only.",
  })
  return table.concat(parts, "\n")
end

--- The message out of the model's answer (also a partial one, while it is being written): without code
--- fences or surrounding blank lines.
local function clean(text)
  text = text:gsub("\r", "")
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

--- Write the message for the changes `found` into their COMMIT_EDITMSG buffer, as the model writes it.
local function write(bufnr, found)
  local ai = require "user.ai"
  local request = {
    system = system(found.tier),
    messages = { { role = "user", content = prompt(found) } },
    -- (the providers: a ceiling, not a target. A model's thinking counts towards it, and a low one can end
    -- the answer before any text)
    max_tokens = ai.is_local() and 320 or 16000,
    ollama = { options = { num_ctx = require("user.ai.ollama").context, temperature = 0.2 } },
  }

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
  local function send()
    local handle
    handle = ai.chat(request, function(text) show(message(text)) end, function(answer, info)
      writing[bufnr] = nil
      if not vim.api.nvim_buf_is_loaded(bufnr) then return end -- the commit was closed meanwhile
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
  if writing[bufnr] then
    writing[bufnr].cancel()
    writing[bufnr] = nil
    return notify "Cancelled"
  end
  if not is_commit_buffer(bufnr) then
    return notify(
      "No commit is being written here: start one first (<Leader>gc in the file tree, or `git commit`).",
      vim.log.levels.WARN
    )
  end
  local found, reason = collect(bufnr)
  if not found then return notify(reason, vim.log.levels.WARN) end
  write(bufnr, found)
end

return M
