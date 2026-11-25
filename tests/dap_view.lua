-- The debug UI of lua/plugins/dap.lua inside the whole configuration: the debug keys, nvim-dap-view's window and
-- its tabs, and when that window opens and closes.
--   tests/run.sh dap_view
-- Run it after changing lua/plugins/dap.lua and after updating nvim-dap-view or nvim-dap. A stand-in debug
-- adapter inside this Neovim plays the sessions, so no debugger has to be installed; what the real adapters
-- show in the tabs is not checked here.
local uv = vim.uv

local harness = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/harness.lua")
harness.whole_config()
local ok = harness.ok

--- A debug adapter for one "program": a session stops on line 2 of `program` as soon as it is configured, and
--- `continue` runs it to its end. Fields of the launch configuration choose how it behaves:
---   terminal      true: the program is run in the client's terminal, in the order debugpy does it: the terminal
---                 is asked for first, and the launch request is answered once the session is configured (so the
---                 debug window opens on a session that has a terminal already)
---   on_terminate  what a terminate request gets: "events" (the answer, then `exited` and `terminated`),
---                 "exited_first" (`exited` before the answer, as debugpy and delve do) or "answer_only" (no event
---                 at all, as bash-debug-adapter does)
---@return integer port it listens on, on 127.0.0.1
local function stand_in_adapter(program)
  local server = assert(uv.new_tcp())
  assert(server:bind("127.0.0.1", 0))
  assert(server:listen(8, function(listen_err)
    assert(not listen_err, listen_err)
    local client = assert(uv.new_tcp())
    assert(server:accept(client))
    local seq, launch, unanswered_launch = 0, {}, nil
    local function send(message)
      seq = seq + 1
      message.seq = seq
      local body = vim.json.encode(message)
      client:write(("Content-Length: %d\r\n\r\n%s"):format(#body, body))
    end
    local function event(name, body) send { type = "event", event = name, body = body } end
    local function answer(request, body)
      send { type = "response", request_seq = request.seq, command = request.command, success = true, body = body }
    end
    local requests = {
      initialize = function(request)
        answer(request, { supportsConfigurationDoneRequest = true, supportsTerminateRequest = true })
        event "initialized"
      end,
      launch = function(request)
        launch = request.arguments
        if not launch.terminal then return answer(request) end
        -- (the sleep: nvim-dap asks for the program's pid after starting it, which fails once the program ended)
        local command = { "sh", "-c", "echo printed in the terminal; sleep 0.1" }
        local arguments = { kind = "integrated", cwd = vim.fs.dirname(program), args = command }
        send { type = "request", command = "runInTerminal", arguments = arguments }
        unanswered_launch = request
      end,
      configurationDone = function(request)
        answer(request)
        if unanswered_launch then answer(unanswered_launch) end
        unanswered_launch = nil
        event("stopped", { reason = "breakpoint", threadId = 1, allThreadsStopped = true })
      end,
      threads = function(request) answer(request, { threads = { { id = 1, name = "main" } } }) end,
      stackTrace = function(request)
        local frame = { id = 1, name = "main", line = 2, column = 1, source = { name = "program", path = program } }
        answer(request, { stackFrames = { frame }, totalFrames = 1 })
      end,
      scopes = function(request)
        answer(request, { scopes = { { name = "Locals", variablesReference = 1, expensive = false } } })
      end,
      variables = function(request)
        answer(request, { variables = { { name = "answer", value = "42", variablesReference = 0 } } })
      end,
      evaluate = function(request)
        answer(request, { result = ("<%s>"):format(request.arguments.expression), variablesReference = 0 })
      end,
      continue = function(request)
        answer(request, { allThreadsContinued = true })
        event("exited", { exitCode = 0 })
        event "terminated"
      end,
      terminate = function(request)
        if launch.on_terminate == "exited_first" then event("exited", { exitCode = 0 }) end
        answer(request)
        if launch.on_terminate == "events" then event("exited", { exitCode = 0 }) end
        if launch.on_terminate ~= "answer_only" then event "terminated" end
      end,
    }
    local received = ""
    client:read_start(vim.schedule_wrap(function(read_err, chunk)
      if read_err or not chunk then return client:close() end
      received = received .. chunk
      while true do
        local header_end, body_start = received:find("\r\n\r\n", 1, true)
        local length = header_end and tonumber(received:sub(1, header_end):match "Content%-Length: (%d+)")
        if not length or #received < body_start + length then break end
        local message = vim.json.decode(received:sub(body_start + 1, body_start + length))
        received = received:sub(body_start + length + 1)
        -- (the client's answer to runInTerminal is the one message that is not a request)
        if message.type == "request" then (requests[message.command] or answer)(message) end
      end
    end))
  end))
  return server:getsockname().port
end

local dir
local run, err = xpcall(function()
  local plugins = require("lazy.core.config").plugins
  ok("nvim-dap-ui is not a plugin any more", plugins["nvim-dap-ui"] == nil)
  ok("nvim-dap-view is a plugin", plugins["nvim-dap-view"] ~= nil)
  ok("the debugger is not loaded at startup", package.loaded["dap"] == nil and package.loaded["dap-view"] == nil)

  -- AstroNvim's debug keys, which the spec of the UI must leave alone, and the keys of the UI itself
  local keys = {
    n = "<F5> <F17> <F21> <F29> <F6> <F9> <F10> <F11> <F23> <Leader>db <Leader>dB <Leader>dc <Leader>dC <Leader>di"
      .. " <Leader>do <Leader>dO <Leader>dq <Leader>dQ <Leader>dp <Leader>dr <Leader>ds"
      .. " <Leader>du <Leader>dh <Leader>dE <Leader>dw",
    x = "<Leader>dE <Leader>dw",
  }
  for mode, mapped in pairs(keys) do
    for key in mapped:gmatch "%S+" do
      ok(("%s is mapped in mode %s"):format(key, mode), vim.fn.maparg(key, mode, false, true).desc ~= nil)
    end
  end
  -- a space typed over a snippet placeholder must not wait for a debug key
  for key in keys.x:gmatch "%S+" do
    ok(key .. " is not mapped in select mode", vim.fn.maparg(key, "s") == "", vim.fn.maparg(key, "s"))
  end
  ok("<Leader>dR is not mapped", next(vim.fn.maparg("<Leader>dR", "n", false, true)) == nil)

  dir = assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/dap-view-test.XXXXXX"))
  local program = dir .. "/program.txt"
  vim.fn.writefile({ "first", "second", "third" }, program)
  vim.cmd.edit(vim.fn.fnameescape(program))
  local source_win = vim.api.nvim_get_current_win()

  require("lazy").load { plugins = { "nvim-dap" } }
  local dap, dap_view = require "dap", require "dap-view"
  ok("nvim-dap-ui is not loaded with the debugger", package.loaded["dapui"] == nil)
  -- neotest-jest and launch.json debug Node through this adapter, which nothing else registers
  local js_debug = vim.fn.expand "$MASON/packages/js-debug-adapter/js-debug/src/dapDebugServer.js"
  local node = dap.adapters["pwa-node"]
  ok(
    "Node's debug adapter runs Mason's js-debug-adapter, when that is installed",
    vim.fn.filereadable(js_debug) == 0 or (type(node) == "table" and node.executable.args[1] == js_debug),
    vim.inspect(node)
  )
  dap.adapters.stand_in = { type = "server", host = "127.0.0.1", port = stand_in_adapter(program) }
  local notes = {}
  vim.notify = function(msg) notes[#notes + 1] = msg end
  vim.ui.input = function(_, on_confirm) on_confirm "6 * 7" end

  local function wait(cond) return vim.wait(5000, cond, 20) end
  local function press(lhs)
    local typed = lhs:gsub("<Leader>", vim.g.mapleader)
    vim.api.nvim_feedkeys(vim.keycode(typed), "x", false)
  end
  --- nvim-dap-view's window, and the window of a terminal it keeps beside it (there must be none)
  local function debug_windows()
    local view, terminal
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      view = vim.w[win].dapview_win and win or view
      terminal = vim.w[win].dapview_win_term and win or terminal
    end
    return view, terminal
  end
  --- the labels of the debug window's tab bar, the selected one in <>
  local function tab_bar()
    local view = debug_windows()
    local labels = {}
    for group, label in (view and vim.wo[view].winbar or ""):gmatch "%%#NvimDapView(Tab%a*)#%%%d+@[^@]+@ (%a+) %[" do
      labels[#labels + 1] = group == "TabSelected" and ("<" .. label .. ">") or label
    end
    return table.concat(labels, " ")
  end
  local function bar_with(selected)
    return (("Console Watches Scopes Exceptions Breakpoints Threads REPL"):gsub(selected, "<%0>"))
  end
  --- `text` is in the buffer of `win` (the debug window when left out)
  local function shows(text, win)
    win = win or debug_windows()
    if not win then return false end
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
    return table.concat(lines, "\n"):find(text, 1, true) ~= nil
  end
  local function exit_notes()
    return vim.tbl_filter(function(note) return note:find("Program exited", 1, true) ~= nil end, notes)
  end
  --- start a session from the source window and wait until it has stopped and the debug window shows it
  local function start(what, options)
    notes = {}
    vim.api.nvim_set_current_win(source_win)
    dap.run(vim.tbl_extend("force", { type = "stand_in", request = "launch", name = "stand-in" }, options or {}))
    local stopped = wait(function() return dap.session() ~= nil and dap.session().stopped_thread_id ~= nil end)
    ok(what .. ": the session stops", stopped)
    ok(
      what .. ": the debug window opens on Scopes",
      wait(function() return tab_bar() == bar_with "Scopes" end),
      tab_bar()
    )
    ok(what .. ": Scopes lists the variables", wait(function() return shows "answer = 42" end))
    ok(what .. ": the cursor stays in the source window", vim.api.nvim_get_current_win() == source_win)
    return dap.session()
  end
  local function ends(what)
    ok(what .. ": the session ends", wait(function() return dap.session() == nil end))
  end
  local function settle()
    vim.wait(200, function() return false end)
  end

  -- a program that prints to the debug console
  start "first session"
  local view, terminal = debug_windows()
  ok("the debug UI is one window", #vim.api.nvim_tabpage_list_wins(0) == 2 and terminal == nil)
  ok(
    "the debug window is below the source",
    vim.api.nvim_win_get_position(view)[1] > vim.api.nvim_win_get_position(source_win)[1]
      and vim.api.nvim_win_get_width(view) == vim.o.columns
  )
  -- every tab keeps the tab bar (the configuration's own winbar must not replace it) and its own filetype
  local tabs = {
    { "console", "Console", "dap-view", "No terminal for the current session" },
    { "watches", "Watches", "dap-view", "No expressions" },
    { "exceptions", "Exceptions", "dap-view" },
    { "breakpoints", "Breakpoints", "dap-view" },
    { "threads", "Threads", "dap-view", "main" },
    { "repl", "REPL", "dap-repl" },
    { "scopes", "Scopes", "dap-view", "answer = 42" },
  }
  for _, tab in ipairs(tabs) do
    local section, label, filetype, text = unpack(tab)
    dap_view.show_view(section)
    ok(label .. " tab: selected in the tab bar", wait(function() return tab_bar() == bar_with(label) end), tab_bar())
    view = debug_windows()
    ok(label .. " tab: filetype " .. filetype, vim.bo[vim.api.nvim_win_get_buf(view)].filetype == filetype)
    if text then ok(label .. " tab: shows " .. text, wait(function() return shows(text) end)) end
    ok(label .. " tab: the cursor stays in the source window", vim.api.nvim_get_current_win() == source_win)
  end

  local function in_hover() return vim.bo.filetype == "dap-view-hover" end
  local function close_hover(what)
    press "q"
    ok(what .. ": q closes the float", wait(function() return vim.api.nvim_get_current_win() == source_win end))
  end
  vim.api.nvim_win_set_cursor(source_win, { 2, 0 })
  press "<Leader>dh"
  ok(
    "<Leader>dh: a float with the word under the cursor",
    wait(function() return in_hover() and shows("<second>", 0) end)
  )
  close_hover "<Leader>dh"
  press "<Leader>dE"
  ok("<Leader>dE: a float with the expression typed", wait(function() return in_hover() and shows("<6 * 7>", 0) end))
  close_hover "<Leader>dE"
  press "0lvl<Leader>dE"
  ok("visual <Leader>dE: a float with the selection", wait(function() return in_hover() and shows("<ec>", 0) end))
  close_hover "visual <Leader>dE"
  press "0<Leader>dw"
  ok(
    "<Leader>dw: the word under the cursor is watched, on the Watches tab",
    wait(function() return tab_bar() == bar_with "Watches" and shows "second = <second>" end),
    tab_bar()
  )
  press "0lvl<Leader>dw"
  ok("visual <Leader>dw: the selection is watched", wait(function() return shows "ec = <ec>" end))
  ok("the watch keys leave the cursor in the source window", vim.api.nvim_get_current_win() == source_win)
  press "<Leader>du"
  ok("<Leader>du closes the debug window", debug_windows() == nil and #vim.api.nvim_tabpage_list_wins(0) == 1)
  press "<Leader>du"
  ok(
    "<Leader>du opens it again, on the same tab",
    wait(function() return tab_bar() == bar_with "Watches" end),
    tab_bar()
  )

  dap.continue()
  ends "a program that ends on its own"
  settle()
  ok("a program that ends on its own: the debug window stays open", debug_windows() ~= nil)
  ok(
    "a program that ends on its own: one notice, naming the REPL tab",
    #exit_notes() == 1 and exit_notes()[1]:find("with code 0. Its output is in the REPL tab", 1, true) ~= nil,
    vim.inspect(notes)
  )
  dap_view.show_view "repl" -- where the output is read; the next session must not start here

  -- a program that runs in a terminal
  start("a program in a terminal", { terminal = true })
  view, terminal = debug_windows()
  ok("a program in a terminal: still one window", #vim.api.nvim_tabpage_list_wins(0) == 2 and terminal == nil)
  dap_view.show_view "console"
  ok(
    "a program in a terminal: the Console tab is its terminal",
    wait(function() return tab_bar() == bar_with "Console" and shows "printed in the terminal" end),
    tab_bar()
  )
  ok(
    "the Console tab: filetype dap-view-term",
    vim.bo[vim.api.nvim_win_get_buf((debug_windows()))].filetype == "dap-view-term"
  )
  dap.continue()
  ends "a program in a terminal"
  settle()
  ok(
    "a program in a terminal: one notice, naming the Console tab",
    #exit_notes() == 1 and exit_notes()[1]:find("Its output is in the Console tab", 1, true) ~= nil,
    vim.inspect(notes)
  )
  ok(
    "a program in a terminal: its output is still there after the end",
    debug_windows() ~= nil and shows "printed in the terminal"
  )

  -- stopped by hand: the window closes without a notice, whatever the adapter sends when it is told to stop
  -- (the first of these starts from the Console tab of a terminal that has output: see lua/plugins/dap.lua)
  local stops = {
    { "events", "<F17>" },
    { "exited_first", "<Leader>dQ" },
    { "answer_only", "<F17>" },
  }
  for _, stop in ipairs(stops) do
    local on_terminate, key = unpack(stop)
    local what = ("%s on an adapter that sends %s"):format(key, on_terminate)
    start(what, { on_terminate = on_terminate, terminal = on_terminate == "events" })
    press(key)
    ends(what)
    ok(what .. ": the debug window closes", wait(function() return debug_windows() == nil end))
    settle()
    ok(what .. ": no notice about the program's exit", #exit_notes() == 0, vim.inspect(notes))
  end

  start "<Leader>dq"
  press "<Leader>dq"
  ends "<Leader>dq"
  ok("<Leader>dq: the debug window closes", debug_windows() == nil)

  -- the stand-in has no restart request, so nvim-dap stops the session and launches it again
  local first = start("<Leader>dr", { on_terminate = "events" })
  press "<Leader>dr"
  local relaunched = wait(function()
    local session = dap.session()
    return session ~= nil and session ~= first and session.stopped_thread_id ~= nil
  end)
  ok("<Leader>dr: a new session stops", relaunched)
  ok(
    "<Leader>dr: the debug window is open on Scopes",
    wait(function() return tab_bar() == bar_with "Scopes" end),
    tab_bar()
  )
  press "<F17>"
  ends "after <Leader>dr"
  ok("after <Leader>dr: the debug window closes", wait(function() return debug_windows() == nil end))

  settle()
  ok("nothing reported an error", vim.v.errmsg == "", vim.v.errmsg)
end, debug.traceback)

if dir then vim.fn.delete(dir, "rf") end
harness.finish(run, err)
