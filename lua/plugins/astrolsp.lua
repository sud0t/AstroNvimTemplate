---@type LazySpec
return {
  "AstroNvim/astrolsp",
  ---@type AstroLSPOpts
  opts = {
    features = {
      inlay_hints = true, -- <Leader>uH toggles them per buffer
    },
    formatting = {
      -- Go's convention; every other filetype is formatted by hand
      format_on_save = { enabled = true, allow_filetypes = { "go" } },
    },
    config = {
      -- ruff logs its routine INFO/WARN messages to stderr, which ends up in lsp.log as errors
      ruff = { init_options = { settings = { logLevel = "error" } } },
      -- the same for clangd (it logs every request, tens of thousands of lsp.log lines per session) and taplo
      clangd = { cmd = { "clangd", "--log=error" } },
      taplo = {
        cmd_env = { RUST_LOG = "error" },
        -- taplo treats a file without a workspace folder as excluded ("this document has been excluded", no
        -- formatting): a TOML file outside a git repository gets its own directory as the root.
        root_dir = function(bufnr, on_dir)
          local root = vim.fs.root(bufnr, { ".taplo.toml", "taplo.toml", ".git" })
          local name = vim.api.nvim_buf_get_name(bufnr)
          on_dir(root or (name ~= "" and vim.fs.dirname(name)) or vim.fn.getcwd())
        end,
      },
    },
    handlers = {
      -- mason-lspconfig starts every installed server, and the stylua package has a language server mode: Lua
      -- would be formatted twice, since the lua pack already runs stylua through none-ls
      stylua = false,
    },
    mappings = {
      n = {
        -- `vim.lsp.codelens.run()` asks again and fails on rust-analyzer's "content modified": run the lens
        -- already on screen, and ask only when none is cached.
        ["<Leader>lL"] = {
          function()
            local bufnr = vim.api.nvim_get_current_buf()
            local row = vim.api.nvim_win_get_cursor(0)[1] - 1
            local candidates = {}
            for _, item in ipairs(vim.lsp.codelens.get { bufnr = bufnr }) do
              if item.lens.range.start.line == row and item.lens.command then
                local client = vim.lsp.get_client_by_id(item.client_id)
                if client then table.insert(candidates, { client = client, lens = item.lens }) end
              end
            end
            if #candidates == 0 then return vim.lsp.codelens.run() end
            local function run(candidate) candidate.client:exec_cmd(candidate.lens.command, { bufnr = bufnr }) end
            if #candidates == 1 then return run(candidates[1]) end
            vim.ui.select(candidates, {
              prompt = "Code lenses: ",
              kind = "codelens",
              format_item = function(candidate) return candidate.lens.command.title end,
            }, function(candidate)
              if candidate then run(candidate) end
            end)
          end,
          desc = "LSP CodeLens run",
          cond = "textDocument/codeLens",
        },
      },
    },
  },
}
