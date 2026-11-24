-- <Leader>k: cheat sheet of the keys that are not behind <Leader> (those are in the which-key popup already).
-- One line per key: the keys to press, what they do, and the modes they work in. Type to filter (by key,
-- description or mode); <CR> presses the selected key when it is a normal mode one.
-- Only mappings that have a description are listed, including the ones local to the current buffer.
local M = {}

-- in the order they are listed ("v" mappings are visual + select: shown as visual)
local modes = { "n", "x", "o", "i", "c", "t" }
local mode_names =
  { n = "normal", x = "visual", v = "visual", o = "operator", i = "insert", c = "command", t = "terminal" }

local modifiers = { C = "Ctrl", S = "Shift", M = "Alt", A = "Alt", D = "Super" }
local key_names = {
  lt = "<",
  Bar = "|",
  Bslash = "\\",
  CR = "Enter",
  BS = "Backspace",
  Del = "Delete",
  NL = "Ctrl+j", -- <NL> is how Neovim stores <C-J>
}

--- One `<...>` key as it is pressed: "C-H" -> "Ctrl+h", "F17" -> "Shift+F5"
local function special(name)
  local mods = {}
  while name:find "^%a%-." do
    table.insert(mods, modifiers[name:sub(1, 1):upper()] or name:sub(1, 1))
    name = name:sub(3)
  end
  -- terminals send Shift+F1..F12 as F13..F24 and Ctrl+F1..F12 as F25..F36
  local fn = tonumber(name:match "^F(%d+)$")
  if fn and fn > 12 and fn <= 36 then
    table.insert(mods, fn > 24 and "Ctrl" or "Shift")
    name = "F" .. (fn - 1) % 12 + 1
  end
  name = key_names[name] or name
  -- <C-H> and <C-h> are the same key; only Alt keeps upper and lower case apart
  if #name == 1 and vim.list_contains(mods, "Ctrl") and not vim.list_contains(mods, "Alt") then name = name:lower() end
  table.insert(mods, name)
  return table.concat(mods, "+")
end

--- The keys of a mapping as they are pressed: "<C-W>d" -> "Ctrl+w d", "[<Space>" -> "[ Space", "gx" -> "gx"
local function keys(map)
  local lhs = vim.fn.keytrans(map.lhsraw or map.lhs)
  local parts, plain = {}, ""
  local function flush()
    if plain ~= "" then table.insert(parts, plain) end
    plain = ""
  end
  local i = 1
  while i <= #lhs do
    local name = lhs:match("^<([^<>]+)>", i)
    if name then
      local key = special(name)
      if #key == 1 then
        plain = plain .. key
      else
        flush()
        table.insert(parts, key)
      end
      i = i + #name + 2
    else
      plain = plain .. lhs:sub(i, i)
      i = i + 1
    end
  end
  flush()
  return table.concat(parts, " ")
end

local function listed(map, leader)
  local desc = map.desc
  if not desc or desc == "" then return false end
  -- which-key's own triggers, and Neovim's tweaks of built-in keys (Y, &, *: described only as ":help Y-default")
  if desc:find "^which%-key%-trigger" or desc:find "^:help .*%-default$" then return false end
  local lhs = map.lhs
  return not (vim.startswith(lhs, leader) or lhs:find "^<Plug>" or lhs:find "^<SNR>" or lhs:find "^\128")
end

--- The rows of the cheat sheet for the current buffer: { keys, desc, modes = { "normal", ... }, lhs }
function M.rows()
  local leader = vim.g.mapleader or "\\"
  local rows, by_id = {}, {}
  for order, mode in ipairs(modes) do
    -- a buffer-local mapping hides the global one on the same keys
    local maps = {}
    for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
      maps[map.lhs] = map
    end
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, mode)) do
      maps[map.lhs] = map
    end
    for _, map in pairs(maps) do
      if listed(map, leader) then
        local row = { keys = keys(map), desc = vim.trim(map.desc), lhs = map.lhs, order = order, modes = {} }
        local id = row.keys .. "\n" .. row.desc
        row = by_id[id] or row
        if not by_id[id] then
          by_id[id] = row
          table.insert(rows, row)
        end
        local name = mode_names[mode]
        if not vim.list_contains(row.modes, name) then table.insert(row.modes, name) end
      end
    end
  end
  table.sort(rows, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    local ka, kb = a.keys:lower(), b.keys:lower()
    if ka ~= kb then return ka < kb end
    return a.keys < b.keys
  end)
  return rows
end

function M.open()
  local rows = M.rows()
  local width = { keys = 0, desc = 0 }
  local items = {}
  for i, row in ipairs(rows) do
    width.keys = math.max(width.keys, vim.api.nvim_strwidth(row.keys))
    width.desc = math.max(width.desc, vim.api.nvim_strwidth(row.desc))
    local modes_text = table.concat(row.modes, ", ")
    items[i] = { idx = i, row = row, modes = modes_text, text = row.keys .. " " .. row.desc .. " " .. modes_text }
  end
  width.desc = math.min(width.desc, 58) -- the few longer descriptions push their modes to the right

  local snacks = require "snacks"
  local align = snacks.picker.util.align
  snacks.picker.pick {
    title = "Keys without <Leader>",
    items = items,
    format = function(item)
      return {
        { align(item.row.keys, width.keys + 3), "SnacksPickerKeymapLhs" },
        { align(item.row.desc, width.desc + 3) },
        { item.modes, "SnacksPickerComment" },
      }
    end,
    layout = {
      hidden = { "preview" },
      layout = {
        backdrop = false,
        box = "vertical",
        width = 0.7,
        min_width = 80,
        max_width = 110,
        height = 0.8,
        border = true,
        title = "{title}",
        title_pos = "center",
        { win = "input", height = 1, border = "bottom" },
        { win = "list", border = "none" },
      },
    },
    confirm = function(picker, item)
      picker:close()
      if item and vim.list_contains(item.row.modes, "normal") then
        vim.schedule(function() vim.api.nvim_input(item.row.lhs) end)
      end
    end,
  }
end

return M
