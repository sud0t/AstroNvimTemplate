-- HTML as a list of tokens. `parse` reads HTML that nobody vouches for and keeps only the tags, attributes and
-- addresses listed here. `write` is the only code that writes the markup of the document (page.lua writes the
-- head around it): it escapes every text and every attribute value, and refuses a tag or an attribute that is
-- not listed, for a document or for this configuration's own code. The document of a page therefore holds no
-- tag that was not a token, and no name from elsewhere. `write` answers for names and for escaping only: the
-- addresses, the one class and the kind of <input> are `parse`'s, so code that puts an address into a token
-- answers for it itself (github.lua and page.lua write only `#...` and the page's own address).
--
-- A token is one of
--   { text = "a &amp; b" }                  text, encoded as HTML
--   { tag = "a", attrs = { href = "x" } }   a start tag; the values are plain text
--   { close = "a" }                         an end tag
local M = {}

local function set(words)
  local found = {}
  for word in words:gmatch "%S+" do
    found[word] = true
  end
  return found
end

-- The elements GitHub keeps. None of them changes how a browser reads the text that follows it (as <script>,
-- <style>, <textarea>, <svg> and the like do), so the browser sees the tokens `write` wrote and nothing else.
local TAGS = set [[a abbr b bdo blockquote br caption cite code dd del details dfn div dl dt em figcaption figure
  h1 h2 h3 h4 h5 h6 hr i img input ins kbd li mark ol p picture pre q rp rt ruby s samp section span strike strong
  sub summary sup table tbody td tfoot th thead time tr tt ul var wbr]]
local VOID = set "br hr img input wbr"
-- Of the attributes GitHub keeps, those that change what is drawn or where a link leads.
local ATTRS = set [[align alt border cellpadding cellspacing checked class clear colspan dir disabled height href
  id lang name open rowspan span src start title type valign width data-footnote-ref data-footnotes]]

-- The names of the icon that github.lua draws in an alert. `write` takes them besides those above and `parse`
-- does not, so no document brings an <svg> of its own. Code that opens an <svg> has to close it: a browser reads
-- what is inside one by other rules.
local OWN_TAGS = set "svg path"
local OWN_ATTRS = set "viewBox d"

-- Where an address may lead: the schemes it may have. An address without a scheme leads to a file of this
-- machine. A file named .desktop is refused, since Firefox reads one as a link to the address written in it; a
-- symbolic link to one under another name is not seen here, so for a picture the policy (page.lua) is the only
-- guard then. A picture is a file of this machine and nothing else, so no page asks another machine for
-- anything. To allow remote pictures, give `src` the schemes http and https here, and name them in `img-src` of
-- the policy in page.lua. `srcset` and <source> are not listed above: Firefox asks for the pictures of a
-- `srcset` whatever the policy says, so nothing but this file would guard them, and a <picture> shows its <img>
-- without them.
local ADDRESSES = { href = set "http https mailto", src = set "" }

local NAMED = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }

--- The text that HTML-encoded `text` stands for. Only the references cmark-gfm writes and numeric ones are read:
--- any other stays as it is written.
---@param text string
---@return string
function M.decode(text)
  return (
    text:gsub("&(#?)([%w]+);", function(numeric, name)
      if numeric == "" then return NAMED[name] end
      local code = name:match "^[xX](%x+)$" and tonumber(name:sub(2), 16) or tonumber(name:match "^%d+$")
      if code and code > 0 and code < 0x110000 then return vim.fn.nr2char(code, true) end
    end)
  )
end

--- `text` encoded for HTML, as text and as an attribute value in double quotes.
---@param text string
---@return string
function M.encode(text)
  return (text:gsub('[&<>"]', { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }))
end

