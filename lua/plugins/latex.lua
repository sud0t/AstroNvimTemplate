-- LaTeX notes with the PDF beside the editor:
--   vimtex    compiles with latexmk in continuous mode and drives zathura (SyncTeX both ways)
--   zathura   opens as its own window, Hyprland tiles it next to kitty and it reloads on every rebuild
--   texlab    LSP for completion/diagnostics (installed through Mason in plugins/mason.lua)
--   math autosnippets live in luasnippets/tex.lua
-- $ closes itself like a bracket ($$ for display math); inside math the snippets do the bracket pairing.
-- Nothing compiles until <Leader>L: it starts latexmk in continuous mode and the PDF opens after the first build.
-- From then on changes are written on InsertLeave/TextChanged so the PDF follows along without :w.
-- In zathura, ctrl+click jumps Neovim to that line, ,lv jumps the PDF to the cursor.
-- The code-focused <Leader> groups are hidden in .tex buffers.

-- <Leader> mappings with no use in LaTeX: debugger, refactoring, node terminal (the Python-only ones are
-- buffer-local to Python buffers already, see plugins/python.lua)
local code_prefixes = { "d", "r", "tn" }

-- shadow every matching global mapping with a buffer-local no-op that which-key hides,
-- so the keys do nothing and the emptied groups drop out of the popup
local function hide_code_maps(buf)
  local leader = vim.g.mapleader
  for _, mode in ipairs { "n", "x" } do
    for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
      for _, prefix in ipairs(code_prefixes) do
        if vim.startswith(map.lhs, leader .. prefix) then
          vim.keymap.set(mode, map.lhs, function() end, { buffer = buf, desc = "which_key_ignore" })
          break
        end
      end
    end
  end
end

-- vimtex's dict functions return v:true/v:false or 1/0 depending on the code path
local function vimtex_check(expr)
  local result = vim.fn.eval(expr)
  return result == true or result == 1
end

-- vimtex only compiles a file that has \documentclass ... \begin{document} ... \end{document}
-- (or belongs to a project with such a main file)
local function is_compileable() return vimtex_check "b:vimtex.is_compileable()" end

-- same preamble as the `template` snippet in luasnippets/tex.lua, minus the title
local preamble = {
  [[\documentclass[11pt]{article}]],
  [[\usepackage[margin=1in]{geometry}]],
  [[\usepackage{amsmath, amssymb, amsthm, mathtools}]],
  "",
  [[\newtheorem{theorem}{Theorem}]],
  [[\newtheorem{definition}{Definition}]],
  "",
  [[\begin{document}]],
  "",
}

-- start continuous compilation (the PDF opens after the build), or just open the PDF if it's already running;
-- a bare snippet of LaTeX (no preamble) is offered the notes preamble first
local function compile_and_view()
  if not is_compileable() then
    local answer =
      vim.fn.confirm("This file has no \\documentclass/\\begin{document}. Wrap it in the notes preamble?", "&Yes\n&No")
    if answer ~= 1 then return end
    vim.api.nvim_buf_set_lines(0, 0, 0, false, preamble)
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { "", [[\end{document}]] })
  end
  vim.cmd "silent! update"
  if vimtex_check "b:vimtex.compiler.is_running()" then
    vim.cmd "VimtexView"
  else
    vim.cmd "VimtexCompile"
  end
end

-- vimtex splits open its raw compiler output when a build fails without parsable errors
local function close_compiler_output()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local output = vim.api.nvim_buf_call(
      buf,
      function() return vim.fn.eval "get(get(get(b:, 'vimtex', {}), 'compiler', {}), 'output', '')" end
    )
    if output ~= "" and vim.api.nvim_buf_get_name(buf) == vim.fn.fnamemodify(output, ":p") then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
end

