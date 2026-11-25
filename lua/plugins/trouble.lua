-- trouble.nvim: lists of diagnostics, quickfix entries and todo comments, on <Leader>z (<Leader>x closes a buffer).

---@type LazySpec
return {
  "folke/trouble.nvim",
  cmd = "Trouble",
  opts = function()
    local get_icon = require("astroui").get_icon
    return {
      keys = { ["<ESC>"] = "close", ["q"] = "close", ["<C-E>"] = "close" },
      icons = {
        indent = { fold_open = get_icon "FoldOpened", fold_closed = get_icon "FoldClosed" },
        folder_closed = get_icon "FolderClosed",
        folder_open = get_icon "FolderOpen",
      },
    }
  end,
  specs = {
    {
      "AstroNvim/astrocore",
      opts = {
        mappings = {
          n = {
            ["<Leader>zx"] = {
              "<Cmd>Trouble diagnostics toggle filter.buf=0<CR>",
              desc = "Trouble Document Diagnostics",
            },
            ["<Leader>zX"] = { "<Cmd>Trouble diagnostics toggle<CR>", desc = "Trouble Workspace Diagnostics" },
            ["<Leader>zL"] = { "<Cmd>Trouble loclist toggle<CR>", desc = "Trouble Location List" },
            ["<Leader>zQ"] = { "<Cmd>Trouble quickfix toggle<CR>", desc = "Trouble Quickfix List" },
            ["<Leader>zt"] = { "<Cmd>Trouble todo<CR>", desc = "Trouble Todo" },
            ["<Leader>zT"] = {
              "<Cmd>Trouble todo filter={tag={TODO,FIX,FIXME}}<CR>",
              desc = "Trouble Todo/Fix/Fixme",
            },
          },
        },
      },
    },
    {
      "folke/snacks.nvim",
      opts = {
        picker = {
          actions = {
            trouble_open = {
              -- required at the key press: here, it would load trouble at every start
              action = function(...) return require("trouble.sources.snacks").actions.trouble_open.action(...) end,
              desc = "smart-open-with-trouble",
            },
          },
          win = { input = { keys = { ["<c-t>"] = { "trouble_open", mode = { "n", "i" } } } } },
        },
      },
    },
  },
}
