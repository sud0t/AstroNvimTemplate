-- Rust overrides on top of the AstroCommunity rust pack (community.lua)

-- Debugging goes through rustaceanvim rather than a hand-written nvim-dap configuration: `:RustLsp debuggables`
-- asks rust-analyzer for the cargo targets of the workspace (binaries, tests, examples), builds the chosen one
-- with `cargo build --message-format=json` and launches the executable named in the build output. The mappings
-- below put that behind the usual debugger keys, so nothing has to be typed.

---@type rustaceanvim.RACargoRunnableArgs?
local last_target
local tracking = false
-- `:RustLsp debuggables!` would relaunch the last target, but with its errors muted (a failed build just does
-- nothing). Remember the target here instead and relaunch it with errors shown.
local function track_last_target()
  if tracking then return end
  tracking = true
  local cached = require "rustaceanvim.cached_commands"
  local set_last = cached.set_last_debuggable
  cached.set_last_debuggable = function(args)
    last_target = args
    set_last(args)
  end
end

local function debuggables()
  track_last_target()
  vim.cmd.RustLsp "debuggables"
end

local function debug_at_cursor()
  track_last_target()
  vim.cmd.RustLsp "debug"
end

local function debug_last()
  if not last_target then return debuggables() end
  require("rustaceanvim.dap").start(last_target, true)
end

-- Start/Continue: with no session running, pick a cargo target instead of nvim-dap's configuration list
local function continue()
  local dap = require "dap"
  if dap.session() then return dap.continue() end
  debuggables()
end

local function is_rust_analyzer(client) return client.name == "rust-analyzer" end

-- `:RustLsp <cmd>`; a table adds arguments / bang: rust_lsp { "runnables", bang = true } re-runs the last one
local function rust_lsp(cmd)
  return function() vim.cmd.RustLsp(cmd) end
end

local warned_missing_component = false -- rustaceanvim resolves the server command more than once per start

-- rust-analyzer asks for a codelens refresh while it is still indexing a workspace, and answers the
-- `codeLens/resolve` requests Neovim then sends for the "N references" / "N implementations" lenses with
-- "content modified" once indexing finishes. Neovim 0.12 does not retry a failed resolve, so those lenses stay as
-- the blank placeholder lines it draws above the item until the next request (an edit, a reload, or the server
-- asking again). Re-request once the loading phases (`rustAnalyzer/...` progress tokens; flycheck runs are
-- `rust-analyzer/flycheck/...`) have been quiet for a moment, through the same handler the server's request uses.
local refresh_generation = {} ---@type table<integer, integer> client id -> last scheduled refresh
local function refresh_codelens_after_indexing(ev)
  local params = ev.data.params
  if params.value.kind ~= "end" or type(params.token) ~= "string" or not vim.startswith(params.token, "rustAnalyzer/") then
    return
  end
  local client = vim.lsp.get_client_by_id(ev.data.client_id)
  if not client or not is_rust_analyzer(client) then return end
  local generation = (refresh_generation[client.id] or 0) + 1
  refresh_generation[client.id] = generation
  vim.defer_fn(function()
    if refresh_generation[client.id] ~= generation then return end -- another phase ended since; wait for that one
    refresh_generation[client.id] = nil
    local refresh = vim.lsp.handlers["workspace/codeLens/refresh"]
    if refresh and vim.lsp.get_client_by_id(client.id) then
      refresh(nil, nil, { client_id = client.id, method = "workspace/codeLens/refresh" })
    end
  end, 500)
end

