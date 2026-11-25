-- The file tree's keys.
--   <Tab> / <S-Tab>        next and previous source (Files, Buffers, Git), as they change buffers outside the tree
--   <Tab> in visual mode   selects the highlighted files, or unselects them when all of them are selected
--   <Esc>                  drops the selection
--   <Leader>               only the tree's own keys, the same in every source, each for the row under the cursor:
--                          Git commands (<Leader>g), find and terminal in its folder (<Leader>f, <Leader>t), close
--                          its buffer (<Leader>x). The global <Leader> keys do nothing in the tree and stay out of
--                          its which-key popup.
--   <Leader>g              is where everything that changes the repository is done (user/git.lua); the Git keys
--                          of a file buffer only look (plugins/gitsigns.lua, astrocore.lua, snacks.lua,
--                          diffview.lua).
--   <Leader>gc, <Leader>gg write the commit message in a floating window (user/git_commit.lua), in place of
--                          neo-tree's one-line prompt, and first stage the file under the cursor when it has
--                          changes of which none is staged. <Leader>gC amends the last commit in that window.
--   <Leader>gp, gl, gr, gU ask first, in a picker in the middle of the screen, as <Leader>gd and <Leader>gD do
--                          once a branch or a stash is picked
--   i                      neo-tree's file details, in a float in the middle of the screen
-- A key set to false is one that neo-tree or AstroNvim maps in the tree. neo-tree 3.42 compares these keys as they
-- are written (its normalize_mappings never finds the table), so each is spelled as neo-tree's defaults.lua spells
-- it, or the default stays.

--- neo-tree only maps a key in visual mode as the twin of a normal mode command on the same key, and hands that
--- twin the files selected earlier as well. <Tab> changes the source in normal mode, so its visual mode mapping is
--- set on the tree buffer directly.
local function select_highlighted()
  local state = assert(require("neo-tree.sources.manager").get_state_for_window(), "not in a neo-tree window")
  local first, last = vim.fn.line "v", vim.fn.line "."
  local nodes = {}
  for line = math.min(first, last), math.max(first, last) do
    nodes[#nodes + 1] = state.tree:get_node(line)
  end
  vim.cmd.normal { vim.keycode "<Esc>", bang = true }
  state.commands.select_visual(state, nodes)
end

--- The keys neo-tree's mapping table cannot express. Runs on every entry into a tree buffer, so that a global
--- <Leader> mapping made after the tree was opened is hidden as well.
local function set_buffer_keys()
  local buf = vim.api.nvim_get_current_buf()
  vim.keymap.set("x", "<Tab>", select_highlighted, { buffer = buf, desc = "Select the highlighted files" })
  local leader = vim.g.mapleader
  require("user.hidden_keys").hide(buf, function(lhs) return vim.startswith(lhs, leader) end)
end

--- After a command that changes the repository: the tree shows the new state, and the buffers of files that were
--- rewritten are read again.
local function repository_changed()
  local events = require "neo-tree.events"
  events.fire_event(events.GIT_EVENT)
  vim.cmd.checktime()
end

--- The repository a tree shows, as the commands of user/git.lua and user/git_commit.lua take it.
---@param state neotree.State
---@return user.git.Repository
local function repository(state) return { dir = state.path, on_change = repository_changed } end

--- The row under the cursor, when it is a file, a directory or a buffer.
---@param state neotree.State
local function row(state)
  local node = state.tree:get_node()
  return node and node.type ~= "message" and node or nil
end

--- Runs `action` once the question is answered with Yes. No comes first, so that it is what Enter alone answers.
---@param question string
---@param action fun()
local function confirmed(question, action)
  vim.ui.select({ "No", "Yes" }, { prompt = question }, function(answer)
    if answer == "Yes" then action() end
  end)
end

--- Shows lines in a float in the middle of the screen, which q, Esc and Enter close.
---@param title string
---@param lines string[]
local function show_in_float(title, lines)
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.api.nvim_strwidth(line))
  end
  require("snacks").win {
    text = lines,
    title = " " .. title .. " ",
    border = true,
    backdrop = false,
    width = width + 2,
    height = #lines,
    keys = { ["<Esc>"] = "close", ["<CR>"] = "close" },
  }
end

--- neo-tree's file details. Its command works them out and hands them to neo-tree's popup, which opens at the
--- cursor's row and over the buffer beside the tree: the float above takes its place while the command runs.
---@param state neotree.State
local function file_details(state)
  local popups = require "neo-tree.ui.popups"
  local alert = popups.alert
  popups.alert = show_in_float
  local shown, problem = pcall(require("neo-tree.sources.common.commands").show_file_details, state)
  popups.alert = alert
  if not shown then error(problem, 0) end
end

---@param state neotree.State
---@param how? { amend?: boolean, push?: boolean }
local function commit(state, how)
  how = how or {}
  local node = state.tree:get_node()
  local on_file = node and (node.type == "file" or node.type == "link")
  require("user.git_commit").commit(vim.tbl_extend("error", repository(state), how, {
    -- an amend is of the last commit and what was staged for it by hand
    stage = on_file and not how.amend and node:get_id() or nil,
  }))
