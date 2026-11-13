-- Debugging (nvim-dap). Adapters come from Mason through mason-nvim-dap (AstroNvim) and the language packs.

-- AstroNvim maps "Restart" (<Leader>dr, Ctrl+F5) to restart_frame(), which none of the adapters used here
-- (debugpy, codelldb, bash-debug-adapter, local-lua-debugger) support, so the keys did nothing. Restart the
-- session instead: nvim-dap uses the adapter's restart request when it has one, and otherwise relaunches.
local function restart() require("dap").restart() end

---@type LazySpec
return {
  {
    "AstroNvim/astrocore",
    opts = function(_, opts)
      local maps = opts.mappings
      if maps.n["<Leader>dr"] then maps.n["<Leader>dr"] = { restart, desc = "Restart (C-F5)" } end
      if maps.n["<F29>"] then maps.n["<F29>"] = { restart, desc = "Debugger: Restart" } end -- Control+F5
    end,
  },
  -- the python pack loads nvim-dap-python on every Python buffer, which drags in nvim-dap, dap-ui, mason-nvim-dap
  -- and cmp-dap (~25ms per first Python file). Load it together with nvim-dap instead, which AstroNvim already
  -- loads on the first debug mapping (<Leader>d...).
  {
    "mfussenegger/nvim-dap-python",
    ft = function() return {} end, -- drop the pack's `ft = "python"` trigger
  },
  -- The same for JavaScript/TypeScript: deno-nvim (typescript pack, loaded on those filetypes) ends its setup with
  -- `if pcall(require, "dap")`, to register its `pwa-node` debug adapter, and that require made lazy.nvim load the
  -- whole debugger stack (~40ms on the first JS/TS file). `require "dap"` is made to fail during that setup, and
  -- the adapter is registered when nvim-dap really loads (in its `config` below).
  {
    "sigmasd/deno-nvim",
    optional = true,
    opts = function(_, opts)
      -- the adapter has no `args` by default ("needs to be set"): point it at Mason's js-debug-adapter
      -- (not $MASON: on the first file of a session this runs before Mason is set up)
      local server = vim.fn.stdpath "data" .. "/mason/packages/js-debug-adapter/js-debug/src/dapDebugServer.js"
      if vim.fn.filereadable(server) == 1 then
        opts.dap = require("astrocore").extend_tbl(opts.dap, {
          adapter = { executable = { args = { server, "${port}" } } },
        })
      end
    end,
    config = function(_, opts)
      local deno = require "deno-nvim"
      if package.loaded["dap"] then return deno.setup(opts) end
      package.preload["dap"] = function() error "nvim-dap is loaded on demand" end
      local ok, err = pcall(deno.setup, opts)
      -- (a failed require leaves a marker in package.loaded that would make every later `require "dap"` fail)
      package.preload["dap"], package.loaded["dap"] = nil, nil
      if not ok then error(err, 0) end
    end,
  },
  {
    "mfussenegger/nvim-dap",
    optional = true,
    dependencies = { "mfussenegger/nvim-dap-python" },
    config = function()
      require "astronvim.plugins.configs.nvim-dap"() -- AstroNvim's own setup (launch.json parsing)
      if package.loaded["deno-nvim"] then require("deno-nvim.dap").setup_adapter() end

      -- Lua scripts (lua / luajit), with local-lua-debugger-vscode from Mason. Nothing provides Lua debugging
      -- by default; this is for standalone scripts, not for Lua running inside Neovim.
      local dap = require "dap"
      local pkg = vim.fn.expand "$MASON/packages/local-lua-debugger-vscode/extension"
      if vim.fn.isdirectory(pkg) == 1 then
        dap.adapters["local-lua"] = {
          type = "executable",
          command = "node",
          args = { pkg .. "/extension/debugAdapter.js" },
          enrich_config = function(config, on_config)
            -- tells the adapter where its `lldebugger` Lua module lives
            on_config(vim.tbl_extend("keep", config, { extensionPath = pkg }))
          end,
        }
        local function launch(interpreter)
          return {
            name = "Lua: current file (" .. interpreter .. ")",
            type = "local-lua",
            request = "launch",
            cwd = "${fileDirname}",
            program = { lua = interpreter, file = "${file}" },
            args = {},
          }
        end
        -- the debugger (0.3.3) does not run on Lua 5.5 (read-only loop variables), the system `lua`; use 5.4/LuaJIT
        local configurations = {}
        for _, interpreter in ipairs { "lua5.4", "luajit" } do
          if vim.fn.executable(interpreter) == 1 then table.insert(configurations, launch(interpreter)) end
        end
        dap.configurations.lua = vim.list_extend(dap.configurations.lua or {}, configurations)
      end
    end,
  },
  {
    "rcarriga/nvim-dap-ui",
    optional = true,
    config = function(...)
      require "astronvim.plugins.configs.nvim-dap-ui"(...)
      local dap, dapui = require "dap", require "dapui"
      -- AstroNvim closes the debug UI the moment a session ends. A program that runs to completion in a few
      -- milliseconds (the Debug codelens or <Leader>dd without a breakpoint) only flashes the UI, and its output in
      -- the console pane is gone before it can be read. Keep the UI open when the program exits on its own, and
      -- close it only when the session was stopped by hand (<Leader>dq, <Leader>dQ, Shift+F5).
      local stopped_by_user = setmetatable({}, { __mode = "k" }) -- session -> true
      local function mark(session)
        if not session or stopped_by_user[session] then return end
        stopped_by_user[session] = true
        for _, child in pairs(session.children or {}) do
          mark(child)
        end
      end
      local function mark_all()
        mark(dap.session())
        for _, session in pairs(dap.sessions()) do
          mark(session)
        end
      end
      -- Marked when the function is called, not from a `listeners.before.terminate`: request listeners run once the
      -- adapter has answered, and debugpy and delve send `exited` before they answer `terminate`.
      for _, name in ipairs { "terminate", "disconnect" } do
        local stop = dap[name]
        dap[name] = function(...)
          mark_all()
          return stop(...)
        end
      end
      local restart_session = dap.restart
      dap.restart = function(...)
        -- an adapter without a restart request is terminated and launched again as a new session
        local session = dap.session()
        if session and not session.capabilities.supportsRestartRequest then mark_all() end
        return restart_session(...)
      end
      local close = dap.close
      dap.close = function(...)
        mark_all()
        local result = close(...)
        dapui.close() -- dap.close() ends the session without the adapter sending `terminated`
        return result
      end
      dap.listeners.before.event_terminated.dapui_config = function(session)
        if stopped_by_user[session] then dapui.close() end
      end
      -- (not every adapter sends `terminated` or `exited` when it is told to stop: bash-debug-adapter only answers)
      for _, request in ipairs { "terminate", "disconnect" } do
        dap.listeners.after[request].dapui_config = function(session)
          if stopped_by_user[session] then dapui.close() end
        end
      end
      dap.listeners.before.event_exited.dapui_config = function(session, body)
        if stopped_by_user[session] then return dapui.close() end
        local code = body and body.exitCode
        vim.notify(
          ("Program exited%s. The output is in the console pane; <Leader>du closes the debug UI."):format(
            code and (" with code " .. code) or ""
          ),
          code == 0 and vim.log.levels.INFO or vim.log.levels.WARN,
          { title = "Debugger" }
        )
      end
    end,
  },
  {
    "jay-babu/mason-nvim-dap.nvim",
    optional = true,
    opts = function(_, opts)
      opts.handlers = opts.handlers or {}
      -- bash-debug-adapter: the default configuration runs bashdb in the "integrated" terminal, which nvim-dap
      -- starts as a direct child of Neovim. When the session ends the adapter cleans up with
      -- `pkill -KILL -P <bashdb's parent>` (a terminal's shell in VS Code), which here is Neovim itself: every
      -- language server and terminal job got killed with it. In the debug console the adapter starts bashdb under
      -- its own shell; the script's output goes to the dap-ui REPL pane (a script cannot read stdin this way).
      opts.handlers.bash = function(config)
        config = vim.deepcopy(config)
        for _, c in ipairs(config.configurations or {}) do
          c.terminalKind = "debugConsole"
        end
        require("mason-nvim-dap").default_setup(config)
      end
      -- codelldb (C/C++): by default the REPL (<Leader>dR) and <Leader>dE treat input as LLDB commands, so typing
      -- a variable name such as `x` ran LLDB's memory-read command. Evaluate expressions instead; LLDB commands
      -- still work with a ` prefix (e.g. `bt).
      opts.handlers.codelldb = function(config)
        config = vim.deepcopy(config)
        local exe = config.adapters.executable
        exe.args = vim.list_extend(exe.args or {}, { "--settings", vim.json.encode { consoleMode = "evaluate" } })

        -- In codelldb's integrated terminal the output of a program that exits right away is lost (the launcher
        -- closes the terminal before Neovim reads it), so the default configurations print to the debug console
        -- (dap-ui REPL pane) instead. "(terminal, for input)" variants keep the terminal for programs that read stdin.
        -- These path-prompt configurations are for C/C++; Rust sessions start from cargo targets through
        -- rustaceanvim (plugins/rust.lua) and only fall back to them via :DapContinue.
        local function program()
          local guess = vim.fn.expand "%:p:r" -- the binary next to the source file, e.g. main.c -> main
          local default = vim.fn.executable(guess) == 1 and guess or vim.fn.getcwd() .. "/"
          return vim.fn.input("Path to executable: ", default, "file")
        end
        local configurations = {}
        for _, c in ipairs(config.configurations or {}) do
          local internal = vim.tbl_extend("force", c, { program = program, console = "internalConsole" })
          local terminal = vim.tbl_extend("force", internal, {
            name = c.name .. " (terminal, for input)",
            console = "integratedTerminal",
          })
          vim.list_extend(configurations, { internal, terminal })
        end
        config.configurations = configurations
        require("mason-nvim-dap").default_setup(config)
      end
    end,
  },
}
