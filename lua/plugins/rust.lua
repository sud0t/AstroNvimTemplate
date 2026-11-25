-- Rust, on top of the AstroCommunity rust pack. Debugging goes through rustaceanvim: `:RustLsp debuggables`
-- asks rust-analyzer for the workspace's cargo targets, builds the chosen one and launches it. The mappings
-- put that behind the usual debugger keys.

---@type rustaceanvim.RACargoRunnableArgs?
local last_target
local tracking = false
-- `:RustLsp debuggables!` relaunches the last target with its errors muted (a failed build does nothing):
-- the target is remembered here and relaunched with errors shown.
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

--- Makes every mapping in `maps` exist only in the buffers of the clients `cond` accepts.
local function only_for(cond, maps)
  for _, mode_maps in pairs(maps) do
    for _, map in pairs(mode_maps) do
      map.cond = cond
    end
  end
  return maps
end

-- `:RustLsp <cmd>`; a table adds arguments / bang: rust_lsp { "runnables", bang = true } re-runs the last one
local function rust_lsp(cmd)
  return function() vim.cmd.RustLsp(cmd) end
end

local warned_missing_component = false -- rustaceanvim resolves the server command more than once per start

-- rust-analyzer answers codeLens/resolve with "content modified" while it indexes, and Neovim 0.12 does not
-- retry: the lenses stay blank. Ask again once its `rustAnalyzer/*` progress has been quiet for 500 ms.
local refresh_generation = {} ---@type table<integer, integer> client id -> last scheduled refresh
local function refresh_codelens_after_indexing(ev)
  local params = ev.data.params
  if
    params.value.kind ~= "end"
    or type(params.token) ~= "string"
    or not vim.startswith(params.token, "rustAnalyzer/")
  then
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
    -- rustaceanvim starts rust-analyzer from its ftplugin, which for the first file of a session runs before
    -- `User AstroFile` loads AstroLSP: the server would start without AstroLSP's `vim.lsp.config` entries
    -- (clippy, the `target/` exclusion, blink.cmp's capabilities). As a dependency, AstroLSP is set up first.
    dependencies = { "AstroNvim/astrolsp" },
    -- the pack's `config` already writes these opts into `vim.g.rustaceanvim`
    opts = function(_, opts)
      opts.server = opts.server or {}
      -- The rust-analyzer of the active rustup toolchain, or of stable when that one lacks the component: the
      -- bare `rust-analyzer` proxy would only print "Unknown binary 'rust-analyzer' in official toolchain".
      opts.server.cmd = function()
        if vim.fn.executable "rustup" == 0 then return { "rust-analyzer" } end -- whatever is on PATH
        -- rustup picks the toolchain from the directory it runs in: ask from the file's directory (the current
        -- buffer is the one the server starts for), since Neovim's working directory may be outside the project
        local dir = vim.fs.dirname(vim.api.nvim_buf_get_name(0))
        local cwd = dir and vim.fn.isdirectory(dir) == 1 and dir or nil
        for _, toolchain in ipairs { {}, { "--toolchain", "stable" } } do
          local cmd = vim.list_extend(vim.list_extend({ "rustup", "which" }, toolchain), { "rust-analyzer" })
          local res = vim.system(cmd, { cwd = cwd, text = true }):wait()
          local ra_path = vim.trim(res.stdout or "")
          if res.code == 0 and ra_path ~= "" then
            if #toolchain > 0 and not warned_missing_component then
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
        return { "rust-analyzer" } -- not in any toolchain: whatever is on PATH
      end

      opts.dap = require("astrocore").extend_tbl(opts.dap, {
        -- The pack's --liblldb path ($MASON/share/lldb) is gone in Mason 2 and codelldb panics on a missing
        -- library; it finds its bundled liblldb by itself. rustaceanvim only reads this adapter to learn that it
        -- talks to codelldb: sessions run through mason-nvim-dap's `codelldb` adapter (plugins/dap.lua).
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
        -- rustaceanvim passes each line of the toolchain's `lldb_commands` as an init command; its blank lines
        -- (Rust 1.9x) abort the launch with "error: empty command". codelldb loads those formatters itself.
        load_rust_types = false,
        -- otherwise rustaceanvim runs `cargo build` for every target when rust-analyzer attaches, loading
        -- nvim-dap on the way, to pre-fill `:DapContinue`; the mappings build on demand
        autoload_configurations = false,
        -- rustaceanvim's default plus the debug console: codelldb's terminal loses the output of a program that
        -- exits at once (plugins/dap.lua). Setting this skips .vscode/launch.json.
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
      config = {
        rust_analyzer = {
          -- nvim-lspconfig's hook, which rustaceanvim merges in, also swaps the "Run" codelens handler for one
          -- that blocks Neovim until the program exits (rustaceanvim's runs a terminal split): keep its other job.
          before_init = function(init_params, config)
            local settings = config.settings and config.settings["rust-analyzer"]
            if settings then init_params.initializationOptions = settings end
          end,
        },
      },
      mappings = only_for(is_rust_analyzer, {
        n = {
          ["<Leader>dc"] = { continue, desc = "Start/Continue (F5)" },
          ["<F5>"] = { continue, desc = "Debugger: Start" },
          ["<Leader>dd"] = { debuggables, desc = "Debug cargo target" },
          ["<Leader>dD"] = { debug_at_cursor, desc = "Debug target at cursor" },
          ["<Leader>dl"] = { debug_last, desc = "Debug last cargo target" },

          -- (AstroNvim's "Rename file" on <Leader>R is dropped in plugins/astrocore.lua)
          ["<Leader>R"] = { desc = "Rust" },
          ["<Leader>Rr"] = { rust_lsp "runnables", desc = "Runnables (cargo run/test/bench picker)" },
          ["<Leader>RR"] = { rust_lsp { "runnables", bang = true }, desc = "Re-run last runnable" },
          ["<Leader>Rt"] = { rust_lsp "testables", desc = "Testables (test picker)" },
          ["<Leader>RT"] = { rust_lsp { "testables", bang = true }, desc = "Re-run last test" },
          ["<Leader>Re"] = { rust_lsp "explainError", desc = "Explain next error (rustc --explain)" },
          ["<Leader>Rd"] = { rust_lsp "renderDiagnostic", desc = "Render next diagnostic (cargo style)" },
          ["<Leader>Rf"] = { rust_lsp { "flyCheck", "run" }, desc = "Check now (clippy without saving)" },
          ["<Leader>Rh"] = { rust_lsp { "hover", "actions" }, desc = "Hover with actions" },
          ["<Leader>Rm"] = { rust_lsp "expandMacro", desc = "Expand macro" },
          ["<Leader>Ro"] = { rust_lsp "openDocs", desc = "Open docs.rs for symbol" },
          ["<Leader>Rc"] = { rust_lsp "openCargo", desc = "Open Cargo.toml" },
          ["<Leader>Rp"] = { rust_lsp "parentModule", desc = "Parent module" },
          ["<Leader>Rs"] = { rust_lsp "ssr", desc = "Structural search replace" },
          ["<Leader>RJ"] = { rust_lsp "joinLines", desc = "Join lines" },
          ["<Leader>Rk"] = { rust_lsp { "moveItem", "up" }, desc = "Move item up" },
          ["<Leader>Rj"] = { rust_lsp { "moveItem", "down" }, desc = "Move item down" },
        },
        x = {
          ["<Leader>R"] = { desc = "Rust" },
          -- `:` from visual mode fills in the '<,'> range, which these commands use
          ["<Leader>RJ"] = { ":RustLsp joinLines<CR>", desc = "Join lines" },
          ["<Leader>Rs"] = { ":RustLsp ssr<CR>", desc = "Structural search replace" },
        },
      }),
    },
  },
}
