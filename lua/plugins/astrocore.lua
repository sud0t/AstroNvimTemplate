---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@type AstroCoreOpts
  opts = {
    features = {
      large_buf = { size = 1024 * 256, lines = 10000 }, -- past either limit, treesitter and the like are off
    },
    options = {
      opt = {
        relativenumber = false,
        scrolloff = 10,
      },
      g = {
        loaded_perl_provider = 0,
        loaded_ruby_provider = 0,
        loaded_node_provider = 0, -- no Node remote plugins in use (the python3 provider stays: molten needs it)
      },
    },
    mappings = {
      i = {
        ["<C-h>"] = { "<Left>", desc = "Move left" },
        ["<C-j>"] = { "<Down>", desc = "Move down" },
        ["<C-k>"] = { "<Up>", desc = "Move up" },
        ["<C-l>"] = { "<Right>", desc = "Move right" },
        ["<C-a>"] = { "<C-o>^", desc = "Move to line start" },
        ["<C-e>"] = { "<End>", desc = "Move to line end" },
      },
      n = {
        ["<Leader>n"] = false, -- AstroNvim's new file; the dashboard's entry runs :enew (plugins/snacks.lua)
        -- AstroNvim's exit and force quit; <C-Q> is spelled as AstroNvim spells it, or its mapping stays
        ["<Leader>Q"] = false,
        ["<C-Q>"] = false,
        -- the only comment key: it runs Neovim's own gc/gcc mappings, which polish.lua moves to these names
        ["<Leader>/"] = { "<Plug>(comment-line)", remap = true, desc = "Toggle comment line" },
        gco = false, -- AstroNvim's add comment below and above
        gcO = false,
        -- AstroNvim's branch and stash pickers: the repository is changed from the file tree (plugins/neo-tree.lua)
        ["<Leader>gb"] = false,
        ["<Leader>gT"] = false,
        ["<Leader>C"] = false, -- AstroNvim's force close buffer: <Leader>X does that
        ["<Leader>c"] = { false, desc = "Folds close/open" }, -- `false` drops AstroNvim's close buffer, the group stays
        ["<Leader>cc"] = { "<Cmd>foldclose<CR>", desc = "Close fold" },
        ["<Leader>cC"] = { "<Cmd>foldopen<CR>", desc = "Open fold" },
        ["<Leader>w"] = { false, desc = "Toggle wrap" }, -- the same for AstroNvim's save
        ["<Leader>ww"] = { function() require("astrocore.toggles").wrap() end, desc = "Toggle wrap" },
        ["\\"] = { "<Cmd>Neotree toggle<CR>", desc = "Toggle Explorer" },
        ["<Leader>e"] = false, -- AstroNvim's explorer toggle and focus: \ does that
        ["<Leader>o"] = false,
        ["<Leader>R"] = false, -- AstroNvim's rename file: <Leader>R is the Rust group (plugins/rust.lua)
        -- the lists move to <Leader>z, so that <Leader>x closes a buffer without waiting for a second key
        ["<Leader>zq"] = { "<Cmd>copen<CR>", desc = "Quickfix List" },
        ["<Leader>zl"] = { "<Cmd>lopen<CR>", desc = "Location List" },
        ["<Leader>xq"] = false,
        ["<Leader>xl"] = false,
        ["<Leader>x"] = { function() require("astrocore.buffer").close() end, desc = "Close buffer" },
        ["<Leader>X"] = { function() require("astrocore.buffer").close(0, true) end, desc = "Force close buffer" },
        ["<Tab>"] = {
          function() require("astrocore.buffer").nav(vim.v.count1) end,
          desc = "Next buffer",
        },
        ["<S-Tab>"] = {
          function() require("astrocore.buffer").nav(-vim.v.count1) end,
          desc = "Previous buffer",
        },
        ["<Leader>z"] = { desc = "Quickfix/Lists" },
      },
      x = {
        ["<Leader>/"] = { "<Plug>(comment-operator)", remap = true, desc = "Toggle comment" },
      },
      t = {
        ["<C-x>"] = { "<C-\\><C-n>", desc = "Exit terminal mode" },
        ["<C-f>"] = { "<Right>", desc = "Accept shell autosuggestion" },
      },
    },
  },
}
