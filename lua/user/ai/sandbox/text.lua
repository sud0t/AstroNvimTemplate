-- Text for the tool sandbox: the characters that do not show on a screen, written out.
local M = {}

--- Whether the character with the code point `cp` takes no room on a screen, or changes how the text around
--- it is laid out: what text is hidden with, from the person who reads it and not from a model.
local function unseen(cp)
  return (cp < 0x20 and cp ~= 0x09 and cp ~= 0x0A and cp ~= 0x0D)
    or (cp >= 0x7F and cp <= 0x9F)
    or cp == 0xAD
    or cp == 0x34F
    or cp == 0x61C
    or cp == 0x115F
    or cp == 0x1160
    or cp == 0x17B4
    or cp == 0x17B5
    or (cp >= 0x180B and cp <= 0x180F)
    or (cp >= 0x200B and cp <= 0x200F)
    or (cp >= 0x2028 and cp <= 0x202E)
    or (cp >= 0x2060 and cp <= 0x206F)
    or cp == 0x3164
    or (cp >= 0xFE00 and cp <= 0xFE0F)
    or cp == 0xFEFF
    or cp == 0xFFA0
    or (cp >= 0xFFF9 and cp <= 0xFFFB)
    or (cp >= 0x1BCA0 and cp <= 0x1BCA3)
    or (cp >= 0x1D173 and cp <= 0x1D17A)
    or (cp >= 0xE0000 and cp <= 0xE0FFF)
end

--- The code point that the bytes `seq` are in UTF-8, or nil when they are not one character of it.
local function code_point(seq)
  local a, b, c, d = seq:byte(1, 4)
  local cp, least
  if #seq == 1 and a < 0x80 then
    return a
  elseif #seq == 2 and a >= 0xC2 and a <= 0xDF then
    cp, least = (a - 0xC0) * 0x40 + (b - 0x80), 0x80
  elseif #seq == 3 and a >= 0xE0 and a <= 0xEF then
    cp, least = (a - 0xE0) * 0x1000 + (b - 0x80) * 0x40 + (c - 0x80), 0x800
  elseif #seq == 4 and a >= 0xF0 and a <= 0xF4 then
    cp, least = (a - 0xF0) * 0x40000 + (b - 0x80) * 0x1000 + (c - 0x80) * 0x40 + (d - 0x80), 0x10000
  end
  -- (not a longer way to write a shorter one, and not half of a UTF-16 pair)
  if not cp or cp < least or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then return nil end
  return cp
end

--- The three that emoji are put together with: a joiner, and "as text" / "as a picture".
local function joins(cp) return cp == 0x200D or cp == 0xFE0E or cp == 0xFE0F end

--- `text` with every character that does not show written out (`<U+200B>`; bytes that are no text: `<FF>`),
--- how many there were, the first one as it is written out and the line it is in. Line breaks and tabs stay.
--- The pieces emoji are made of stay where emoji have them: straight after a character outside ASCII, two in
--- a row at most (more of them would be a text of their own), and in a keycap (a digit, `#` or `*`, U+FE0F,
--- U+20E3). `strict`: they are written out as well (where every character counts: what is sent to the web).
---@return string spelled, integer count, string|nil first, integer|nil line
local function spell_out(text, strict)
  local count, first, at = 0, nil, nil
  local shown_until, run = 0, 0 -- where the last character outside ASCII that stayed ends; joiners since
  local function note(pos, shown)
    count = count + 1
    if not first then
      first, at = shown, pos
    end
    return shown
  end
  local spelled = text:gsub("()([%z\1-\8\11\12\14-\31\127-\255][\128-\191]*)", function(pos, seq)
    local cp = code_point(seq)
    if cp and joins(cp) and not strict then
      local after_shown = pos == shown_until and run < 2
      local keycap = cp == 0xFE0F
        and text:sub(pos - 1, pos - 1):find "[%d#*]"
        and text:sub(pos + #seq, pos + #seq + 2) == "\226\131\163"
      if after_shown or keycap then
        shown_until, run = pos + #seq, after_shown and run + 1 or 1
        return nil
      end
    end
    if cp and not unseen(cp) then
      shown_until, run = pos + #seq, 0
      return nil
    end
    shown_until = 0
    if cp then return note(pos, ("<U+%04X>"):format(cp)) end
    return note(pos, (seq:gsub(".", function(byte) return ("<%02X>"):format(byte:byte()) end)))
  end)
  local line = at and select(2, text:sub(1, at):gsub("\n", "")) + 1 or nil
  return spelled, count, first, line
end

M.spell_out = spell_out

return M
