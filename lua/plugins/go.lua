-- Go, on top of the AstroCommunity go pack: imports organized with the format on save (plugins/astrolsp.lua),
-- golangci-lint, gopher.nvim on <Leader>G, and the debugger loaded on its first key, not on every Go buffer.

local function is_gopls(client) return client.name == "gopls" end

--- Makes every mapping in `maps` exist only in the buffers of the clients `cond` accepts.
local function only_for(cond, maps)
  for _, mode_maps in pairs(maps) do
    for _, map in pairs(mode_maps) do
      map.cond = cond
    end
  end
  return maps
end

-- gopls keeps imports apart from formatting: they are the `source.organizeImports` code action
local function organize_imports(bufnr)
  if not require("astrolsp").autoformat_enabled(bufnr) then return end
  local client = vim.lsp.get_clients({ bufnr = bufnr, name = "gopls" })[1]
  if not client then return end
  local start = { line = 0, character = 0 }
  local result = client:request_sync("textDocument/codeAction", {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    range = { start = start, ["end"] = start },
    context = { only = { "source.organizeImports" }, diagnostics = {} },
  }, 1000, bufnr)
  for _, action in ipairs(result and result.result or {}) do
    if action.edit then vim.lsp.util.apply_workspace_edit(action.edit, client.offset_encoding) end
  end
end

-- gopher.nvim's commands; a table adds arguments: gopher { "GoTagAdd", "json" }
local function gopher(cmd)
  return function() vim.cmd(type(cmd) == "table" and table.concat(cmd, " ") or cmd) end
end

-- commands that need an argument typed after them are put on the command line instead
local function cmdline(text)
  return function() vim.api.nvim_feedkeys(":" .. text, "n", false) end
end

---@type LazySpec
return {
  {
    "AstroNvim/astrolsp",
    ---@param opts AstroLSPOpts
    opts = function(_, opts)
      -- the pack builds with `-tags integration`, which hides every file that is excluded under that tag
      -- (`//go:build !integration`) from gopls; a project that needs tags sets them in its own gopls settings
      local gopls = vim.tbl_get(opts, "config", "gopls", "settings", "gopls")
      if gopls then gopls.buildFlags = nil end

      return require("astrocore").extend_tbl(opts, {
        autocmds = {
          go_organize_imports = {
            cond = is_gopls,
            {
              event = "BufWritePre",
              desc = "Organize Go imports (with format on save)",
              callback = function(args) organize_imports(args.buf) end,
            },
          },
        },
        mappings = only_for(is_gopls, {
          n = {
            ["<Leader>G"] = { desc = "Go" },
            ["<Leader>Gt"] = { gopher { "GoTagAdd", "json" }, desc = "Add json struct tags" },
            ["<Leader>GT"] = { cmdline "GoTagAdd ", desc = "Add struct tags..." },
            ["<Leader>Gr"] = { gopher "GoTagClear", desc = "Remove struct tags" },
            ["<Leader>Ge"] = { gopher "GoIfErr", desc = "Insert if err != nil" },
            ["<Leader>Gi"] = { cmdline "GoImpl ", desc = "Implement interface..." },
            ["<Leader>Gc"] = { gopher "GoCmt", desc = "Add doc comment" },
            ["<Leader>Ga"] = { gopher "GoTestAdd", desc = "Add test for function" },
            ["<Leader>GA"] = { gopher "GoTestsAll", desc = "Add tests for all functions" },
            ["<Leader>Gm"] = { gopher { "GoMod", "tidy" }, desc = "go mod tidy" },
            ["<Leader>Gg"] = { gopher { "GoGenerate", "%" }, desc = "go generate (file)" },
            ["<Leader>Gd"] = { cmdline "GoGet ", desc = "go get..." },
            ["<Leader>dt"] = { function() require("dap-go").debug_test() end, desc = "Debug Go test at cursor" },
            ["<Leader>dT"] = { function() require("dap-go").debug_last_test() end, desc = "Debug last Go test" },
          },
          x = {
            ["<Leader>G"] = { desc = "Go" },
            -- `:` from visual mode fills in the '<,'> range: tags for the selected fields only
            ["<Leader>Gt"] = { ":GoTagAdd json<CR>", desc = "Add json struct tags" },
            ["<Leader>GT"] = { ":GoTagAdd ", desc = "Add struct tags..." },
            ["<Leader>Gr"] = { ":GoTagRm json<CR>", desc = "Remove json struct tags" },
          },
        }),
      })
    end,
  },
  {
    "WhoIsSethDaniel/mason-tool-installer.nvim",
    optional = true,
    opts = function(_, opts)
      -- the linter and its language server (mason-lspconfig enables `golangci_lint_ls` once it is installed)
      opts.ensure_installed =
        require("astrocore").list_insert_unique(opts.ensure_installed, { "golangci-lint", "golangci-lint-langserver" })
    end,
  },
  {
    "jay-babu/mason-null-ls.nvim",
    optional = true,
    opts = function(_, opts)
      -- Installed for gopher.nvim and golangci_lint_ls. Once another filetype has loaded none-ls, mason-null-ls
      -- would register each as a none-ls source too: a formatter over gopls, and every lint diagnostic twice.
      opts.handlers = opts.handlers or {}
      for _, tool in ipairs { "goimports", "gomodifytags", "golangci_lint", "impl" } do
        opts.handlers[tool] = function() end
      end
    end,
  },
  -- The pack loads nvim-dap-go, and with it the debugger stack, on every Go buffer: load it with nvim-dap, on
  -- the first debug key (as for Python, plugins/dap.lua).
  {
    "leoluz/nvim-dap-go",
    ft = function() return {} end, -- drop the pack's `ft = "go"` trigger
  },
  {
    "mfussenegger/nvim-dap",
    optional = true,
    dependencies = { "leoluz/nvim-dap-go" },
  },
  {
    "jay-babu/mason-nvim-dap.nvim",
    optional = true,
    opts = function(_, opts)
      -- nvim-dap-go sets up the adapter and the configurations; mason-nvim-dap would add a second set
      opts.handlers = opts.handlers or {}
      opts.handlers.delve = function() end
    end,
  },
  {
    "olexsmir/gopher.nvim",
    ft = function() return {} end, -- it only provides commands: load it with the first one
    cmd = {
      "GoTagAdd",
      "GoTagRm",
      "GoTagClear",
      "GoMod",
      "GoGet",
      "GoWork",
      "GoImpl",
      "GoTestAdd",
      "GoTestsAll",
      "GoTestsExp",
      "GoGenerate",
      "GoCmt",
      "GoIfErr",
      "GoNew",
      "GoJson",
      "GoInstallDeps",
      "GoInstallDepsSync",
      "GopherLog",
    },
  },
}