end

--- Opens one of snacks' Git pickers on the tree's repository, and hands what is picked in it to `on_pick`. The
--- pickers that change a repository are opened from the tree only (astrocore.lua drops their global keys), and
--- change it through user/git.lua, which tells the tree when it is done.
---@param state neotree.State
---@param picker snacks.picker.Config the source, and a title that says what Enter does: a source has several keys
---@param on_pick fun(repo: user.git.Repository, item: snacks.picker.Item)
local function pick(state, picker, on_pick)
  local repo = repository(state)
  require("snacks").picker.pick(vim.tbl_extend("error", picker, {
    cwd = repo.dir,
    -- the tree: without it a closed picker leaves for the window it would have opened a file in
    main = { current = true },
    confirm = function(open, item)
      open:close()
      -- not before the picker has left insert mode, which it does after this: a picker that `on_pick` opens to
      -- ask a question would be left in normal mode with it
      if item then vim.schedule(function() on_pick(repo, item) end) end
    end,
  }))
end

---@param state neotree.State
local function switch_branch(state)
  pick(state, { source = "git_branches", title = "Switch branch" }, function(repo, item)
    local ref = item.branch or item.commit
    if ref then require("user.git").checkout(repo, ref) end
  end)
end

---@param state neotree.State
local function new_branch(state)
  vim.ui.input({ prompt = "New branch: " }, function(name)
    if name and name ~= "" then require("user.git").create_branch(repository(state), name) end
  end)
end

---@param state neotree.State
local function delete_branch(state)
  local others = {
    source = "git_branches",
    title = "Delete a branch",
    -- git deletes no branch that is checked out
    transform = function(item) return not item.current end,
  }
  pick(state, others, function(repo, item)
    if not item.branch then return end
    local git = require "user.git"
    local lost = git.commits_only_in(repo, item.branch)
    local question = ("Delete branch %s?"):format(item.branch)
    if lost > 0 then
      local commits = lost == 1 and "1 commit" or (lost .. " commits")
      question = ("%s It has %s the current branch does not."):format(question, commits)
    end
    confirmed(question, function() git.delete_branch(repo, item.branch) end)
  end)
end

---@param state neotree.State
local function pop_stash(state)
  pick(
    state,
    { source = "git_stash", title = "Apply a stash" },
    function(repo, item) require("user.git").pop_stash(repo, item.stash) end
  )
end

---@param state neotree.State
local function drop_stash(state)
  pick(state, { source = "git_stash", title = "Drop a stash" }, function(repo, item)
    confirmed(
      ("Drop %s without applying it?"):format(item.stash),
      function() require("user.git").drop_stash(repo, item.stash) end
    )
  end)
end

---@param state neotree.State
local function stash_changes(state)
  vim.ui.input({ prompt = "Stash message (optional): " }, function(message)
    if message then require("user.git").stash(repository(state), message) end
  end)
end

--- The listed buffer that the file `path` is open in.
---@param path string
---@return integer?
local function buffer_of(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].buflisted and vim.api.nvim_buf_get_name(buf) == path then return buf end
  end
end

--- Closes the buffer of the row under the cursor, as <Leader>x closes the current buffer outside the tree: the
--- row's own buffer in the Buffers source, elsewhere the buffer the row's file is open in.
---@param state neotree.State
local function close_buffer(state)
  local node = row(state)
  if not node then return end
  local buf = node.extra and node.extra.bufnr or buffer_of(node:get_id())
  if not buf then
    vim.notify(("%s is not open in a buffer"):format(node.name), vim.log.levels.INFO)
    return
  end
  require("astrocore.buffer").close(buf)
end

-- neo-tree maps i in each source, not for all of them, so each source is given this
local file_details_key = { "file_details", desc = "Show file details" }

