---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@type AstroCoreOpts
  opts = {
    features = {
      large_buf = { size = 1024 * 256, lines = 10000 }, -- past either limit, treesitter and the like are off for the buffer
      autopairs = true,
      cmp = true,
      diagnostics = { virtual_text = true, virtual_lines = false },
      highlighturl = true,
      notifications = true,
    },
    -- passed to `vim.diagnostic.config` while diagnostics are on
    diagnostics = {
      virtual_text = true,
      underline = true,
    },
    -- passed to `vim.filetype.add`
    filetypes = {
      filename = {
        [".zshrc"] = "zsh",
      },
    },
    options = {
      opt = {
        relativenumber = false,
        number = true,
        spell = false,
        signcolumn = "yes",
        wrap = false,
      },
      g = {
        loaded_perl_provider = 0,
        loaded_ruby_provider = 0,
        loaded_node_provider = 0, -- no Node remote plugins in use (the python3 provider stays: molten needs it)
      },
      o = {
        scrolloff = 10,
      },
    },
    mappings = {
      i = {
        ["<C-h>"] = { "<Left>", desc = "Move left" },
        ["<C-j>"] = { "<Down>", desc = "Move down" },
        ["<C-k>"] = { "<Up>", desc = "Move up" },
        ["<C-l>"] = { "<Right>", desc = "Move right" },
        -- <C-o> stays in insert mode: no InsertLeave (LaTeX autosave, multicursor hand-over) for a cursor move
        ["<C-a>"] = { "<C-o>^", desc = "move beginning of line" },
        ["<C-e>"] = { "<End>", desc = "move end of line" },
      },
      n = {
        ["<Leader>ue"] = { "<Cmd>Precognition toggle<CR>", desc = "Toggle precognition" },
        ["<Leader>k"] = { function() require("user.cheatsheet").open() end, desc = "Keys cheat sheet (non-leader)" },
        ["<Leader>C"] = false, -- AstroNvim's force close buffer: <Leader>X does that
        ["<Leader>c"] = { false, desc = "Folds close/open" }, -- `false` drops AstroNvim's close buffer, keeping only the group
        ["<Leader>cc"] = { "<Cmd>foldclose<CR>", desc = "Close fold" },
        ["<Leader>cC"] = { "<Cmd>foldopen<CR>", desc = "Open fold" },
        ["<Leader>w"] = { false, desc = "Toggle wrap" }, -- `false` drops AstroNvim's save, keeping only the group
        ["<Leader>ww"] = { function() require("astrocore.toggles").wrap() end, desc = "Toggle wrap" },
        ["\\"] = { "<Cmd>Neotree toggle<CR>", desc = "Toggle Explorer" },
        ["<Leader>e"] = false, -- AstroNvim's explorer toggle and focus: \ does that
        ["<Leader>o"] = false,
        ["<Leader>R"] = false, -- AstroNvim's rename file; <Leader>R is the Rust command group in Rust buffers (plugins/rust.lua)
        -- the lists move to <Leader>z, so that <Leader>x closes a buffer without waiting for a second key
        ["<Leader>zq"] = { "<Cmd>copen<CR>", desc = "Quickfix List" },
        ["<Leader>zl"] = { "<Cmd>lopen<CR>", desc = "Location List" },
        ["<Leader>xq"] = false,
        ["<Leader>xl"] = false,
        ["<Leader>x"] = { function() require("astrocore.buffer").close() end, desc = "Close buffer" },
        ["<Leader>X"] = { function() require("astrocore.buffer").close(0, true) end, desc = "Force close buffer" },
        ["<tab>"] = {
          function() require("astrocore.buffer").nav(vim.v.count1) end,
          desc = "Next buffer",
        },
        ["<S-tab>"] = {
          function() require("astrocore.buffer").nav(-vim.v.count1) end,
          desc = "Previous buffer",
        },
        ["<Leader>z"] = { desc = "Quickfix/Lists" },
      },
      t = {
        ["<C-x>"] = { "<C-\\><C-n>", desc = "Exit terminal mode" },
        ["<C-f>"] = { "<Right>", desc = "Fill autosearch" },
      },
    },
  },
}
