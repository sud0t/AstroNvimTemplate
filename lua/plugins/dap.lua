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
  {
    "mfussenegger/nvim-dap",
    optional = true,
    dependencies = { "mfussenegger/nvim-dap-python" },
    config = function()
      require "astronvim.plugins.configs.nvim-dap"() -- AstroNvim's own setup (launch.json parsing)

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
    "jay-babu/mason-nvim-dap.nvim",
    optional = true,
    opts = function(_, opts)
      opts.handlers = opts.handlers or {}
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
