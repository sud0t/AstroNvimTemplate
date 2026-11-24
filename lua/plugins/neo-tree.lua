-- The file tree's keys.
--   <Tab> / <S-Tab>        next and previous source (Files, Buffers, Git), as they change buffers outside the tree
--   <Tab> in visual mode   selects the highlighted files, or unselects them when all of them are selected
--   <Esc>                  drops the selection
--   <Leader>               only the tree's own keys: Git commands in the Git source (<Leader>g), find and terminal
--                          in the folder under the cursor (<Leader>f in Files, <Leader>t), close the buffer under
--                          the cursor in Buffers (<Leader>x). The global <Leader> keys do nothing in the tree and
--                          stay out of its which-key popup.
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

---@type LazySpec
return {
  "nvim-neo-tree/neo-tree.nvim",
  opts = {
    commands = {
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
          ["<Leader>ff"] = { "find_files_in_dir", desc = "Find files in this folder" },
          ["<Leader>fF"] = { "find_all_files_in_dir", desc = "Find all files in this folder" },
          ["<Leader>fw"] = { "find_words_in_dir", desc = "Find words in this folder" },
          ["<Leader>fW"] = { "find_all_words_in_dir", desc = "Find words in all files in this folder" },
        },
      },
    },
    buffers = {
      window = {
        mappings = {
          bd = false,
          d = false,
          ["<Leader>x"] = { "buffer_delete", desc = "Close buffer" },
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
          ["<Leader>ga"] = { "git_add_file", desc = "Stage file" },
          ["<Leader>gA"] = { "git_add_all", desc = "Stage all" },
          ["<Leader>gu"] = { "git_unstage_file", desc = "Unstage file" },
          ["<Leader>gt"] = { "git_toggle_file_stage", desc = "Stage or unstage file" },
          ["<Leader>gr"] = { "git_revert_file", desc = "Revert file" },
          ["<Leader>gc"] = { "git_commit", desc = "Commit" },
          ["<Leader>gg"] = { "git_commit_and_push", desc = "Commit and push" },
          ["<Leader>gp"] = { "git_push", desc = "Push" },
          ["<Leader>gl"] = { "git_pull", desc = "Pull" },
          ["<Leader>gU"] = { "git_undo_last_commit", desc = "Undo last commit" },
        },
      },
    },
  },
}
