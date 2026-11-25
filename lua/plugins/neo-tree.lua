-- The file tree's keys. <Leader> lists only the tree's own keys, the same in every source, each acting on the row
-- under the cursor; the global <Leader> keys are hidden here (user/hidden_keys.lua). Everything that changes the
-- repository is on <Leader>g (user/git.lua, user/git_prompts.lua, user/git_commit.lua): a file buffer's Git keys
-- only look.
-- A key set to false is one that neo-tree or AstroNvim maps. neo-tree 3.42 compares these keys as written (its
-- normalize_mappings never finds the table), so each is spelled as neo-tree's defaults.lua spells it.

--- <Tab> in visual mode. neo-tree maps a visual mode key only as the twin of the same key's normal mode command
--- (<Tab>: the next source), and hands the twin the rows selected earlier as well: so the tree buffer maps this.
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

--- The repository a tree shows, as user/git.lua, user/git_prompts.lua and user/git_commit.lua take it.
---@param state neotree.State
---@return user.git.Repository
local function repository(state) return { dir = state.path, on_change = repository_changed } end

--- The row under the cursor, when it is a file, a directory or a buffer.
---@param state neotree.State
local function row(state)
  local node = state.tree:get_node()
  return node and node.type ~= "message" and node or nil
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

---@type LazySpec
return {
  "nvim-neo-tree/neo-tree.nvim",
  opts = {
    commands = {
      commit_in_editor = function(state) commit(state) end,
      commit_in_editor_and_push = function(state) commit(state, { push = true }) end,
      amend_in_editor = function(state) commit(state, { amend = true }) end,
      -- Not named as neo-tree's git_push, git_pull, git_revert_file and git_undo_last_commit: a source prefers
      -- its own command to one of the same name given here, and those wait for git and ask at the cursor's row.
      push_in_background = function(state) require("user.git_prompts").push(repository(state)) end,
      pull_in_background = function(state) require("user.git_prompts").pull(repository(state)) end,
      fetch_in_background = function(state) require("user.git").fetch(repository(state)) end,
      undo_last_commit = function(state) require("user.git_prompts").undo_last_commit(repository(state)) end,
      unstage_all = function(state) require("user.git").unstage_all(repository(state)) end,
      revert_file = function(state)
        local node = row(state)
        if node then require("user.git_prompts").revert(repository(state), node:get_id(), node.name) end
      end,
      ignore_file = function(state)
        local node = row(state)
        if node then require("user.git").ignore(repository(state), node:get_id()) end
      end,
      switch_branch = function(state) require("user.git_prompts").switch_branch(repository(state)) end,
      new_branch = function(state) require("user.git_prompts").new_branch(repository(state)) end,
      delete_branch = function(state) require("user.git_prompts").delete_branch(repository(state)) end,
      stash_changes = function(state) require("user.git_prompts").stash(repository(state)) end,
      pop_stash = function(state) require("user.git_prompts").pop_stash(repository(state)) end,
      drop_stash = function(state) require("user.git_prompts").drop_stash(repository(state)) end,
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
        -- as <Tab> and <S-Tab> change buffers outside the tree
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
          bd = false,
          d = false,
        },
      },
    },
    git_status = {
      window = {
        mappings = {
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
