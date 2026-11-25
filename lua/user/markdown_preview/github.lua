-- What GitHub adds to the HTML of a Markdown file after its parser has run: an id on each heading, links into the
-- page that find a heading whatever their case, the box of a task inside its paragraph, alert boxes and emoji.
-- Each works on the tokens of html.lua.
local html = require "user.markdown_preview.html"

local M = {}

-- Whether GitHub keeps a character that is not ASCII in the name of a heading: letters, marks and digits stay,
-- punctuation, symbols and emoji go. Above U+00FF this is what `charclass()` tells; below it `charclass()`
-- follows 'iskeyword', so the Latin-1 letters are named here.
local function in_name(char)
  local code = vim.fn.char2nr(char, true)
  if code < 0x100 then
    return code >= 0xC0 and code ~= 0xD7 and code ~= 0xF7 or code == 0xAA or code == 0xB5 or code == 0xBA
  end
  local class = vim.fn.charclass(char)
  return class == 2 or class > 3
end

-- The name GitHub gives a heading with this text. It neither trims nor collapses: each space becomes a hyphen
-- of its own.
local function name_of(text)
  local kept = {}
  for char in vim.fn.tolower(text):gmatch "[%z\1-\127\194-\244][\128-\191]*" do
    if char:find "^[%w_ -]$" or (#char > 1 and in_name(char)) then kept[#kept + 1] = char end
  end
  return (table.concat(kept):gsub(" ", "-"))
end

-- Gives each heading its name as id, which is where GitHub's link to a heading leads. A second heading of one
-- name gets -1, the third -2. A heading with an id of its own keeps it, and its name counts all the same. A
-- heading ends at its end tag or, as in a browser, where the next heading starts; one that does neither has no
-- name.
local function headings(tokens)
  local seen = {}
  local heading, text -- the heading that is open, and the texts inside it
  for _, token in ipairs(tokens) do
    local starts = (token.tag or ""):find "^h[1-6]$"
    if heading and (starts or token.close == heading.tag) then
      local name = name_of(html.decode(table.concat(text)))
      seen[name] = (seen[name] or -1) + 1
      if seen[name] > 0 then name = name .. "-" .. seen[name] end
      if not heading.attrs.id and name ~= "" then heading.attrs.id = name end
      heading = nil
    end
    if starts then
      heading, text = token, {}
    elseif heading then
      text[#text + 1] = token.text
    end
  end
  return tokens
end

-- github.com scrolls to a heading for #Usage as it does for #usage; a browser alone does not. So a link into
-- the page that names no id and no name of it, but names an id once in lower case, is written in lower case.
local function links(tokens)
  local ids, names = {}, {}
  for _, token in ipairs(tokens) do
    local attrs = token.attrs or {}
    if attrs.id then ids[attrs.id] = true end
    if attrs.name then names[attrs.name] = true end
  end
  for _, token in ipairs(tokens) do
    local target = token.tag == "a" and (token.attrs.href or ""):match "^#(.*)"
    -- cmark-gfm writes an address percent-encoded (#%C3%9Cber-uns), and an id is not
    target = target and vim.uri_decode(target)
    -- (`tolower()` takes no NUL byte, and no id has one)
    local lower = target and not target:find "%z" and vim.fn.tolower(target)
    if lower and not ids[target] and not names[target] and ids[lower] then token.attrs.href = "#" .. lower end
  end
  return tokens
end

-- An item of a task list that has paragraphs: cmark-gfm writes the box, white space and then the first
-- paragraph, which draws the box on a line of its own. GitHub starts the paragraph before the box.
local function tasks(tokens)
  for index = 1, #tokens - 3 do
    local item, box, space, para = unpack(tokens, index, index + 3)
    local blank = space.text and space.text:find "^%s*$"
    if item.tag == "li" and box.tag == "input" and blank and para.tag == "p" then
      tokens[index + 1], tokens[index + 2], tokens[index + 3] = para, box, space
    end
  end
  return tokens
end

-- The five alerts: GitHub's title of each and the path of its icon, from GitHub's Octicons (MIT: their licence
-- is octicons.license, beside this file).
-- stylua: ignore
local ALERTS = {
  note = { title = "Note", path = "M0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8Zm8-6.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM6.5 7.75A.75.75 0 0 1 7.25 7h1a.75.75 0 0 1 .75.75v2.75h.25a.75.75 0 0 1 0 1.5h-2a.75.75 0 0 1 0-1.5h.25v-2h-.25a.75.75 0 0 1-.75-.75ZM8 6a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z" },
  tip = { title = "Tip", path = "M8 1.5c-2.363 0-4 1.69-4 3.75 0 .984.424 1.625.984 2.304l.214.253c.223.264.47.556.673.848.284.411.537.896.621 1.49a.75.75 0 0 1-1.484.211c-.04-.282-.163-.547-.37-.847a8.456 8.456 0 0 0-.542-.68c-.084-.1-.173-.205-.268-.32C3.201 7.75 2.5 6.766 2.5 5.25 2.5 2.31 4.863 0 8 0s5.5 2.31 5.5 5.25c0 1.516-.701 2.5-1.328 3.259-.095.115-.184.22-.268.319-.207.245-.383.453-.541.681-.208.3-.33.565-.37.847a.751.751 0 0 1-1.485-.212c.084-.593.337-1.078.621-1.489.203-.292.45-.584.673-.848.075-.088.147-.173.213-.253.561-.679.985-1.32.985-2.304 0-2.06-1.637-3.75-4-3.75ZM5.75 12h4.5a.75.75 0 0 1 0 1.5h-4.5a.75.75 0 0 1 0-1.5ZM6 15.25a.75.75 0 0 1 .75-.75h2.5a.75.75 0 0 1 0 1.5h-2.5a.75.75 0 0 1-.75-.75Z" },
  important = { title = "Important", path = "M0 1.75C0 .784.784 0 1.75 0h12.5C15.216 0 16 .784 16 1.75v9.5A1.75 1.75 0 0 1 14.25 13H8.06l-2.573 2.573A1.458 1.458 0 0 1 3 14.543V13H1.75A1.75 1.75 0 0 1 0 11.25Zm1.75-.25a.25.25 0 0 0-.25.25v9.5c0 .138.112.25.25.25h2a.75.75 0 0 1 .75.75v2.19l2.72-2.72a.749.749 0 0 1 .53-.22h6.5a.25.25 0 0 0 .25-.25v-9.5a.25.25 0 0 0-.25-.25Zm7 2.25v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 9a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z" },
  warning = { title = "Warning", path = "M6.457 1.047c.659-1.234 2.427-1.234 3.086 0l6.082 11.378A1.75 1.75 0 0 1 14.082 15H1.918a1.75 1.75 0 0 1-1.543-2.575Zm1.763.707a.25.25 0 0 0-.44 0L1.698 13.132a.25.25 0 0 0 .22.368h12.164a.25.25 0 0 0 .22-.368Zm.53 3.996v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 11a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z" },
  caution = { title = "Caution", path = "M4.47.22A.749.749 0 0 1 5 0h6c.199 0 .389.079.53.22l4.25 4.25c.141.14.22.331.22.53v6a.749.749 0 0 1-.22.53l-4.25 4.25A.749.749 0 0 1 11 16H5a.749.749 0 0 1-.53-.22L.22 11.53A.749.749 0 0 1 0 11V5c0-.199.079-.389.22-.53Zm.84 1.28L1.5 5.31v5.38l3.81 3.81h5.38l3.81-3.81V5.31L10.69 1.5ZM8 4a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 8 4Zm0 8a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z" },
}

-- The index of the end tag of each quote, by the index of its start tag. A quote that is never closed has none.
local function quote_ends(tokens)
  local ends, open = {}, {}
  for index, token in ipairs(tokens) do
    if token.tag == "blockquote" then
      open[#open + 1] = index
    elseif token.close == "blockquote" and open[1] then
      ends[table.remove(open)] = index
    end
  end
  return ends
end

-- Whether the quote that starts at `index` and ends at `last` is an alert: its kind, and what its first paragraph
-- says after the mark, or nil when the mark is all of it. cmark-gfm writes a quote as <blockquote>, a line
-- break, <p> and the text. The mark is alone on its line.
local function alert_at(tokens, index, last)
  local space, para, lead, after = unpack(tokens, index + 1, index + 4)
  -- (the quote ends after what it holds, so each of the four tokens is there when those before it are as said)
  if not (last and space.text == "\n" and para.tag == "p" and lead.text) then return end
  local kind, rest = lead.text:match "^%[!(%a+)%]\n(.*)$"
  if not kind and after.close == "p" then kind = lead.text:match "^%[!(%a+)%]$" end
  if kind and ALERTS[kind:lower()] then return kind:lower(), rest end
end

-- Turns a quote that starts with `[!NOTE]` and the like into GitHub's alert box. GitHub does so at the top
-- level only, not inside another quote or a list.
local function alerts(tokens)
  local out, ends, depth, index = {}, quote_ends(tokens), 0, 1
  while index <= #tokens do
    local token = tokens[index]
    local name = token.tag or token.close
    local last = ends[index]
    local kind, rest = alert_at(tokens, index, last)
    if kind and depth == 0 then
      vim.list_extend(out, {
        { tag = "div", attrs = { class = "markdown-alert markdown-alert-" .. kind } },
        { tag = "p", attrs = { class = "markdown-alert-title" } },
        { tag = "svg", attrs = { class = "octicon mr-2", viewBox = "0 0 16 16", width = "16", height = "16" } },
        { tag = "path", attrs = { d = ALERTS[kind].path } },
        { close = "path" },
        { close = "svg" },
        { text = ALERTS[kind].title },
        { close = "p" },
      })
      if rest then tokens[index + 3].text = rest end
      -- a paragraph that held the mark alone is left out
      vim.list_extend(out, tokens, rest and index + 2 or index + 5, last - 1)
      out[#out + 1] = { close = "div" }
      index = last
    else
      if name == "blockquote" or name == "li" then depth = math.max(0, depth + (token.tag and 1 or -1)) end
      out[#out + 1] = token
    end
    index = index + 1
  end
  return out
end

-- The emoji GitHub knows by name: what its `GET /emojis` listed on 2026-11-25, without the 23 names that are
-- pictures of GitHub's own (:octocat:), each as the characters Unicode's list of emoji gives for it.
local EMOJI = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/emoji.json"
local CODE = { code = true, pre = true, tt = true, kbd = true }

-- Writes the emoji for `:name:` in text that is not code. A name GitHub does not know stays as it is.
local function emoji(tokens)
  local names = vim.json.decode(table.concat(vim.fn.readfile(EMOJI)))
  local code = 0
  for _, token in ipairs(tokens) do
    if CODE[token.tag or token.close] then
      code = math.max(0, code + (token.tag and 1 or -1))
    elseif token.text and code == 0 then
      token.text = token.text:gsub(":([%w_+-]+):", names)
    end
  end
  return tokens
end

--- Changes the tokens of cmark-gfm's HTML into those of the HTML GitHub shows. The tokens given are changed too.
---@param tokens table[] tokens of html.lua
---@return table[]
function M.apply(tokens)
  -- `emoji` after `headings`: the name of a heading is made from the name of an emoji, not from the emoji
  return emoji(alerts(tasks(links(headings(tokens)))))
end

return M
