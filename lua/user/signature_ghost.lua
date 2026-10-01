-- Signature ghost text: shows the parameters of a function (with their default values) as ghost text, e.g.
--   ipaddress.ip_netw<Tab>                   -> ip_network|(address, strict=True)    (completion menu selection)
--   ipaddress.ip_network("10.0.0.0/8"|)      -> , strict=True                         (inside the call)
-- <M-s> inserts it as a snippet: every parameter is a placeholder (defaults pre-filled); <M-s> again (or <Tab>
-- when the completion menu is closed) jumps to the next one.
-- Inside a call, the data comes from signature help (`textDocument/signatureHelp`); for the selected completion
-- item, from the signature in its documentation (`completionItem/resolve`).
-- Hooked up per buffer in plugins/astrolsp.lua.
local M = {}

local api = vim.api
local ns = api.nvim_create_namespace "signature_ghost"
local timer = assert(vim.uv.new_timer())
local shown = {} -- buf -> { text = ghost text, snippet = snippet body }
local resolved = setmetatable({}, { __mode = "k" }) -- completion item -> parameter list
local FUNCTION_KINDS = { [2] = true, [3] = true, [4] = true } -- Method, Function, Constructor
local enabled = true

api.nvim_set_hl(0, "SignatureGhost", { link = "LspInlayHint", default = true })

function M.clear(buf)
  buf = buf or api.nvim_get_current_buf()
  if api.nvim_buf_is_valid(buf) then api.nvim_buf_clear_namespace(buf, ns, 0, -1) end
  shown[buf] = nil
end