---@type LazySpec
return {
  "nvim-neo-tree/neo-tree.nvim",
  opts = {
    commands = {
      commit_in_editor = function(state) commit(state) end,
      commit_in_editor_and_push = function(state) commit(state, { push = true }) end,
      amend_in_editor = function(state) commit(state, { amend = true }) end,
      -- named apart from neo-tree's git_push, git_pull, git_revert_file and git_undo_last_commit, which a source
      -- prefers to a command of the same name given here; those wait for git, and ask and answer in popups of
      -- their own at the cursor's row
      push_in_background = function(state)
        confirmed(
          "Are you sure you want to push your changes?",
          function() require("user.git").push(repository(state)) end
        )
      end,
      pull_in_background = function(state)
        confirmed("Run a git pull?", function() require("user.git").pull(repository(state)) end)
      end,
      fetch_in_background = function(state) require("user.git").fetch(repository(state)) end,
      undo_last_commit = function(state)
        confirmed(
          "Undo the last commit? Its changes stay staged.",
          function() require("user.git").undo_last_commit(repository(state)) end
        )
      end,
      file_details = file_details,
      unstage_all = function(state) require("user.git").unstage_all(repository(state)) end,
      revert_file = function(state)
        local node = row(state)
        if not node then return end
        confirmed(
          ("Are you sure you want to revert %s?"):format(node.name),
          function() require("user.git").revert(repository(state), node:get_id()) end
        )
      end,
      ignore_file = function(state)
        local node = row(state)
        if node then require("user.git").ignore(repository(state), node:get_id()) end
      end,
      switch_branch = switch_branch,
      new_branch = new_branch,
      delete_branch = delete_branch,
      stash_changes = stash_changes,
      pop_stash = pop_stash,
      drop_stash = drop_stash,
      close_buffer = close_buffer,
      clear_selection_or_cancel = function(state)
        if next(state.selected) then
          state.commands.clear_selection(state)
        else
          state.commands.cancel(state)
        end
      end,
    },
    event_handlers = {
      { event = "neo_tree_buffer_enter", handler = set_buffer_keys },
    },
    window = {
      mappings = {
        ["<Tab>"] = "next_source",
        ["<S-Tab>"] = "prev_source",
        ["<C-S-i>"] = false, -- neo-tree's invert selection: the same key as <S-Tab>
        ["<"] = false,
        [">"] = false,
        ["[b"] = false,
        ["]b"] = false,
        ["<esc>"] = { "clear_selection_or_cancel", desc = "Clear selection, or close the preview" },
        ["<C-;>"] = false, -- neo-tree's clear selection
        -- neo-tree's toggle folder (<CR> does that); while it is mapped, which-key cannot open on <Leader>
        ["<space>"] = false,
        T = false,
        Tf = false,
        Th = false,
        Tv = false,
        ["<Leader>tf"] = { "toggleterm_float", desc = "Terminal in this folder (float)" },
        ["<Leader>th"] = { "toggleterm_horizontal", desc = "Terminal in this folder (horizontal)" },
        ["<Leader>tv"] = { "toggleterm_vertical", desc = "Terminal in this folder (vertical)" },
        ["<Leader>ff"] = { "find_files_in_dir", desc = "Find files in this folder" },
        ["<Leader>fF"] = { "find_all_files_in_dir", desc = "Find all files in this folder" },
        ["<Leader>fw"] = { "find_words_in_dir", desc = "Find words in this folder" },
        ["<Leader>fW"] = { "find_all_words_in_dir", desc = "Find words in all files in this folder" },
        ["<Leader>x"] = { "close_buffer", desc = "Close buffer" },
        ["<Leader>ga"] = { "git_add_file", desc = "Stage file" },
        ["<Leader>gA"] = { "git_add_all", desc = "Stage all" },
        ["<Leader>gu"] = { "git_unstage_file", desc = "Unstage file" },
        ["<Leader>gt"] = { "git_toggle_file_stage", desc = "Stage or unstage file" },
        ["<Leader>gx"] = { "unstage_all", desc = "Unstage all" },
        ["<Leader>gr"] = { "revert_file", desc = "Revert file" },
        ["<Leader>gi"] = { "ignore_file", desc = "Ignore file" },
        ["<Leader>gc"] = { "commit_in_editor", desc = "Commit" },
        ["<Leader>gC"] = { "amend_in_editor", desc = "Amend last commit" },
        ["<Leader>gg"] = { "commit_in_editor_and_push", desc = "Commit and push" },
        ["<Leader>gU"] = { "undo_last_commit", desc = "Undo last commit" },
        ["<Leader>gp"] = { "push_in_background", desc = "Push" },
        ["<Leader>gl"] = { "pull_in_background", desc = "Pull" },
        ["<Leader>gf"] = { "fetch_in_background", desc = "Fetch" },
        ["<Leader>gb"] = { "switch_branch", desc = "Switch branch" },
        ["<Leader>gB"] = { "new_branch", desc = "New branch" },
        ["<Leader>gd"] = { "delete_branch", desc = "Delete a branch" },
        ["<Leader>gs"] = { "stash_changes", desc = "Stash changes" },
        ["<Leader>gT"] = { "pop_stash", desc = "Apply a stash" },
        ["<Leader>gD"] = { "drop_stash", desc = "Drop a stash" },
      },
    },
    filesystem = {
      window = {
        mappings = {
          i = file_details_key,
          f = "filter_on_submit", -- neo-tree's own f; AstroNvim made it the prefix of the find keys
          ["f/"] = false,
          ff = false,
          fF = false,
          fw = false,
          fW = false,
        },
      },
    },
    buffers = {
      window = {
        mappings = {
          i = file_details_key,
          bd = false,
          d = false,
        },
      },
    },
    git_status = {
      window = {
        mappings = {
          i = file_details_key,
          A = false,
          ga = false,
          gu = false,
          gt = false,
          gr = false,
          gc = false,
          gg = false,
          gp = false,
          gl = false,
          gU = false,
        },
      },
    },
  },
}
