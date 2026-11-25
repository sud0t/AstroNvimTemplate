-- The file tree's keys.
--   <Tab> / <S-Tab>        next and previous source (Files, Buffers, Git), as they change buffers outside the tree
--   <Tab> in visual mode   selects the highlighted files, or unselects them when all of them are selected
--   <Esc>                  drops the selection
--   <Leader>               only the tree's own keys, the same in every source, each for the row under the cursor:
--                          Git commands (<Leader>g), find and terminal in its folder (<Leader>f, <Leader>t), close
--                          its buffer (<Leader>x). The global <Leader> keys do nothing in the tree and stay out of
--                          its which-key popup.
--   <Leader>gc, <Leader>gg write the commit message in a floating window (user/git_commit.lua), in place of
--                          neo-tree's one-line prompt, and first stage the file under the cursor when it has
--                          changes of which none is staged.
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

---@param state neotree.State
---@param push? boolean
local function commit(state, push)
  local node = state.tree:get_node()
  local on_file = node and (node.type == "file" or node.type == "link")
  require("user.git_commit").commit {
    dir = state.path,
    stage = on_file and node:get_id() or nil,
    push = push,
    on_change = function()
      local events = require "neo-tree.events"
      events.fire_event(events.GIT_EVENT)
    end,
  }
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
  local node = state.tree:get_node()
  if not node or node.type == "message" then return end
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
      commit_in_editor_and_push = function(state) commit(state, true) end,
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
        ["<Leader>gr"] = { "git_revert_file", desc = "Revert file" },
        ["<Leader>gc"] = { "commit_in_editor", desc = "Commit" },
        ["<Leader>gg"] = { "commit_in_editor_and_push", desc = "Commit and push" },
        ["<Leader>gp"] = { "git_push", desc = "Push" },
        ["<Leader>gl"] = { "git_pull", desc = "Pull" },
        ["<Leader>gU"] = { "git_undo_last_commit", desc = "Undo last commit" },
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