-- Split at top-level commas. `angles` also treats <...> as brackets (TS/Rust generics in signatures).
local function split_args(text, angles)
  local args, depth, start = {}, 0, 1
  for i = 1, #text do
    local c = text:sub(i, i)
    local prev = text:sub(i - 1, i - 1)
    if c == "(" or c == "[" or c == "{" or (angles and c == "<") then
      depth = depth + 1
    elseif c == ")" or c == "]" or c == "}" or (angles and c == ">" and prev ~= "-" and prev ~= "=") then
      depth = depth - 1
    elseif c == "," and depth == 0 then
      args[#args + 1] = text:sub(start, i - 1)
      start = i + 1
    end
  end
  args[#args + 1] = text:sub(start)
  return args
end

-- Text of the call the cursor is in: from just after its unmatched `(` up to the cursor (up to 30 lines back).
local function call_text(buf, row, col)
  local lines = api.nvim_buf_get_lines(buf, math.max(0, row - 30), row + 1, false)
  lines[#lines] = lines[#lines]:sub(1, col)
  local text = table.concat(lines, "\n")
  local depth = 0
  for i = #text, 1, -1 do
    local c = text:sub(i, i)
    if c == ")" or c == "]" or c == "}" then
      depth = depth + 1
    elseif c == "(" or c == "[" or c == "{" then
      if depth == 0 then return c == "(" and text:sub(i + 1) or nil end
      depth = depth - 1
    end
  end
end

-- Parameter text -> { name, default } or { marker = "/" | "*" | "*args" | "**kwargs" }. Looks like
-- `strict: bool = True` (Python), `strict: boolean` (Lua/TS), `options?: Options` (TS), `strict: bool` (Rust).
local function parse_param(label)
  label = vim.trim(label)
  if label == "/" or label == "*" then return { marker = label } end
  if label:match "^%*%*" then return { marker = "**kwargs" } end
  if label:match "^%*" or label:match "^%.%.%." then return { marker = "*args" } end
  local name = label:match "^[%w_$]+"
  if not name then return nil end
  local default = label:match "=%s*(.-)%s*$"
  return { name = name, default = default ~= "" and default or nil }
end

-- Signature help parameter labels are either strings or [start, end) UTF-16 offsets into the signature label.
local function sig_param_label(sig_label, label)
  if type(label) ~= "table" then return label end
  local ok_s, s = pcall(vim.str_byteindex, sig_label, "utf-16", label[1], false)
  local ok_e, e = pcall(vim.str_byteindex, sig_label, "utf-16", label[2], false)
  return sig_label:sub((ok_s and s or label[1]) + 1, ok_e and e or label[2])
end

local function escape(text) return (text:gsub("[\\$}]", "\\%0")) end

-- Ghost text and snippet body for a list of pieces: strings are literal text, tables are parameters
-- ({ name, default }) or { value = ... } for a lone default value.
local function render(pieces)
  local text, snippet, n = {}, {}, 0
  for _, piece in ipairs(pieces) do
    if type(piece) == "string" then
      text[#text + 1], snippet[#snippet + 1] = piece, escape(piece)
    else
      n = n + 1
      if piece.value then
        text[#text + 1], snippet[#snippet + 1] = piece.value, ("${%d:%s}"):format(n, escape(piece.value))
      elseif piece.default then
        text[#text + 1] = piece.name .. "=" .. piece.default
        snippet[#snippet + 1] = ("%s=${%d:%s}"):format(escape(piece.name), n, escape(piece.default))
      else
        text[#text + 1], snippet[#snippet + 1] = piece.name, ("${%d:%s}"):format(n, escape(piece.name))
      end
    end
  end
  return { text = table.concat(text), snippet = table.concat(snippet) .. "$0" }
end

local function join(params, pieces)
  for i, p in ipairs(params) do
    if i > 1 then pieces[#pieces + 1] = ", " end
    pieces[#pieces + 1] = p
  end
  return pieces
end

local function keyword_of(arg) return arg:match "^%s*([%w_]+)%s*=[^=]" or arg:match "^%s*([%w_]+)%s*=$" end

-- Inside a call: what is still missing, worked out from the typed arguments rather than the server's
-- "active parameter", which points at **kwargs as soon as a call only takes keyword arguments.
local function call_ghost(result, args)
  local sig = result and result.signatures and result.signatures[(result.activeSignature or 0) + 1]
  if not sig or not sig.parameters or #sig.parameters == 0 then return nil end

  local current = args[#args]
  local current_blank = current:match "^%s*$" ~= nil
  local used, positional = {}, 0
  for i = 1, #args - 1 do
    local kw = keyword_of(args[i])
    if kw then
      used[kw] = true
    else
      positional = positional + 1
    end
  end

  local missing, keyword_only = {}, false
  for _, param in ipairs(sig.parameters) do
    local p = parse_param(sig_param_label(sig.label, param.label))
    if p and p.marker then
      if p.marker == "*" or p.marker == "*args" then keyword_only = true end
      if p.marker == "*args" then positional = 0 end -- *args swallows the remaining positional arguments
    elseif p then
      if not keyword_only and positional > 0 then
        positional = positional - 1 -- filled by a positional argument
      elseif not used[p.name] then
        p.keyword_only = keyword_only
        missing[#missing + 1] = p
      end
    end
  end

  -- the next positional slot, which a plain (non keyword) argument being typed would fill
  local slot = missing[1] and not missing[1].keyword_only and missing[1] or nil

  -- typing the start of a keyword (`ind`): complete it (`ent=None`); not for the positional slot,
  -- where the text is far more likely a variable being passed
  local prefix = current:match "^%s*([%a_][%w_]*)$"
  if prefix then
    for _, p in ipairs(missing) do
      if p ~= slot and vim.startswith(p.name, prefix) then
        return render { p.name:sub(#prefix + 1) .. "=", { value = p.default or "" } }
      end
    end
  end

  local kw = keyword_of(current)
  -- `sort_keys=` with no value yet: offer its default
  if kw and current:match "=%s*$" then
    for _, p in ipairs(missing) do
      if p.name == kw then return p.default and render { { value = p.default } } or nil end
    end
  end
  if not current_blank and not kw and slot then table.remove(missing, 1) end
  local params = vim.tbl_filter(function(p) return p.name ~= kw end, missing)
  if #params == 0 then return nil end
  return render(join(params, current_blank and {} or { ", " }))
end

-- Parameters of a completion item, from the signature in the first code block of its documentation
-- (falls back to the label, e.g. lua_ls's `nvim_buf_set_lines(buf, start, ...)`).
local function item_params(item)
  local doc = item.documentation
  doc = type(doc) == "table" and doc.value or doc or ""
  local name = (item.filterText or item.label):match "^[%w_.:$]+" or ""
  for _, source in ipairs { doc:match "```[%w_]*\n(.-)\n```", item.label } do
    local s = source:find(name .. "%s*%(") or source:find "%("
    local open = s and source:find("(", s, true)
    if open then
      local depth, close = 0, nil
      for i = open, #source do
        local c = source:sub(i, i)
        if c == "(" then
          depth = depth + 1
        elseif c == ")" then
          depth = depth - 1
          if depth == 0 then
            close = i
            break
          end
        end
      end
      if close then
        local params = {}
        local inner = source:sub(open + 1, close - 1)
        if inner:match "%S" then
          for i, arg in ipairs(split_args(inner:gsub("\n", " "), true)) do
            local p = parse_param(arg)
            if p and not p.marker and not (i == 1 and (p.name == "self" or p.name == "cls")) then
              params[#params + 1] = p
            end
          end
        end
        return params
      end
    end
  end
end

-- an AI suggestion from minuet sits at the same spot; it wins
local function minuet_visible(buf)
  local minuet = package.loaded["minuet.virtualtext"]
  return minuet and api.nvim_buf_get_extmark_by_id(buf, minuet.ns_id, 1, {})[1] ~= nil
end

local function show(buf, cursor, ghost, preview)
  M.clear(buf)
  if not ghost or minuet_visible(buf) then return end
  api.nvim_buf_set_extmark(buf, ns, cursor[1] - 1, cursor[2], {
    virt_text = { { ghost.text, "SignatureGhost" } },
    virt_text_pos = "inline",
  })
  ghost.preview = preview
  shown[buf] = ghost
end

-- Only answer for the state the request was made in.
local function still(buf, tick, cursor)
  if not api.nvim_buf_is_valid(buf) or buf ~= api.nvim_get_current_buf() then return false end
  if not vim.fn.mode():match "^i" or api.nvim_buf_get_changedtick(buf) ~= tick then return false end
  local now = api.nvim_win_get_cursor(0)
  return now[1] == cursor[1] and now[2] == cursor[2]
end

-- Completion menu: the selected item is a function -> preview its full parameter list after the name.
local function update_from_menu(buf, cursor, tick)
  local blink = package.loaded["blink.cmp"]
  if not (blink and blink.is_menu_visible()) then return false end
  local item = blink.get_selected_item()
  if not (item and FUNCTION_KINDS[item.kind] and item.client_id) then return false end
  if api.nvim_get_current_line():sub(cursor[2] + 1, cursor[2] + 1) == "(" then return false end

  local function display(params)
    if not still(buf, tick, cursor) or blink.get_selected_item() ~= item then return end
    if not params then return M.clear(buf) end
    local pieces = join(params, { "(" })
    pieces[#pieces + 1] = ")"
    show(buf, cursor, render(pieces), true)
  end

  if resolved[item] ~= nil or item.documentation then
    resolved[item] = resolved[item] or item_params(item) or false
    display(resolved[item] or nil)
    return true
  end
  local client = vim.lsp.get_client_by_id(item.client_id)
  if not (client and client:supports_method "completionItem/resolve") then
    resolved[item] = item_params(item) or false
    display(resolved[item] or nil)
    return true
  end
  client:request("completionItem/resolve", item, function(err, res)
    resolved[item] = (not err and res and item_params(vim.tbl_extend("force", item, res))) or item_params(item) or false
    display(resolved[item] or nil)
  end, buf)
  return true
end

-- Inside a call: what is still missing, but only at the end of the arguments (nothing but `)` after the cursor).
local function update_from_call(buf, cursor, tick)
  local rest = api.nvim_get_current_line():sub(cursor[2] + 1)
  if not (rest:match "^%s*$" or rest:match "^%s*%)") then return M.clear(buf) end
  local text = call_text(buf, cursor[1] - 1, cursor[2])
  local client = text and vim.lsp.get_clients({ bufnr = buf, method = "textDocument/signatureHelp" })[1]
  if not client then return M.clear(buf) end
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  client:request("textDocument/signatureHelp", params, function(err, result)
    if err or not still(buf, tick, cursor) then return end
    show(buf, cursor, call_ghost(result, split_args(text)), false)
  end, buf)
end

function M.update(buf)
  buf = buf or api.nvim_get_current_buf()
  if not enabled then return M.clear(buf) end
  if buf ~= api.nvim_get_current_buf() or not vim.fn.mode():match "^i" then return M.clear(buf) end
  local cursor = api.nvim_win_get_cursor(0)
  local tick = api.nvim_buf_get_changedtick(buf)
  if not update_from_menu(buf, cursor, tick) then update_from_call(buf, cursor, tick) end
end

-- follow blink.cmp's menu: selecting an item or closing the menu changes what to show
local hooked = false
local function hook_blink()
  local list = package.loaded["blink.cmp.completion.list"]
  if hooked or not list then return end
  hooked = true
  local function refresh() M.schedule(api.nvim_get_current_buf()) end
  list.select_emitter:on(refresh)
  list.hide_emitter:on(refresh)
end

--- Debounced `update`, for CursorMovedI/TextChangedI and completion menu changes.
function M.schedule(buf)
  hook_blink()
  M.clear(buf)
  timer:stop()
  timer:start(120, 0, vim.schedule_wrap(function() M.update(buf) end))
end

--- Turn the ghost text on/off everywhere (<Leader>uG).
function M.toggle()
  enabled = not enabled
  timer:stop()
  for buf in pairs(shown) do
    M.clear(buf)
  end
  vim.notify("Signature ghost text " .. (enabled and "enabled" or "disabled"))
end

--- Insert the ghost text at the cursor as a snippet; without ghost text, jump to the next snippet placeholder
--- (<Tab> picks completion items first whenever the menu is open). Returns false when there was nothing to do.
function M.accept()
  local buf = api.nvim_get_current_buf()
  local ghost = shown[buf]
  if not ghost then
    local ok, luasnip = pcall(require, "luasnip")
    if ok and luasnip.locally_jumpable(1) then
      local blink = package.loaded["blink.cmp"]
      if blink then blink.hide() end
      luasnip.jump(1)
      return true
    end
    if vim.snippet.active { direction = 1 } then
      vim.snippet.jump(1)
      return true
    end
    return false
  end
  M.clear(buf)
  local blink = package.loaded["blink.cmp"]
  if ghost.preview and blink then blink.hide() end -- keep the previewed function name, close the menu
  local ok, luasnip = pcall(require, "luasnip")
  if ok then
    luasnip.lsp_expand(ghost.snippet)
  else
    vim.snippet.expand(ghost.snippet)
  end
  return true
end

return M
