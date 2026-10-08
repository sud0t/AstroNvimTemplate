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

---@type LazySpec
return {
  {
    "mrcjkb/rustaceanvim",
    -- the pack's `config` already writes these opts into `vim.g.rustaceanvim`
    opts = function(_, opts)
      opts.server = opts.server or {}
      -- use the rust-analyzer that matches the active rustup toolchain
      opts.server.cmd = function()
        local ra_path = vim.fn.system("rustup which rust-analyzer"):gsub("%s+$", "")
        -- rustup missing / no toolchain: don't hand an error message to the LSP client as the command
        if vim.v.shell_error ~= 0 or ra_path == "" then return { "rust-analyzer" } end
        return { ra_path }
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
        },
      },
    },
  },
}