-- After every build: errors go to one notification that is replaced on each rebuild (instead of the quickfix
-- window), and it's dismissed once the document builds cleanly. latexmk sometimes reports success even though
-- the log has errors, so the error list decides, not the event.
local function report_build(ev)
  local errors = {}
  for _, item in ipairs(vim.fn.getqflist()) do
    if item.type == "E" then table.insert(errors, ("line %d: %s"):format(item.lnum, vim.split(item.text, "\n")[1])) end
  end
  local failed = ev.match == "VimtexEventCompileFailed"
  if failed then close_compiler_output() end

  if #errors == 0 and not failed then
    local ok, snacks = pcall(require, "snacks")
    if ok and snacks.notifier then snacks.notifier.hide "vimtex_compile" end
    return
  end
  local lines = vim.list_slice(errors, 1, 3)
  if #errors > 3 then table.insert(lines, ("... %d more"):format(#errors - 3)) end
  if #errors == 0 then table.insert(lines, "no error lines found, ,lo shows the compiler output") end
  table.insert(lines, ",le lists all errors")
  vim.notify(table.concat(lines, "\n"), vim.log.levels.ERROR, { id = "vimtex_compile", title = "LaTeX build failed" })
end

-- Command completion comes from vimtex's omnifunc instead of texlab: texlab caps its list at 50 items, so `\i`
-- stops at the \if... commands before reaching \int. texlab still completes environments, labels, citations and files.
-- Math commands are ranked first: anything vimtex shows with a glyph (∫, α, ≤, ...), commands from math packages,
-- and the glyphless math commands below.
local math_packages = { amsmath = true, amssymb = true, amsfonts = true, mathtools = true, bm = true, mathrsfs = true }
local math_commands = {}
for cmd in
  ([[
  frac dfrac tfrac binom sqrt left right big Big bigg Bigg lim limsup liminf limits sin cos tan sec csc cot
  arcsin arccos arctan sinh cosh tanh log ln exp max min sup inf det dim ker deg gcd arg Pr mod bmod pmod
  mathbb mathcal mathrm mathbf mathit mathsf mathfrak mathscr operatorname overline underline overbrace underbrace
  widehat widetilde displaystyle textstyle quad qquad
]]):gmatch "%S+"
do
  math_commands[cmd] = true
end

local function is_math_command(item)
  local details = item.labelDetails or {}
  local package = (details.detail or ""):match "^%[cmd: (%S+)%]"
  if not package then return false end -- environments, labels, citations, ...
  if math_packages[package] or math_commands[item.label] then return true end
  local has_glyph = details.description and details.description ~= ""
  return has_glyph
    and not (item.label:match "^text" or item.label:match "section" or item.label == "pounds" or item.label == "space")
end

-- nvim-autopairs conditions run before the typed key is inserted, so they look at the line and cursor as they are

-- the runs of $ right before and after the cursor, and whether the one before opens math (what precedes it is text)
-- rather than closing it; vimtex doesn't count the delimiters themselves as math
local function dollar_runs()
  local line, col = vim.api.nvim_get_current_line(), vim.api.nvim_win_get_cursor(0)[2]
  local before, after = #line:sub(1, col):match "%$*$", #line:sub(col + 1):match "^%$*"
  local start = col - before + 1
  local opens = before > 0 and (start == 1 or not require("user.latex_suite").in_math_at(vim.fn.line ".", start - 1))
  return before, after, opens
end

