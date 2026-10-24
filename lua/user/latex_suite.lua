-- Obsidian LaTeX Suite behaviour for .tex files, on top of LuaSnip and vimtex:
--   * snippets written in LaTeX Suite's own format (luasnippets/tex.lua), converted to LuaSnip snippets by M.build
--   * autofraction: `x/` -> \frac{x}{}, `(a+b)/` -> \frac{a+b}{}
--   * tabout: <Tab> in math jumps past the closing bracket / $ around the cursor
--   * matrix shortcuts: <Tab> -> ` & ` and <CR> -> ` \\` + newline in matrix-like environments (<S-CR>: plain newline)
--   * visual snippets: select text, <Tab> (cuts it), then type the trigger (U, O, B, C, K, S, (, [, {)
-- The keys are wired up in plugins/latex.lua (blink.cmp keymaps, buffer-local maps on FileType tex).
--
-- LaTeX Suite snippet format: { trigger, replacement, options, priority = n, description = "..." }
--   options: t text, m math, M display math, n inline math, A auto-expand, r regex, w word boundary, v visual
--   replacement: $0 $1 ... tabstops in jump order (${0:default}), [[0]] [[1]] ... regex captures, ${VISUAL} selection,
--     or a Lua function(captures) returning the text
--   regex triggers are JavaScript regexes (LuaSnip's "ecma" engine), ${GREEK} ${SYMBOL} ${MORE_SYMBOLS} ${ACCENT} expand

local M = {}

-- LuaSnip is required on first use: this module is loaded from the FileType hook before LuaSnip, and loading LuaSnip
-- runs luasnippets/tex.lua, which requires this module again
local ls, s, t, i, f, rep
local function load_luasnip()
  if ls then return end
  ls = require "luasnip"
  s, t, i, f = ls.snippet, ls.text_node, ls.insert_node, ls.function_node
  rep = require("luasnip.extras").rep
end

-- LaTeX Suite's default snippet variables
M.variables = {
  GREEK = "(?:alpha|beta|gamma|Gamma|delta|Delta|epsilon|varepsilon|zeta|eta|theta|vartheta|Theta|iota|kappa|lambda|Lambda|mu|nu|xi|omicron|pi|rho|varrho|sigma|Sigma|tau|upsilon|Upsilon|phi|varphi|Phi|chi|psi|omega|Omega)",
  SYMBOL = "(?:parallel|perp|partial|nabla|hbar|ell|infty|oplus|ominus|otimes|oslash|square|star|dagger|vee|wedge|subseteq|subset|supseteq|supset|emptyset|exists|nexists|forall|implies|impliedby|iff|setminus|neg|lor|land|bigcup|bigcap|cdot|times|simeq|approx)",
  MORE_SYMBOLS = "(?:leq|geq|neq|gg|ll|equiv|sim|propto|rightarrow|leftarrow|Rightarrow|Leftarrow|leftrightarrow|to|top|mapsto|cap|cup|in|sum|prod|exp|ln|log|det|dots|vdots|ddots|pm|mp|int|iint|iiint|oint)",
  ACCENT = "(?:dot|ddot|hat|bar|tilde|vec|underline|overline|mathbf|mathcal|mathrm|mathbb)",
}

local greek = {}
for name in M.variables.GREEK:gmatch "%a+" do
  greek[name] = true
end
M.greek = greek

---------------------------------------------------------------------------------------------------- context

-- vimtex math zones that are display math (\[ \], $$ $$, equation/align/... environments)
local display_zones =
  { texMathZoneLD = true, texMathZoneTD = true, texMathZoneEnv = true, texMathZoneEnvStarred = true }

-- innermost math zone syntax group at the cursor, nil outside math (and inside \text{} in math)
local function math_zone()
  if vim.fn["vimtex#syntax#in_mathzone"]() ~= 1 then return nil end
  local stack = vim.fn["vimtex#syntax#stack"]()
  for k = #stack, 1, -1 do
    if stack[k]:match "^texMathZone" then return stack[k] end
  end
  return "texMathZone"
end

local function in_math() return math_zone() ~= nil end
local function in_display() return display_zones[math_zone()] == true end
local function in_inline()
  local zone = math_zone()
  return zone ~= nil and not display_zones[zone]
end
local function in_text() return math_zone() == nil end
M.in_math = in_math

--- whether the character at (row, col), both 1-based, is in math
function M.in_math_at(row, col)
  -- in insert mode vimtex#syntax#stack looks one column left (the character before the cursor)
  if vim.fn.mode() == "i" then col = col + 1 end
  return vim.fn["vimtex#syntax#in_mathzone"](row, col) == 1
end

-- the macro list is sorted once so a prefix check is a binary search
local macros = require "user.latex_suite_macros"
table.sort(macros)

local function is_macro_prefix(str)
  local lo, hi = 1, #macros
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if macros[mid] < str then
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return macros[lo] ~= nil and macros[lo]:sub(1, #str) == str
end
M.is_macro_prefix = is_macro_prefix

-- "Disable snippets while typing macros": while the text before the cursor is the start of a known macro (\eps... of
-- \epsilon), no other math autosnippet fires, so `psi` inside `\epsilon` stays put
local function typing_macro(line_to_cursor)
  local name = line_to_cursor:match "\\(%a%a+)$"
  return name ~= nil and is_macro_prefix("\\" .. name)
end

-- visual snippets: <Tab> in visual mode cuts the selection (LuaSnip keeps it), the next typed trigger wraps it
local selection_mark
function M.mark_selection()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  selection_mark = { buf = vim.api.nvim_get_current_buf(), row = row, col = col }
end

local function has_selection(line_to_cursor, trigger)
  if not pcall(vim.api.nvim_buf_get_var, 0, "LUASNIP_SELECT_RAW") or not selection_mark then return false end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  -- only the trigger typed right where the selection was cut
  return selection_mark.buf == vim.api.nvim_get_current_buf()
    and selection_mark.row == row
    and #line_to_cursor == selection_mark.col + #trigger
end

---------------------------------------------------------------------------------------------------- converter

local function text_node(str) return t(vim.split(str, "\n", { plain = true })) end

-- split a LaTeX Suite replacement into text / tabstop / capture / visual pieces
local function parse(replacement)
  local pieces, buffer, pos = {}, {}, 1
  local function flush()
    if #buffer > 0 then
      table.insert(pieces, { kind = "text", text = table.concat(buffer) })
      buffer = {}
    end
  end
  while pos <= #replacement do
    local num, default, stop
    if replacement:find("^%${VISUAL}", pos) then
      flush()
      table.insert(pieces, { kind = "visual" })
      pos = pos + #"${VISUAL}"
    elseif replacement:find("^%${%d+:", pos) then
      num = replacement:match("^%${(%d+):", pos)
      -- default text runs to the matching brace
      local depth, k = 1, pos + #num + 3
      while k <= #replacement do
        local c = replacement:sub(k, k)
        if c == "{" then
          depth = depth + 1
        elseif c == "}" then
          depth = depth - 1
          if depth == 0 then break end
        end
        k = k + 1
      end
      default, stop = replacement:sub(pos + #num + 3, k - 1), k + 1
      flush()
      table.insert(pieces, { kind = "tab", num = tonumber(num), default = default })
      pos = stop
    elseif replacement:find("^%${%d+}", pos) or replacement:find("^%$%d+", pos) then
      num = replacement:match("^%${(%d+)}", pos)
      stop = num and pos + #num + 3 or nil
      if not num then
        num = replacement:match("^%$(%d+)", pos)
        stop = pos + #num + 1
      end
      flush()
      table.insert(pieces, { kind = "tab", num = tonumber(num) })
      pos = stop
    elseif replacement:find("^%[%[%d+%]%]", pos) then
      num = replacement:match("^%[%[(%d+)%]%]", pos)
      flush()
      table.insert(pieces, { kind = "capture", num = tonumber(num) })
      pos = pos + #num + 4
    else
      table.insert(buffer, replacement:sub(pos, pos))
      pos = pos + 1
    end
  end
  flush()
  return pieces
end

local function capture_node(num)
  return f(function(_, snip) return snip.captures[num + 1] or "" end)
end

local function visual_node()
  return f(function(_, snip)
    local selection = snip.env.LS_SELECT_RAW
    return (type(selection) == "table" and #selection > 0) and selection or ""
  end)
end

-- LaTeX Suite numbers tabstops from $0 in jump order and ends the snippet on the last one; LuaSnip jumps 1, 2, ...
-- and ends on 0, so the last tabstop becomes 0 when it's a plain one-off stop
local function to_nodes(replacement)
  local pieces = parse(replacement)
  local count, has_default = {}, {}
  for _, p in ipairs(pieces) do
    if p.kind == "tab" then
      count[p.num] = (count[p.num] or 0) + 1
      if p.default then has_default[p.num] = true end
    end
  end
  local order = vim.tbl_keys(count)
  table.sort(order)
  local last = order[#order]
  local index = {}
  for rank, num in ipairs(order) do
    index[num] = rank
  end
  if last and count[last] == 1 and not has_default[last] then index[last] = 0 end

  local nodes, seen = {}, {}
  for _, p in ipairs(pieces) do
    if p.kind == "text" then
      table.insert(nodes, text_node(p.text))
    elseif p.kind == "capture" then
      table.insert(nodes, capture_node(p.num))
    elseif p.kind == "visual" then
      table.insert(nodes, visual_node())
    elseif seen[p.num] then
      table.insert(nodes, rep(index[p.num]))
    else
      seen[p.num] = true
      table.insert(nodes, i(index[p.num], p.default and vim.split(p.default, "\n", { plain = true }) or nil))
    end
  end
  return nodes
end

local function expand_variables(trigger)
  return (trigger:gsub("%${(%u[%u_]*)}", function(name) return M.variables[name] end))
end

local function all(conditions)
  return function(...)
    for _, condition in ipairs(conditions) do
      if not condition(...) then return false end
    end
    return true
  end
end

--- Convert LaTeX Suite snippet definitions; returns snippets, autosnippets (what a luasnippets file returns).
function M.build(definitions)
  load_luasnip()
  local snippets, autosnippets = {}, {}
  for _, def in ipairs(definitions) do
    local trigger, replacement, options = def[1], def[2], def[3] or ""
    local function has(flag) return options:find(flag, 1, true) ~= nil end
    local regex, auto = has "r", has "A" or has "v"
    local math_mode = has "m" or has "M" or has "n"

    local conditions = {}
    if has "t" then table.insert(conditions, in_text) end
    if has "m" then table.insert(conditions, in_math) end
    if has "M" then table.insert(conditions, in_display) end
    if has "n" then table.insert(conditions, in_inline) end
    if auto and math_mode and not def.while_typing_macro then
      table.insert(conditions, function(line_to_cursor) return not typing_macro(line_to_cursor) end)
    end
    if has "v" then table.insert(conditions, has_selection) end
    if def.condition then table.insert(conditions, def.condition) end

    local nodes
    if type(replacement) == "function" then
      nodes = {
        f(function(_, snip) return vim.split(replacement(snip.captures, snip.trigger), "\n", { plain = true }) end),
      }
    else
      nodes = to_nodes(replacement)
    end

    local snippet = s({
      trig = regex and expand_variables(trigger) or trigger,
      trigEngine = regex and "ecma" or "plain",
      wordTrig = has "w",
      -- LaTeX Suite tries higher priority first, then the longer trigger (so `lr(` beats `(` and `([a-zA-Z])hat`
      -- beats `hat`), then file order; LuaSnip keeps file order within a priority
      priority = 10000 + (def.priority or 0) * 1000 + math.min(#(regex and expand_variables(trigger) or trigger), 999),
      snippetType = auto and "autosnippet" or "snippet",
      desc = def.description,
      condition = all(conditions),
      -- only offer math snippets in the completion menu inside math
      show_condition = function()
        if has "t" then return in_text() end
        return not math_mode or in_math()
      end,
    }, nodes)
    table.insert(auto and autosnippets or snippets, snippet)
  end
  return snippets, autosnippets
end

---------------------------------------------------------------------------------------------------- autofraction

-- LaTeX Suite's numerator rules: stop at a space, $ ( [ { or + - = and step over bracketed groups
local breaking = " $([{\t+-="
local openers = { [")"] = "(", ["]"] = "[", ["}"] = "{" }

local function matching_open(text, k)
  local close, open, depth = text:sub(k, k), openers[text:sub(k, k)], 0
  for j = k, 1, -1 do
    local c = text:sub(j, j)
    if c == close then
      depth = depth + 1
    elseif c == open then
      depth = depth - 1
      if depth == 0 then return j end
    end
  end
end

-- inside ^{...} a slash stays a slash (LaTeX Suite's excluded environment)
local function in_superscript(text)
  local depth = 0
  for k = #text, 1, -1 do
    local c = text:sub(k, k)
    if c == "}" then
      depth = depth + 1
    elseif c == "{" then
      if depth == 0 then return text:sub(k - 1, k - 1) == "^" end
      depth = depth - 1
    end
  end
  return false
end

local function numerator(line_to_cursor)
  local text = line_to_cursor:sub(1, -2) -- without the typed /
  if in_superscript(text) then return nil end
  local k, start = #text, 1
  while k >= 1 do
    local c = text:sub(k, k)
    if openers[c] then
      local open = matching_open(text, k)
      if not open then break end
      k = open - 1
    elseif breaking:find(c, 1, true) then
      start = k + 1
      break
    else
      k = k - 1
    end
  end
  local num = text:sub(start)
  if num == "" then return nil end
  if num:sub(1, 1) == "(" and num:sub(-1) == ")" and matching_open(num, #num) == 1 then num = num:sub(2, -2) end
  return start, num
end

function M.autofraction()
  load_luasnip()
  return s({
    trig = "/",
    wordTrig = false,
    snippetType = "autosnippet",
    priority = 1, -- below every LaTeX Suite snippet (`//` in particular)
    desc = "autofraction",
    condition = function(line_to_cursor) return in_math() and not typing_macro(line_to_cursor:sub(1, -2)) end,
    resolveExpandParams = function(_, line_to_cursor, matched)
      local start, num = numerator(line_to_cursor)
      if not start then return nil end
      local row = vim.api.nvim_win_get_cursor(0)[1] - 1
      return {
        trigger = matched,
        captures = { num },
        clear_region = { from = { row, start - 1 }, to = { row, #line_to_cursor } },
      }
    end,
  }, { t "\\frac{", capture_node(0), t "}{", i(1), t "}", i(0) })
end

---------------------------------------------------------------------------------------------------- keys

-- environments where <Tab>/<CR> become & and \\ (LaTeX Suite's list plus the aligned/gathered forms used in .tex)
local matrix_envs = {}
for _, name in ipairs {
  "pmatrix",
  "cases",
  "align",
  "gather",
  "bmatrix",
  "Bmatrix",
  "vmatrix",
  "Vmatrix",
  "array",
  "matrix",
  "aligned",
  "gathered",
  "alignat",
  "alignedat",
  "split",
  "smallmatrix",
} do
  matrix_envs[name] = true
end

local function in_matrix()
  if not in_math() then return false end
  local ok, env = pcall(vim.fn["vimtex#env#get_inner"])
  return ok and type(env) == "table" and env.name ~= nil and matrix_envs[(env.name:gsub("%*$", ""))] == true
end

-- \langle ... \rangle style pairs that open/close a group by themselves
local self_open = { langle = true, lvert = true, lVert = true, lceil = true, lfloor = true }
local self_close = { rangle = true, rvert = true, rVert = true, rceil = true, rfloor = true }

-- column (0-based, just after it) of the bracket / math delimiter that closes the group around the cursor
local function tabout_target()
  local line = vim.api.nvim_get_current_line()
  local k, depth = vim.api.nvim_win_get_cursor(0)[2] + 1, 0
  while k <= #line do
    local c = line:sub(k, k)
    local name = c == "\\" and line:match("^%a+", k + 1)
    if name then
      k = k + 1 + #name
      local delim = line:sub(k, k)
      if name == "left" and (delim == "|" or delim == ".") then
        depth, k = depth + 1, k + 1
      elseif name == "right" and (delim == "|" or delim == ".") then
        if depth == 0 then return k end
        depth, k = depth - 1, k + 1
      elseif self_open[name] then
        depth = depth + 1
      elseif self_close[name] then
        if depth == 0 then return k - 1 end
        depth = depth - 1
      end -- \left( and \right) continue with the bracket itself
    elseif c == "\\" then -- escaped character: \{ \} \( \) \[ \]
      local escaped = line:sub(k + 1, k + 1)
      if escaped == "{" or escaped == "(" or escaped == "[" then
        depth = depth + 1
      elseif escaped == "}" or escaped == ")" or escaped == "]" then
        if depth == 0 then return k + 1 end
        depth = depth - 1
      end
      k = k + 2
    elseif c == "(" or c == "[" or c == "{" then
      depth, k = depth + 1, k + 1
    elseif c == ")" or c == "]" or c == "}" then
      if depth == 0 then return k end
      depth, k = depth - 1, k + 1
    elseif c == "$" and depth == 0 then
      return line:sub(k + 1, k + 1) == "$" and k + 1 or k
    else
      k = k + 1
    end
  end
end

local function feed(keys) vim.api.nvim_feedkeys(vim.keycode(keys), "n", false) end

--- <Tab> in a tex buffer, before the completion menu gets it, the LaTeX Suite order: expand a <Tab>-triggered snippet
--- (\\sum, par, ...); in math also jump to the next tabstop, tab out of the bracket / $ around the cursor, or insert
--- ` & ` in a matrix. Returns false to let completion/snippet handling continue.
function M.tab()
  load_luasnip()
  -- blink runs this under textlock (an <expr> mapping): decide now, edit on the next tick like blink's own actions
  local function run(action)
    local blink = package.loaded["blink.cmp"]
    if blink then blink.hide() end
    vim.schedule(action)
    return true
  end

  if ls.expandable() then
    return run(function() ls.expand() end)
  end
  if not in_math() then return false end
  if ls.locally_jumpable(1) then
    return run(function() ls.jump(1) end)
  end

  local target = tabout_target()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  -- in a matrix, & unless the cursor sits right before the closer (`}`, `\\right)`, `\\rangle`, ...)
  local between = target and vim.api.nvim_get_current_line():sub(col + 1, target):gsub("^%s+", "") or ""
  local closer_next = between:match "^[%)%]}%$]+$" or between:match "^\\%a+[%)%]}|.]?$" or between:match "^\\[%)%]}]$"
  if in_matrix() and not closer_next then
    return run(function() feed " & " end)
  end
  if not target then return false end
  return run(function() vim.api.nvim_win_set_cursor(0, { vim.api.nvim_win_get_cursor(0)[1], target }) end)
end

--- <CR>, when the completion menu didn't take it: ` \\` + newline in a matrix
function M.enter()
  if vim.bo.filetype ~= "tex" or not in_matrix() then return false end
  feed " \\\\<CR>"
  return true
end

--- buffer-local keys for a tex buffer
function M.attach(buf)
  -- visual snippets: cut the selection, then type the trigger
  vim.keymap.set(
    "x",
    "<Tab>",
    require("luasnip.util.select").cut_keys .. "<Cmd>lua require('user.latex_suite').mark_selection()<CR>",
    { buffer = buf, desc = "Cut selection for a LaTeX Suite visual snippet" }
  )
  -- plain newline in a matrix
  vim.keymap.set("i", "<S-CR>", "<CR>", { buffer = buf, desc = "Newline without \\\\" })
end

return M
