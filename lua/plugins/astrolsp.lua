---@type LazySpec
return {
  "AstroNvim/astrolsp",
  ---@type AstroLSPOpts
  opts = {
    diagnostics = {
      update_in_insert = false,
    },
    features = {
      codelens = true,
      inlay_hints = true, -- <Leader>uH toggles them per buffer
      semantic_tokens = true,
    },
    formatting = {
      format_on_save = {
        enabled = false, -- plugins/go.lua turns it on, for Go alone
        allow_filetypes = {},
        ignore_filetypes = {},
      },
      disabled = {},
      timeout_ms = 1000,
    },
    servers = {}, -- for servers installed outside Mason
    -- passed to `vim.lsp.config`
    config = {
      -- ruff logs its routine INFO/WARN messages to stderr, which ends up in lsp.log as errors
      ruff = { init_options = { settings = { logLevel = "error" } } },
      -- the same for clangd (it logs every request, tens of thousands of lsp.log lines per session) and taplo
      clangd = { cmd = { "clangd", "--log=error" } },
      taplo = {
        cmd_env = { RUST_LOG = "error" },
        -- Without a workspace folder taplo treats a file as excluded: a TOML file outside a git repository
        -- (~/.config/...) gets "this document has been excluded" as its only diagnostic and no formatting.
        -- So fall back to the file's own directory.
        root_dir = function(bufnr, on_dir)
          local root = vim.fs.root(bufnr, { ".taplo.toml", "taplo.toml", ".git" })
          local name = vim.api.nvim_buf_get_name(bufnr)
          on_dir(root or (name ~= "" and vim.fs.dirname(name)) or vim.fn.getcwd())
        end,
      },
    },
    handlers = {
      -- mason-lspconfig starts every installed server, and the stylua package also ships a language server
      -- mode; the lua pack already formats with stylua through none-ls, so this would format Lua twice
      stylua = false,
    },
    autocmds = {
      -- No codelens refresh group here: Neovim 0.12 keeps the lenses current itself once AstroLSP has called
      -- `vim.lsp.codelens.enable()`, and re-enabling them per buffer on BufEnter/InsertLeave would undo
      -- <Leader>uL.

      -- ghost text with the parameters (and defaults) still missing from the call under the cursor
      signature_ghost = {
        cond = "textDocument/signatureHelp",
        {
          event = { "CursorMovedI", "TextChangedI" },
          desc = "Update signature ghost text",
          callback = function(args) require("user.signature_ghost").schedule(args.buf) end,
        },
        {
          event = { "InsertLeave", "BufLeave" },
          desc = "Clear signature ghost text",
          callback = function(args) require("user.signature_ghost").clear(args.buf) end,
        },
      },
    },
    mappings = {
      n = {
        -- AstroLSP's `vim.lsp.codelens.run()` asks the server for the lenses again, and gives up ("No codelens
        -- at current line") when a busy server answers "content modified" (rust-analyzer, right after an edit
        -- or while indexing). So run the lenses already on screen, and only ask when none are cached.
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
        ["<Leader>uG"] = {
          function() require("user.signature_ghost").toggle() end,
          desc = "Toggle signature ghost text",
          cond = "textDocument/signatureHelp",
        },
      },
      i = {
        ["<M-s>"] = {
          function() require("user.signature_ghost").accept() end,
          desc = "Insert signature ghost text / next placeholder",
          cond = "textDocument/signatureHelp",
        },
      },
    },
  },
}