-- $ ... $ and $$ ... $$ as a pair: typing $ in text gives `$|$`, typing it again right away `$$|$$`
local function dollar_rule()
  local Rule = require "nvim-autopairs.rule"
  local suite = require "user.latex_suite"
  return Rule("$", "$", "tex")
    :with_pair(function()
      local line, col = vim.api.nvim_get_current_line(), vim.api.nvim_win_get_cursor(0)[2]
      if #line:sub(1, col):match "\\*$" % 2 == 1 then return false end -- \$ is a dollar sign
      local before, after, opens = dollar_runs()
      if before == 1 and after == 1 and opens then return true end
      -- a $ typed in math or right after a closing $ ends it, and one in a comment is just text
      if suite.in_math() or (before > 0 and not opens) or vim.fn["vimtex#syntax#in_comment"]() == 1 then
        return false
      end
      if line:sub(col + 1, col + 1):match "%w" then return false end
    end)
    -- the closing $ is typed over, except the second $ of `$|$`, which makes it display math
    :with_move(function()
      local before, after, opens = dollar_runs()
      if before == 1 and after == 1 and opens then return false end
      return after > 0 and (suite.in_math() or (before > 0 and not opens))
    end)
    -- <BS> deletes both only in empty math, `$a$|$b$` would lose the formulas' delimiters
    :with_del(function()
      local before, after, opens = dollar_runs()
      return opens and before == after
    end)
    -- <CR> in `$$|$$` puts the closing $$ two lines down, with the cursor on the line between
    :with_cr(function()
      local before, after, opens = dollar_runs()
      return opens and before == 2 and after == 2
    end)
end