---@type LazySpec
return {
  {
    "AstroNvim/astrocore",
    ---@type AstroCoreOpts
    opts = {
      autocmds = {
        rust_analyzer_codelens = {
          {
            event = "LspProgress",
            desc = "Re-request codelens once rust-analyzer has finished indexing",
            callback = refresh_codelens_after_indexing,
          },
        },
      },
    },
  },
  {
    "mrcjkb/rustaceanvim",
    -- rustaceanvim starts rust-analyzer from its ftplugin, on the FileType event, which for the first file of a
    -- session comes before `User AstroFile` loads AstroLSP. rust-analyzer then started with the plain nvim-lspconfig
    -- config: no clippy, no `target/` exclusion and none of the capabilities the LSP packs add (blink.cmp snippets).
    -- Loading AstroLSP first registers its `vim.lsp.config` entries before the server starts.
    dependencies = { "AstroNvim/astrolsp" },
    -- the pack's `config` already writes these opts into `vim.g.rustaceanvim`
    opts = function(_, opts)
      opts.server = opts.server or {}
      -- use the rust-analyzer that matches the active rustup toolchain; a project pinned to a toolchain without the
      -- component (rust-toolchain.toml) falls back to the stable one, since the bare `rust-analyzer` proxy would
      -- only print "Unknown binary 'rust-analyzer' in official toolchain" and no server would start
      opts.server.cmd = function()
        for _, args in ipairs { "", " --toolchain stable" } do
          local ra_path = vim.fn.system("rustup which" .. args .. " rust-analyzer"):gsub("%s+$", "")
          if vim.v.shell_error == 0 and ra_path ~= "" then
            if args ~= "" and not warned_missing_component then
              warned_missing_component = true
              vim.notify(
                "The active toolchain has no rust-analyzer component (rustup component add rust-analyzer); "
                  .. "using the stable one",
                vim.log.levels.WARN,
                { title = "rust-analyzer" }
              )
            end
            return { ra_path }
          end
        end
        return { "rust-analyzer" } -- rustup missing: whatever is on PATH
      end

      opts.dap = require("astrocore").extend_tbl(opts.dap, {
        -- The pack passes `--liblldb $MASON/share/lldb/lib/liblldb.so`, a path Mason 2 no longer creates
        -- (it is `$MASON/opt/lldb` now), and codelldb panics on start when it gets a missing library. codelldb
        -- finds its bundled liblldb next to its own binary, so no path is needed. Sessions actually run through
        -- nvim-dap's `codelldb` adapter registered by mason-nvim-dap (plugins/dap.lua); rustaceanvim only uses
        -- this one to know it's talking to codelldb (source maps, library paths), or if that adapter is missing.
        adapter = function()
          local codelldb = vim.fn.exepath "codelldb"
          if codelldb == "" then return false end
          return {
            type = "server",
            host = "127.0.0.1",
            port = "${port}",
            executable = { command = codelldb, args = { "--port", "${port}" } },
          }
        end,
        -- rustaceanvim loads the toolchain's LLDB type formatters by passing every line of
        -- `<sysroot>/lib/rustlib/etc/lldb_commands` as an init command; the blank lines in that file (Rust 1.9x)
        -- make codelldb abort the launch with "error: empty command". codelldb already loads the same formatters
        -- itself when the configuration says `sourceLanguages = { "rust" }`, so this is redundant anyway.
        load_rust_types = false,
        -- otherwise rustaceanvim runs `cargo build` for every target as soon as rust-analyzer attaches (loading
        -- nvim-dap and dap-ui along the way) just to pre-fill `:DapContinue`; the mappings build on demand instead
        autoload_configurations = false,
        -- rustaceanvim's default configuration plus the debug console: like the C/C++ configurations in
        -- plugins/dap.lua, print to the dap-ui REPL pane, since codelldb's terminal loses the output of programs
        -- that exit right away. For a program that reads stdin, `:DapContinue` has the "(terminal, for input)"
        -- configurations with a path prompt (target/debug/<name>). Note: setting this skips `.vscode/launch.json`.
        configuration = {
          name = "Rust (cargo)",
          type = "codelldb",
          request = "launch",
          stopOnEntry = false,
          sourceLanguages = { "rust" },
          console = "internalConsole",
        },
      })
      return opts
    end,
  },
  {
    "AstroNvim/astrolsp",
    ---@type AstroLSPOpts
    opts = {
      mappings = {
        n = {
          ["<Leader>dc"] = { continue, desc = "Start/Continue (F5)", cond = is_rust_analyzer },
          ["<F5>"] = { continue, desc = "Debugger: Start", cond = is_rust_analyzer },
          ["<Leader>dd"] = { debuggables, desc = "Debug cargo target", cond = is_rust_analyzer },
          ["<Leader>dD"] = { debug_at_cursor, desc = "Debug target at cursor", cond = is_rust_analyzer },
          ["<Leader>dl"] = { debug_last, desc = "Debug last cargo target", cond = is_rust_analyzer },

          -- rustaceanvim's :RustLsp commands, only in rust-analyzer buffers (AstroNvim's "Rename file" on
          -- <Leader>R is dropped in plugins/astrocore.lua)
          ["<Leader>R"] = { desc = "Rust", cond = is_rust_analyzer },
          ["<Leader>Rr"] = { rust_lsp "runnables", desc = "Runnables (cargo run/test/bench picker)", cond = is_rust_analyzer },
          ["<Leader>RR"] = { rust_lsp { "runnables", bang = true }, desc = "Re-run last runnable", cond = is_rust_analyzer },
          ["<Leader>Rt"] = { rust_lsp "testables", desc = "Testables (test picker)", cond = is_rust_analyzer },
          ["<Leader>RT"] = { rust_lsp { "testables", bang = true }, desc = "Re-run last test", cond = is_rust_analyzer },
          ["<Leader>Re"] = { rust_lsp "explainError", desc = "Explain next error (rustc --explain)", cond = is_rust_analyzer },
          ["<Leader>Rd"] = { rust_lsp "renderDiagnostic", desc = "Render next diagnostic (cargo style)", cond = is_rust_analyzer },
          ["<Leader>Rf"] = { rust_lsp { "flyCheck", "run" }, desc = "Check now (clippy without saving)", cond = is_rust_analyzer },
          ["<Leader>Rh"] = { rust_lsp { "hover", "actions" }, desc = "Hover with actions", cond = is_rust_analyzer },
          ["<Leader>Rm"] = { rust_lsp "expandMacro", desc = "Expand macro", cond = is_rust_analyzer },
          ["<Leader>Ro"] = { rust_lsp "openDocs", desc = "Open docs.rs for symbol", cond = is_rust_analyzer },
          ["<Leader>Rc"] = { rust_lsp "openCargo", desc = "Open Cargo.toml", cond = is_rust_analyzer },
          ["<Leader>Rp"] = { rust_lsp "parentModule", desc = "Parent module", cond = is_rust_analyzer },
          ["<Leader>Rs"] = { rust_lsp "ssr", desc = "Structural search replace", cond = is_rust_analyzer },
          ["<Leader>RJ"] = { rust_lsp "joinLines", desc = "Join lines", cond = is_rust_analyzer },
          ["<Leader>Rk"] = { rust_lsp { "moveItem", "up" }, desc = "Move item up", cond = is_rust_analyzer },
          ["<Leader>Rj"] = { rust_lsp { "moveItem", "down" }, desc = "Move item down", cond = is_rust_analyzer },
        },
        x = {
          ["<Leader>R"] = { desc = "Rust", cond = is_rust_analyzer },
          -- `:` from visual mode fills in the '<,'> range, which these commands use
          ["<Leader>RJ"] = { ":RustLsp joinLines<CR>", desc = "Join lines", cond = is_rust_analyzer },
          ["<Leader>Rs"] = { ":RustLsp ssr<CR>", desc = "Structural search replace", cond = is_rust_analyzer },
        },
      },
    },
  },
}