-- The address a browser makes of an attribute's value, or nil when it has a scheme that is not among `schemes`
-- (of ADDRESSES), or has none and names a .desktop file. A browser drops the spaces and control characters
-- around an address and the tabs and line breaks inside it before it looks for the scheme, so they are dropped
-- here first: `java\tscript:` must not pass as a relative address. It also reads a backslash as a slash.
local function address(value, schemes)
  -- (the last character that stays is found from the end: a pattern that ends in `+$` tries every run of
  -- spaces, and takes half a minute for 100,000 of them)
  local first = value:find "[^%z\1-\32]"
  local url = first and value:match("^.*[^%z\1-\32]", first):gsub("[\t\n\r]", "") or ""
  -- An address that starts with a host (//host/x) takes the scheme of its page: https on github.com, but
  -- `file` here. It is written as github.com reads it.
  if url:find "^[/\\][/\\]" then url = "https://" .. url:sub(3) end
  local scheme = url:match "^(%a[%w+.-]*):"
  if scheme and not schemes[scheme:lower()] then return nil end
  -- (any part of the path, which is what stands before ? or #, may end in .desktop: Firefox follows
  -- `v.desktop/` and `v.desktop/x/..` to the file as well)
  if not scheme and (vim.uri_decode(url:match "^[^?#]*"):lower() .. "/"):find "%.desktop[/\\]" then return nil end
  return url
end

local SPACE = "[ \t\n\f\r]"

-- Reads the attributes of a start tag from `pos` on, as a browser does. Returns them and the position after the
-- tag's `>`, or nil when the text ends inside the tag.
local function attributes(html, pos)
  local attrs = {}
  while true do
    pos = html:match("^[ \t\n\f\r/]*()", pos)
    local char = html:sub(pos, pos)
    if char == "" then return nil end
    if char == ">" then return attrs, pos + 1 end
    local name, after = html:match("^(=?[^ \t\n\f\r/>=]*)()", pos)
    local value = ""
    pos = html:match("^" .. SPACE .. "*()", after)
    if html:sub(pos, pos) == "=" then
      pos = html:match("^" .. SPACE .. "*()", pos + 1)
      local quote = html:sub(pos, pos)
      if quote == '"' or quote == "'" then
        local last = html:find(quote, pos + 1, true)
        if not last then return nil end
        value, pos = html:sub(pos + 1, last - 1), last + 1
      else
        value, pos = html:match("^([^ \t\n\f\r>]*)()", pos)
      end
    end
    name = name:lower()
    -- the first of two attributes of one name counts, as in a browser
    if attrs[name] == nil then attrs[name] = M.decode(value) end
  end
end

-- What of a start tag's attributes is allowed, or nil when the tag itself is not.
local function allowed(tag, attrs)
  local kept = {}
  for name, value in pairs(attrs) do
    if ADDRESSES[name] then value = address(value, ADDRESSES[name]) end
    if ATTRS[name] and value then kept[name] = value end
  end
  -- cmark-gfm marks the list of footnotes with this class. Every other class goes: the document's own, and
  -- cmark-gfm's `footnote-ref` and `footnote-backref`, by which the stylesheet draws nothing.
  if kept.class ~= "footnotes" then kept.class = nil end
  -- the only <input> GitHub shows is the box of a task list
  if tag == "input" and kept.type ~= "checkbox" then return nil end
  return kept
end

--- The tokens of `html` that are allowed. A tag that is not allowed is left out and what is inside it stays;
--- comments are left out; text that ends inside a tag or a comment is left out from there on.
---@param html string
---@return table[] tokens
function M.parse(html)
  local tokens, pos = {}, 1
  local function add(token) tokens[#tokens + 1] = token end
  while pos <= #html do
    local open = html:find("<", pos, true) or #html + 1
    if open > pos then add { text = html:sub(pos, open - 1) } end
    if open > #html then break end
    local closing, name, after = html:match("^<(/?)(%a[^ \t\n\f\r/>]*)()", open)
    if name then
      name = name:lower()
      local attrs, next_pos = attributes(html, after)
      if not attrs then break end
      pos = next_pos
      if TAGS[name] and closing == "/" then
        if not VOID[name] then add { close = name } end
      elseif TAGS[name] then
        local kept = allowed(name, attrs)
        if kept then add { tag = name, attrs = kept } end
      end
    elseif html:find("^<!%-%-", open) then
      local _, last = html:find("-->", open + 2, true)
      pos = (last or #html) + 1
    elseif html:find("^<[!?/]", open) then
      pos = (html:find(">", open, true) or #html) + 1
    else
      add { text = "&lt;" }
      pos = open + 1
    end
  end
  return tokens
end

-- `name` when it is listed, for a document or for this configuration's own code. Any other name in a token is
-- a mistake of the code that made the token: the page is not written.
local function listed(names, own, name, kind)
  if names[name] or own[name] then return name end
  error(("html.write: the %s %q is not listed in html.lua"):format(kind, tostring(name)))
end

--- The HTML of `tokens`. Attributes are written in the order of their names. A tag or an attribute that is not
--- listed above is an error.
---@param tokens table[]
---@return string
function M.write(tokens)
  local out = {}
  for _, token in ipairs(tokens) do
    if token.text then
      -- text keeps its character references: only what could open or close a tag is encoded
      out[#out + 1] = token.text:gsub("[<>]", { ["<"] = "&lt;", [">"] = "&gt;" })
    elseif token.close then
      out[#out + 1] = "</" .. listed(TAGS, OWN_TAGS, token.close, "tag") .. ">"
    else
      local names = vim.tbl_keys(token.attrs)
      table.sort(names)
      out[#out + 1] = "<" .. listed(TAGS, OWN_TAGS, token.tag, "tag")
      for _, name in ipairs(names) do
        out[#out + 1] = (' %s="%s"'):format(listed(ATTRS, OWN_ATTRS, name, "attribute"), M.encode(token.attrs[name]))
      end
      out[#out + 1] = ">"
    end
  end
  return table.concat(out)
end

return M
