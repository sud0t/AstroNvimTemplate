-- Rules files (the instructions that go along with chats): which of them may be used, and the record
-- of what the owner has approved.
local M = {}

local uv = vim.uv

local State = require "user.ai.sandbox.state"
local Paths = require "user.ai.sandbox.paths"
local Text = require "user.ai.sandbox.text"
local Checks = require "user.ai.sandbox.checks"

local locks = State.locks
local tell = State.tell
local settings = State.settings
local within = Paths.within
local entry_path = Paths.entry_path
local list = Paths.list
local covered = Paths.covered
local spell_out = Text.spell_out
local project_root = Checks.project_root

-- which versions of the projects' rules files the owner has read and approved: { [path] = sha256 }
M.approved_file = vim.fn.stdpath "state" .. "/ai_rules_approved.json"
M.rules_max_size = 262144 -- bytes; far more than a chat has room for

local function content_hash(path)
  local ok, lines = pcall(vim.fn.readfile, path, "b")
  return ok and vim.fn.sha256(table.concat(lines, "\n")) or nil
end

local function approved()
  local ok, lines = pcall(vim.fn.readfile, M.approved_file)
  local decoded, data = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
  return decoded and type(data) == "table" and not vim.islist(data) and data or {}
end

--- Whether the project instructions at `path` go along with chats: "missing", "approved" (the owner has
--- approved exactly this content in <Leader>AS) or "unapproved" (new, or changed since). What the file says
--- is obeyed by every later chat in the project, and a repository can bring one along (so can a command the
--- chat runs): it only counts once the owner has seen it.
--- Only a regular file of a size instructions have is read at all: a repository can bring a link to anything.
---@return "missing"|"approved"|"unapproved" state, string|nil real, string|nil hash
function M.rules_state(path)
  local read, real = pcall(function() return uv.fs_realpath(vim.fs.abspath(vim.fs.normalize(path))) end)
  local stat = read and real and uv.fs_stat(real)
  if not stat or stat.type ~= "file" then return "missing" end
  if stat.size > M.rules_max_size then return "unapproved", real, nil end
  local hash = content_hash(real)
  if not hash then return "missing" end
  return approved()[real] == hash and "approved" or "unapproved", real, hash
end

--- Why the file at `path` cannot be the project's instructions, or nil when it can (also when there is none
--- yet), and its absolute path. A repository can bring a link under that name: to a device that never ends,
--- or to a file of yours that opening and saving would then change.
local function rules_file_problem(path)
  local found, abs, stat = pcall(function()
    local full = vim.fs.abspath(vim.fs.normalize(path))
    return full, uv.fs_lstat(full)
  end)
  if not found or not stat then return nil end
  if stat.type == "link" then return "it is a symbolic link, and instructions are a file of the project itself" end
  if stat.type ~= "file" then return "it is not a regular file" end
  if stat.size > M.rules_max_size then return ("it is larger than instructions are (%d bytes)"):format(stat.size) end
  return nil, abs
end

-- More blanks in a row (a table with one long cell is padded with a good hundred), and more empty lines,
-- than instructions have a use for
local most_blanks, most_empty_lines = 400, 10
-- Characters that show as an empty place (the ones that show as nothing at all: `unseen` in text.lua): no-break
-- space, ogham space, U+2000 to U+200A and U+202F, U+205F, the empty braille pattern, ideographic space
local blank_characters = {
  "\194\160",
  "\225\154\128",
  "\226\128[\128-\138\175]",
  "\226\129\159",
  "\226\160\128",
  "\227\128\128",
}

