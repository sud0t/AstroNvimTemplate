-- Go, on top of the AstroCommunity go pack (community.lua):
--   gopls           LSP: completion, diagnostics (with the staticcheck analyzers), inlay hints, code lenses; it also
--                   formats (gofumpt). Go files are formatted and their imports organized on save, the Go convention
--                   (everything else keeps format on save off; <Leader>uf toggles it per buffer).
--   golangci-lint   linter, through golangci-lint-langserver (diagnostics appear after a save; a project's
--                   .golangci.yml is picked up)
--   delve           debugger, through nvim-dap-go: the usual <Leader>d keys, plus <Leader>dt to debug the test
--                   under the cursor
--   neotest         test runner with neotest-golang (<Leader>T, see `astrocommunity.test.neotest`)
--   gopher.nvim     struct tags, `if err != nil`, interface stubs, test skeletons, doc comments (<Leader>G)
-- Everything is installed through Mason and nothing loads before it is needed: the language servers start with
-- the first Go buffer, the debugger with the first debug key, neotest and gopher.nvim with their first mapping.

local function is_gopls(client) return client.name == "gopls" end

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

      local astrocore = require "astrocore"
      local format_on_save = opts.formatting.format_on_save
      format_on_save.enabled = true
      format_on_save.allow_filetypes = astrocore.list_insert_unique(format_on_save.allow_filetypes, { "go" })

      return astrocore.extend_tbl(opts, {
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
        mappings = {
          n = {
            ["<Leader>G"] = { desc = "Go", cond = is_gopls },
            ["<Leader>Gt"] = { gopher { "GoTagAdd", "json" }, desc = "Add json struct tags", cond = is_gopls },
            ["<Leader>GT"] = { cmdline "GoTagAdd ", desc = "Add struct tags...", cond = is_gopls },
            ["<Leader>Gr"] = { gopher "GoTagClear", desc = "Remove struct tags", cond = is_gopls },
            ["<Leader>Ge"] = { gopher "GoIfErr", desc = "Insert if err != nil", cond = is_gopls },
            ["<Leader>Gi"] = { cmdline "GoImpl ", desc = "Implement interface...", cond = is_gopls },
            ["<Leader>Gc"] = { gopher "GoCmt", desc = "Add doc comment", cond = is_gopls },
            ["<Leader>Ga"] = { gopher "GoTestAdd", desc = "Add test for function", cond = is_gopls },
            ["<Leader>GA"] = { gopher "GoTestsAll", desc = "Add tests for all functions", cond = is_gopls },
            ["<Leader>Gm"] = { gopher { "GoMod", "tidy" }, desc = "go mod tidy", cond = is_gopls },
            ["<Leader>Gg"] = { gopher { "GoGenerate", "%" }, desc = "go generate (file)", cond = is_gopls },
            ["<Leader>Gd"] = { cmdline "GoGet ", desc = "go get...", cond = is_gopls },
            ["<Leader>dt"] = {
              function() require("dap-go").debug_test() end,
              desc = "Debug Go test at cursor",
              cond = is_gopls,
            },
            ["<Leader>dT"] = {
              function() require("dap-go").debug_last_test() end,
              desc = "Debug last Go test",
              cond = is_gopls,
            },
          },
          x = {
            ["<Leader>G"] = { desc = "Go", cond = is_gopls },
            -- `:` from visual mode fills in the '<,'> range: tags for the selected fields only
            ["<Leader>Gt"] = { ":GoTagAdd json<CR>", desc = "Add json struct tags", cond = is_gopls },
            ["<Leader>GT"] = { ":GoTagAdd ", desc = "Add struct tags...", cond = is_gopls },
            ["<Leader>Gr"] = { ":GoTagRm json<CR>", desc = "Remove json struct tags", cond = is_gopls },
          },
        },
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
      -- The pack installs these for gopher.nvim. Both also have a none-ls builtin, which mason-null-ls would
      -- register whenever none-ls happens to be loaded (it is not for Go, see plugins/none-ls.lua), and a none-ls
      -- formatter takes formatting away from gopls (gofumpt). gopls and gopher.nvim cover both.
      opts.handlers = opts.handlers or {}
      opts.handlers.goimports = function() end
      opts.handlers.gomodifytags = function() end
    end,
  },
  -- The pack loads nvim-dap-go, and with it the whole debugger stack, on every Go buffer. As for Python
  -- (plugins/dap.lua), load it together with nvim-dap instead, on the first debug key.
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
