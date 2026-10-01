-- AstroCore provides a central place to modify mappings, vim options, autocommands, and more!
---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@type AstroCoreOpts
  opts = {
    -- Configure core features of AstroNvim
    features = {
      large_buf = { size = 1024 * 256, lines = 10000 }, -- set global limits for large files for disabling features like treesitter
      autopairs = true, -- enable autopairs at start
      cmp = true, -- enable completion at start
      diagnostics = { virtual_text = true, virtual_lines = false }, -- diagnostic settings on startup
      highlighturl = true, -- highlight URLs at start
      notifications = true, -- enable notifications at start
    },
    -- Diagnostics configuration (for vim.diagnostics.config({...})) when diagnostics are on
    diagnostics = {
      virtual_text = true,
      underline = true,
    },
    -- passed to `vim.filetype.add`
    filetypes = {
      -- see `:h vim.filetype.add` for usage
      filename = {
        [".zshrc"] = "zsh",
      },
    },
    -- vim options can be configured here
    options = {
      opt = { -- vim.opt.<key>
        relativenumber = false, -- sets vim.opt.relativenumber
        number = true, -- sets vim.opt.number
        spell = false, -- sets vim.opt.spell
        signcolumn = "yes", -- sets vim.opt.signcolumn to yes
        wrap = false, -- sets vim.opt.wrap
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
      -- first key is the mode
      i = {
        -- Insert mode
        ["<C-h>"] = { "<Left>", desc = "Move left" },
        ["<C-j>"] = { "<Down>", desc = "Move down" },
        ["<C-k>"] = { "<Up>", desc = "Move up" },
        ["<C-l>"] = { "<Right>", desc = "Move right" },
        ["<C-a>"] = { "<ESC>^i", desc = "move beginning of line" },
        ["<C-e>"] = { "<End>", desc = "move end of line" },
      },
      n = {
        -- Precognition toggle
        ["<Leader>ue"] = { "<Cmd>Precognition toggle<CR>", desc = "Toggle precognition" },
        -- Fold open / fold close
        ["<Leader>C"] = false,
        ["<Leader>c"] = { false, desc = "Folds close/open" }, -- `false` drops AstroNvim's close buffer, keeping only the group
        ["<Leader>cc"] = { "<Cmd>foldclose<CR>", desc = "Close fold" },
        ["<Leader>cC"] = { "<Cmd>foldopen<CR>", desc = "Open fold" },
        -- Toggle wrap
        ["<Leader>w"] = { false, desc = "Toggle wrap" }, -- `false` drops AstroNvim's save, keeping only the group
        ["<Leader>ww"] = { function() require("astrocore.toggles").wrap() end, desc = "Toggle wrap" },
        -- Neotree better toggle key
        ["\\"] = { "<Cmd>Neotree toggle<CR>", desc = "Toggle Explorer" },
        -- Change list keys so I can use leader x for closing buffers
        ["<Leader>zq"] = { "<Cmd>copen<CR>", desc = "Quickfix List" },
        ["<Leader>zl"] = { "<Cmd>lopen<CR>", desc = "Location List" },
        -- Manage Buffers
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
        -- tables with just a `desc` key will be registered with which-key if it's installed
        -- this is useful for naming menus
        ["<Leader>z"] = { desc = "Quickfix/Lists" },
      },
      t = {
        ["<C-x>"] = { "<C-\\><C-n>", desc = "Exit terminal mode" },
        ["<C-f>"] = { "<Right>", desc = "Fill autosearch" },
      },
    },
  },
}
