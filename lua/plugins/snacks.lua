-- The Git pickers of a file buffer only look: what changes the repository is done from the file tree
-- (plugins/neo-tree.lua), with its <Leader>g keys. The pickers the tree opens have no keys of their own for it.

--- Enter on a commit shows it in Diffview, where snacks would check it out.
local function show_commit(picker, item)
  picker:close()
  if not item then return end
  local args = { "-C" .. vim.fn.fnameescape(item.cwd), item.commit .. "^!" }
  if item.file then vim.list_extend(args, { "--", vim.fn.fnameescape(item.file) }) end
  vim.cmd.DiffviewOpen(args)
end

-- <Tab> selects, as in every other picker, where snacks would stage; <C-r> would throw the changes away
local no_staging = {
  input = { keys = { ["<Tab>"] = { "select_and_next", mode = { "i", "n" } }, ["<c-r>"] = false } },
}

-- <C-a> selects all, as in every other picker, where snacks would make a branch; <C-x> would delete one
local no_branch_keys = {
  input = { keys = { ["<c-a>"] = { "select_all", mode = { "n", "i" } }, ["<c-x>"] = false } },
}

local sources = {
  git_log = { confirm = show_commit },
  git_log_file = { confirm = show_commit },
  git_log_line = { confirm = show_commit },
  git_status = { win = no_staging },
  git_diff = { win = no_staging },
  git_branches = { win = no_branch_keys },
}

---@type LazySpec
return {
  "folke/snacks.nvim",
  opts = function(_, opts)
    opts.picker = vim.tbl_deep_extend("force", opts.picker or {}, { sources = sources })

    local preset = opts.dashboard.preset
    preset.header = table.concat({
      "███    ██ ██    ██ ██ ███    ███",
      "████   ██ ██    ██ ██ ████  ████",
      "██ ██  ██ ██    ██ ██ ██ ████ ██",
      "██  ██ ██  ██  ██  ██ ██  ██  ██",
      "██   ████   ████   ██ ██      ██",
    }, "\n")
    -- AstroNvim's New File entry presses <Leader>n, which is unmapped here (plugins/astrocore.lua)
    for _, entry in ipairs(preset.keys) do
      if entry.action == "<Leader>n" then entry.action = ":enew" end
    end
  end,
}