---@type LazySpec
return {
  {
    "lervag/vimtex", -- base spec and which-key descriptions come from astrocommunity (lua/community.lua)
    init = function()
      -- zathura_simple skips xdotool window tracking (X11 only), SyncTeX still works on Wayland
      vim.g.vimtex_view_method = "zathura_simple"
      -- latexmk builds in a hidden folder beside the .tex file: its working files (.aux, .log, .fls, ...), the SyncTeX
      -- data (.synctex.gz) and the PDF zathura shows, which has to sit next to the SyncTeX file for ctrl+click and ,lv
      -- to work. After every build latexmk copies just the PDF out next to the .tex file (-out2dir, latexmk 4.87+).
      vim.g.vimtex_compiler_latexmk = {
        aux_dir = ".textras",
        out_dir = ".textras",
        options = {
          "-verbose", -- vimtex's defaults
          "-file-line-error",
          "-synctex=1",
          "-interaction=nonstopmode",
          "-out2dir=.", -- latexmk runs in the .tex file's folder
          [[-e '@out2_exts = ("pdf")']], -- by default the .synctex.gz is copied out too
        },
      }
      vim.g.vimtex_quickfix_open_on_warning = false
      vim.g.vimtex_quickfix_ignore_filters = { "Underfull", "Overfull" }
      -- never pop the quickfix window on a failed build (it reopens on every rebuild while typing), see report_build
      vim.g.vimtex_quickfix_mode = 0

      local group = vim.api.nvim_create_augroup("latex_notes", { clear = true })
      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = { "VimtexEventCompileSuccess", "VimtexEventCompileFailed" },
        desc = "Report LaTeX build errors in a notification",
        callback = report_build,
      })
      vim.api.nvim_create_autocmd("FileType", {
        group = group,
        pattern = "tex",
        desc = "LaTeX-only <Leader> mappings",
        callback = function(ev)
          hide_code_maps(ev.buf)
          require("user.latex_suite").attach(ev.buf)
          vim.keymap.set("n", "<Leader>L", compile_and_view, { buffer = ev.buf, desc = "Compile and view PDF" })
        end,
      })
      vim.api.nvim_create_autocmd({ "InsertLeave", "TextChanged" }, {
        group = group,
        pattern = "*.tex",
        desc = "Write LaTeX buffers so the running latexmk rebuilds the PDF",
        callback = function(ev)
          if not (vim.bo[ev.buf].modified and vim.bo[ev.buf].buftype == "") then return end
          -- only once <Leader>L has started the compiler for this document
          local running = vim.api.nvim_buf_call(
            ev.buf,
            function() return vim.fn.exists "b:vimtex" == 1 and vimtex_check "b:vimtex.compiler.is_running()" end
          )
          if running then vim.api.nvim_buf_call(ev.buf, function() vim.cmd "silent! update" end) end
        end,
      })
    end,
  },
  {
    "saghen/blink.cmp",
    opts = function(_, opts)
      local providers = vim.tbl_get(opts, "sources", "providers") or {}
      local lsp_transform = vim.tbl_get(providers, "lsp", "transform_items")
      local Kind = require("blink.cmp.types").CompletionItemKind

      -- LaTeX Suite keys (lua/user/latex_suite.lua), only acting in tex buffers: <Tab> expands <Tab>-triggered
      -- snippets (\sum, par, ...) and, in math, jumps tabstops / tabs out of brackets / inserts ` & ` in matrices
      -- before the completion menu gets it (<C-n>/<C-j> still pick items); <CR> inserts ` \\` + newline in matrices
      local function suite(method)
        return function() return vim.bo.filetype == "tex" and require("user.latex_suite")[method]() end
      end
      local keymap = opts.keymap or {}
      local tab = vim.deepcopy(keymap["<Tab>"] or { "select_next", "snippet_forward", "fallback" })
      table.insert(tab, 1, suite "tab")
      local enter = vim.deepcopy(keymap["<CR>"] or { "accept", "fallback" })
      table.insert(enter, #enter, suite "enter")

      opts.keymap = keymap
      keymap["<Tab>"], keymap["<CR>"] = tab, enter

      return require("astrocore").extend_tbl(opts, {
        sources = {
          per_filetype = { tex = { "omni", inherit_defaults = true } },
          providers = {
            -- autosnippets expand as they're typed, listing them only clutters the menu
            snippets = { opts = { show_autosnippets = false } },
            omni = {
              -- only the vimtex commands, texlab already covers the rest (its \begin snippet included);
              -- math commands get enough of a boost to rank above friendly-snippets' \integral..., \section, ...
              transform_items = function(_, items)
                return vim.tbl_filter(function(item)
                  if not (item.labelDetails and (item.labelDetails.detail or ""):match "^%[cmd:") then return false end
                  if item.label == "begin" then return false end
                  item.kind = Kind.Function
                  if is_math_command(item) then item.score_offset = (item.score_offset or 0) + 20 end
                  return true
                end, items)
              end,
            },
            lsp = {
              -- texlab's (capped) command list would duplicate the vimtex one
              transform_items = function(ctx, items)
                if lsp_transform then items = lsp_transform(ctx, items) end
                if vim.bo[ctx.bufnr].filetype ~= "tex" then return items end
                return vim.tbl_filter(function(item) return item.kind ~= Kind.Function end, items)
              end,
            },
          },
        },
      })
    end,
  },
  {
    "windwp/nvim-autopairs",
    config = function(plugin, opts)
      require "astronvim.plugins.configs.nvim-autopairs"(plugin, opts)
      local npairs = require "nvim-autopairs"
      -- Inside math the LaTeX Suite snippets pair (, [, { and " themselves. LuaSnip expands an autosnippet as soon as
      -- its last character is in, before the rest of autopairs' `()<Left>`, so pairing there too doubles the closer.
      local function not_in_math(o)
        if vim.bo[o.bufnr].filetype == "tex" and require("user.latex_suite").in_math() then return false end
      end
      for _, char in ipairs { "(", "[", "{", '"' } do
        for _, rule in ipairs(npairs.get_rules(char)) do
          if rule.pair_cond ~= false then rule:with_pair(not_in_math, 1) end -- first, ahead of conditions that pair
        end
      end
      npairs.add_rule(dollar_rule())
    end,
  },
  {
    "L3MON4D3/LuaSnip",
    opts = { enable_autosnippets = true }, -- math snippets in luasnippets/tex.lua expand without a trigger key
    -- AstroNvim's loader setup, minus friendly-snippets' LaTeX set: its \section/\integral... triggers would
    -- compete with the LaTeX Suite ones on <Tab> and crowd the completion menu
    config = function(_, opts)
      require("luasnip").config.setup(opts)
      require("luasnip.loaders.from_vscode").lazy_load { exclude = { "tex", "plaintex" } }
      require("luasnip.loaders.from_snipmate").lazy_load()
      require("luasnip.loaders.from_lua").lazy_load()
    end,
  },
}