--- Why `text` cannot be instructions: characters that do not show on a screen are how instructions are
--- written that a model reads and the person who approves them does not. (A byte order mark at the very
--- start is how some editors save, and the pieces emoji are made of say nothing.)
local function rules_text_problem(text)
  text = text:gsub("^\239\187\191", "")
  local _, count, first, line = spell_out(text)
  if count > 0 then
    return (
      "it has %d character%s that %s not show on a screen (%s in line %d), which is how instructions are hidden "
      .. "from the one who approves them. Open the file yourself and take %s out"
    ):format(
      count,
      count == 1 and "" or "s",
      count == 1 and "does" or "do",
      first,
      line,
      count == 1 and "it" or "them"
    )
  end
  -- Nor is it padded: blanks are how text is kept off the screen it is read on before it is approved.
  local number, empty = 0, 0
  for row in (text .. "\n"):gmatch "(.-)\r?\n" do
    number = number + 1
    for _, blank in ipairs(blank_characters) do
      row = row:gsub(blank, " ")
    end
    for run in row:gmatch "[ \t]+" do
      if #run > most_blanks then
        return (
          "line %d has %d blanks in a row, which is how text is kept off the screen of the one who approves it. "
          .. "Open the file yourself and take them out"
        ):format(number, #run)
      end
    end
    if not row:find "%S" then
      empty = empty + 1
    elseif empty > most_empty_lines then
      -- (only before more text: the ones a file ends with keep nothing off the screen)
      return (
        "it has more than %d lines in a row with nothing in them (from line %d), which is how text is kept off "
        .. "the screen of the one who approves it. Open the file yourself and take them out"
      ):format(most_empty_lines, number - empty)
    else
      empty = 0
    end
  end
end

--- The project instructions at `path` as they are on disk and the hash of exactly that text, for showing
--- them before they are approved; nil and why when they cannot be instructions (or there are none).
---@return string|nil text, string hash_or_why
function M.read_rules(path)
  local problem, abs = rules_file_problem(path)
  if problem then return nil, problem end
  local read, lines = pcall(vim.fn.readfile, abs or "", "b")
  if not abs or not read then return nil, "there is no such file" end
  local text = table.concat(lines, "\n")
  problem = rules_text_problem(text)
  if problem then return nil, problem end
  return text, vim.fn.sha256(text)
end

--- Why the project instructions at `path` cannot be opened or approved as they are, or nil when they can
--- (also when there is no file yet).
function M.rules_problem(path)
  local problem, abs = rules_file_problem(path)
  if problem or not abs then return problem end
  local read, lines = pcall(vim.fn.readfile, abs, "b")
  return read and rules_text_problem(table.concat(lines, "\n")) or nil
end

--- Approve the instructions at `path` as they are now. `shown`: the hash of what the owner was shown (or
--- several, when it is one of them): a file that is not that text, or no longer, is not approved.
--- Returns false and the reason when that failed.
function M.approve_rules(path, shown)
  local problem = M.rules_problem(path)
  if problem then return false, problem end
  local state, real, hash = M.rules_state(path)
  if state == "missing" or not hash then return false, path .. " does not exist" end
  if type(shown) == "string" then shown = { shown } end
  if type(shown) ~= "table" then return false, "nothing says which text was read" end
  if not vim.list_contains(shown, hash) then
    return false, "the file on disk is not what you were shown: it changed meanwhile"
  end
  if state == "approved" then return true end
  local all = approved()
  all[real] = hash
  -- Written beside the record and moved into place, so that nothing ever reads half of it. (Two Neovims that
  -- approve at the same moment can lose one of the two approvals: that file then waits to be approved again.)
  local ok = pcall(function()
    vim.fn.mkdir(vim.fs.dirname(M.approved_file), "p")
    local beside = ("%s.%d"):format(M.approved_file, uv.os_getpid())
    assert(vim.fn.writefile({ vim.json.encode(all) }, beside) == 0)
    assert(uv.fs_rename(beside, M.approved_file))
  end)
  if ok then return true end
  return false, "could not write " .. M.approved_file
end

--- The rules files out of `paths` (what CodeCompanion is about to read and send along) that may be used:
--- regular files, none of them protected, none that is written as part of the project but leads out of it
--- (a link in a repository), and the project's own instructions only as the owner approved them.
local function vet_rules(paths)
  local s = settings()
  local root = project_root()
  local kept = {}
  for _, path in ipairs(paths) do
    local abs = vim.fs.abspath(vim.fs.normalize(path))
    local real = uv.fs_realpath(abs)
    local stat = real and uv.fs_stat(real)
    local why
    if not s then
      why = "srt-ai.json cannot be read"
    elseif not root then
      why = "the directory Neovim is running in no longer exists"
    elseif not stat or stat.type ~= "file" then
      why = "it is not a regular file"
    elseif within(abs, root) and not within(real, root) then
      why = "it is a link that leads out of the project"
    else
      for _, entry in ipairs(list(s.filesystem.denyRead)) do
        if covered(real, entry) then why = "it is protected (" .. entry_path(entry) .. ")" end
      end
    end
    if not why and vim.fs.basename(abs) == State.project_rules then
      local state, _, hash = M.rules_state(real)
      -- (also for a file that was approved before this was looked for)
      local unusable = state == "approved" and M.rules_problem(real)
      if unusable then
        tell(("The project's AI instructions (%s) are not used: %s."):format(vim.fn.fnamemodify(real, ":~"), unusable))
        why = unusable
      elseif state ~= "approved" then
        tell(
          (
            "The project's AI instructions (%s) are new or have changed: chats do not get them until you have "
            .. "approved them (<Leader>AS, Project rules).\n[%s]"
          ):format(vim.fn.fnamemodify(real, ":~"), (hash or ""):sub(1, 8))
        )
        why = "not approved"
      end
    elseif why then
      tell(("The AI rules file %s is not used: %s."):format(vim.fn.fnamemodify(abs, ":~"), why))
    end
    if not why then kept[#kept + 1] = path end
  end
  return kept
end

--- Whether the rules files are sent along unchecked (the function wrapped for them is gone): the rule groups
--- in plugins/codecompanion.lua then load nothing by themselves.
function M.rules_locked() return locks.rules ~= nil end

M.vet_rules = vet_rules

return M
