-- Debugging (nvim-dap). Adapters come from Mason through mason-nvim-dap and the language packs. The debug UI
-- is nvim-dap-view: one window at the bottom with a tab for each view. In it a tab's letter selects the tab,
-- and g? lists the keys of the current one.

-- AstroNvim maps "Restart" to restart_frame(): the current stack frame again, and only with an adapter that has
-- that request. nvim-dap's restart is for the program: the adapter's restart request, or a new launch.
local function restart() require("dap").restart() end

---@type LazySpec
return {
  {
    "AstroNvim/astrocore",
    opts = function(_, opts)
      local maps = opts.mappings
      if maps.n["<Leader>dr"] then maps.n["<Leader>dr"] = { restart, desc = "Restart (C-F5)" } end
      if maps.n["<F29>"] then maps.n["<F29>"] = { restart, desc = "Debugger: Restart" } end -- Control+F5
      -- AstroNvim's "Toggle REPL" opens the REPL in a split of its own; here it is a tab of the debug window
      maps.n["<Leader>dR"] = false
    end,
  },
  -- The python pack loads nvim-dap-python, and with it the whole debugger stack, on every Python buffer (~25ms
  -- for the first): load it with nvim-dap instead, on the first debug key.
  {
    "mfussenegger/nvim-dap-python",
    ft = function() return {} end, -- drop the pack's `ft = "python"` trigger
  },
  {
    "mfussenegger/nvim-dap",
    optional = true,
    dependencies = { "mfussenegger/nvim-dap-python", "igorlfs/nvim-dap-view" },
    config = function()
      require "astronvim.plugins.configs.nvim-dap"() -- AstroNvim's own setup (launch.json parsing)
      local dap = require "dap"

      -- Node: neotest-jest and launch.json sessions are of type `pwa-node`, for which mason-nvim-dap has no adapter
      local js_debug = vim.fn.expand "$MASON/packages/js-debug-adapter/js-debug/src/dapDebugServer.js"
      if vim.fn.filereadable(js_debug) == 1 then
        dap.adapters["pwa-node"] = {
          type = "server",
          host = "localhost",
          port = "${port}",
          executable = { command = "node", args = { js_debug, "${port}" } },
        }
      end

      -- Lua, which nothing else here can debug: standalone scripts, not Lua running inside Neovim
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
  -- nvim-dap-view is the debug UI here
  { "rcarriga/nvim-dap-ui", enabled = false },
  -- AstroNvim makes it lazy only as a dependency of nvim-dap-ui; without that it would load at every start
  { "nvim-neotest/nvim-nio", lazy = true },
  {
    "igorlfs/nvim-dap-view",
    version = "^1",
    lazy = true, -- loaded with nvim-dap, which depends on it (above)
    specs = {
      {
        "AstroNvim/astrocore",
        opts = function(_, opts)
          local maps = opts.mappings
          -- both take the selection in visual mode, and the expression under the cursor otherwise
          local function hover() require("dap-view").hover() end
          local function watch() require("dap-view").add_expr() end
          -- the keys AstroNvim gives nvim-dap-ui, which go when it is disabled, doing the same jobs
          maps.x["<Leader>d"] = vim.tbl_get(opts, "_map_sections", "d")
          maps.n["<Leader>du"] = { function() require("dap-view").toggle() end, desc = "Toggle Debugger UI" }
          maps.n["<Leader>dh"] = { hover, desc = "Debugger Hover" }
          maps.n["<Leader>dE"] = {
            function()
              vim.ui.input({ prompt = "Expression: " }, function(expr)
                if expr and expr ~= "" then require("dap-view").hover(expr) end
              end)
            end,
            desc = "Evaluate Input",
          }
          maps.x["<Leader>dE"] = { hover, desc = "Evaluate Selection" }
          -- and one more: watches are added from the code, since their tab is not always in view
          maps.n["<Leader>dw"] = { watch, desc = "Watch Expression" }
          maps.x["<Leader>dw"] = { watch, desc = "Watch Selection" }
        end,
      },
    },
    opts = {
      winbar = {
        -- "console" makes the program's terminal a tab of the debug window; left out, it gets a window of its own
        sections = { "console", "watches", "scopes", "exceptions", "breakpoints", "threads", "repl" },
        default_section = "scopes",
      },
    },
    config = function(_, opts)
      local dap, dap_view = require "dap", require "dap-view"
      dap_view.setup(opts)

      -- Open every session on the default tab. `auto_toggle` would reopen the tab used last, and dap-view has no
      -- call to choose the tab of a closed window, so its remembered tab is cleared. (Opening first and switching
      -- afterwards fails: leaving the Console tab at once breaks its pending scroll, "Invalid cursor line".)
      local view_state = require "dap-view.state"
      for _, request in ipairs { "attach", "launch" } do
        dap.listeners.before[request].dapview_config = function()
          dap_view.close() -- (before the tab is forgotten: closing the REPL tab takes a step of its own)
          view_state.current_section = nil
          dap_view.open()
        end
      end

      -- (true: a terminal window too, should "console" stop being a tab)
      local function close_ui() dap_view.close(true) end
      -- Keep the UI open when the program ends by itself, so its output can be read; close it only when the
      -- session was stopped by hand.
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
      ---@diagnostic disable-next-line: duplicate-set-field
      dap.restart = function(...)
        -- an adapter without a restart request is terminated and launched again as a new session
        local session = dap.session()
        if session and not session.capabilities.supportsRestartRequest then mark_all() end
        return restart_session(...)
      end
      local close = dap.close
      ---@diagnostic disable-next-line: duplicate-set-field
      dap.close = function(...)
        mark_all()
        local result = close(...)
        close_ui() -- dap.close() ends the session without the adapter sending `terminated`
        return result
      end
      dap.listeners.before.event_terminated.dapview_config = function(session)
        if stopped_by_user[session] then close_ui() end
      end
      -- (not every adapter sends `terminated` or `exited` when it is told to stop: bash-debug-adapter only answers)
      for _, request in ipairs { "terminate", "disconnect" } do
        dap.listeners.after[request].dapview_config = function(session)
          if stopped_by_user[session] then close_ui() end
        end
      end
      dap.listeners.before.event_exited.dapview_config = function(session, body)
        if stopped_by_user[session] then return close_ui() end
        local code = body and body.exitCode
        vim.notify(
          -- a program run in a terminal prints there, any other to the debug console
          ("Program exited%s. Its output is in the %s tab; <Leader>du closes the debug UI."):format(
            code and (" with code " .. code) or "",
            session.term_buf and "Console" or "REPL"
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
      -- bash-debug-adapter ends a session with `pkill -KILL -P <bashdb's parent>`, which in the "integrated"
      -- terminal is Neovim. In the debug console bashdb runs under the adapter's own shell (no stdin).
      opts.handlers.bash = function(config)
        config = vim.deepcopy(config)
        for _, c in ipairs(config.configurations or {}) do
          c.terminalKind = "debugConsole"
        end
        require("mason-nvim-dap").default_setup(config)
      end
      -- codelldb (C/C++) takes what is typed in the REPL tab and on <Leader>dE as LLDB commands: a variable
      -- named `x` runs LLDB's memory read. Evaluate expressions instead; a ` prefix still runs a command (`bt).
      opts.handlers.codelldb = function(config)
        config = vim.deepcopy(config)
        local exe = config.adapters.executable
        exe.args = vim.list_extend(exe.args or {}, { "--settings", vim.json.encode { consoleMode = "evaluate" } })

        -- codelldb's integrated terminal loses the output of a program that exits at once (the launcher closes it
        -- before Neovim reads it), so the configurations print to the debug console; the "(terminal, for input)"
        -- variants are for programs that read stdin. Rust sessions start from cargo targets (plugins/rust.lua).
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
