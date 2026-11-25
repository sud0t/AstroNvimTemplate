-- Colours code blocks as GitHub does: Neovim's treesitter finds what each piece of the code is, and the tables
-- here name the class of GitHub's stylesheet (`pl-*`) that draws such a piece. The treesitter is that of a
-- Neovim started for the document (colour.lua, beside this file), since nothing inside a Neovim can stop a
-- parser: one may take minutes for a few thousand bytes, and a fault in one ends the Neovim it runs in. `colour`
-- asks that Neovim, and `draw` is what it runs.
local html = require "user.markdown_preview.html"

local M = {}

-- What a fence may call a language whose parser has another name.
local PARSERS = {
  console = "bash",
  js = "javascript",
  md = "markdown",
  py = "python",
  rs = "rust",
  sh = "bash",
  shell = "bash",
  ts = "typescript",
  viml = "vim",
  yml = "yaml",
  zsh = "bash",
}

-- The class of a capture and of the captures below it (`string` is also for `string.documentation`); false is
-- for what GitHub leaves in the colour of the text.
local CLASSES = {
  attribute = "pl-e",
  boolean = "pl-c1",
  character = "pl-s",
  comment = "pl-c",
  constant = "pl-c1",
  constructor = "pl-en",
  ["function"] = "pl-en",
  ["function.builtin"] = "pl-c1",
  keyword = "pl-k",
  label = "pl-en",
  ["markup.heading"] = "pl-mh",
  ["markup.italic"] = "pl-mi",
  ["markup.link.url"] = "pl-corl",
  ["markup.list"] = "pl-ml",
  ["markup.raw"] = "pl-c1",
  ["markup.strong"] = "pl-mb",
  number = "pl-c1",
  operator = "pl-k",
  property = "pl-ent",
  string = "pl-s",
  ["string.escape"] = "pl-cce",
  ["string.regexp"] = "pl-sr",
  ["string.special.url"] = "pl-corl",
  tag = "pl-ent",
  ["tag.attribute"] = "pl-e",
  ["tag.delimiter"] = false,
  type = "pl-en",
  ["type.builtin"] = "pl-c1",
  variable = "pl-smi",
  ["variable.builtin"] = "pl-c1",
}
-- Where GitHub's grammar of a language colours a capture in another way than most do.
local CLASSES_OF = {
  bash = {
    constant = false,
    ["function.call"] = false,
    ["keyword.directive"] = "pl-c",
    number = false,
    operator = false,
    variable = false,
  },
  lua = { constructor = false, ["function.call"] = "pl-c1", property = false, ["variable.member"] = "pl-e" },
}

-- The value `classes` has for a capture or, without one, for the nearest capture above it.
local function inherited(classes, capture)
  while capture do
    if classes[capture] ~= nil then return classes[capture] end
    capture = capture:match "^(.*)%.[^.]*$"
  end
end

local function class_of(language, capture)
  local class = inherited(CLASSES_OF[language] or {}, capture)
  if class == nil then class = inherited(CLASSES, capture) end
  return class
end

-- The class of every byte of `code`, or nil when there is no parser for the language. An error when treesitter
-- gives one. A later capture replaces an earlier one, and a language inside another (a script in HTML) replaces
-- its host, which is the order Neovim highlights a buffer in.
local function classes(code, language)
  -- (`add` refuses a name that is not made of letters, digits and _: the name is the document's, and it is
  -- the name of a library to load)
  if not vim.treesitter.language.add(language) then return nil end
  local parser = vim.treesitter.get_string_parser(code, language)
  parser:parse(true)
  local class_at = {}
  parser:for_each_tree(function(tree, part)
    local query = vim.treesitter.query.get(part:lang(), "highlights")
    if not query then return end
    for id, node in query:iter_captures(tree:root(), code) do
      local capture = query.captures[id]
      if not capture:find "^_" and capture ~= "spell" and capture ~= "nospell" and capture ~= "conceal" then
        local class = class_of(part:lang(), capture)
        local _, _, first, _, _, last = node:range(true)
        for byte = first + 1, last do
          class_at[byte] = class
        end
      end
    end
  end)
  return class_at
end

-- The tokens that draw `code`: a span around each run of bytes of one class.
local function spans(code, class_at)
  local tokens, first = {}, 1
  for byte = 2, #code + 1 do
    if byte > #code or (class_at[byte] or false) ~= (class_at[first] or false) then
      local text = { text = html.encode(code:sub(first, byte - 1)) }
      if class_at[first] then
        vim.list_extend(tokens, { { tag = "span", attrs = { class = class_at[first] } }, text, { close = "span" } })
      else
        tokens[#tokens + 1] = text
      end
      first = byte
    end
  end
  return tokens
end

---@class user.markdown_preview.Block
---@field at integer the index of the block's text among the tokens
---@field language string the parser its fence names
---@field code string

-- The blocks of code among `tokens`. cmark-gfm writes one as `<pre lang="x"><code>`, the code as one text,
-- `</code></pre>`; a block of any other shape is none.
---@return user.markdown_preview.Block[]
local function blocks_among(tokens)
  local found = {}
  for index, pre in ipairs(tokens) do
    local code, text, last = tokens[index + 1], tokens[index + 2], tokens[index + 3]
    local name = pre.tag == "pre" and pre.attrs.lang and pre.attrs.lang:lower()
    if name and code and code.tag == "code" and text and text.text and last and last.close == "code" then
      local source = html.decode(text.text)
      -- The text is written anew from the code, so only a text that comes back as it was is a block. What
      -- cmark-gfm writes for a fence does; one written as HTML in another way (`&copy;`, a bare quote) does not.
      if html.encode(source) == text.text then
        found[#found + 1] = { at = index + 2, language = PARSERS[name] or name, code = source }
      end
    end
  end
  return found
end

--- What draws each of `blocks`, by the parsers and queries of this Neovim. An error of treesitter's costs the
--- colours of the block and not the others: a query that does not fit its parser, as after an update of some
--- parsers only, raises one.
---@param blocks user.markdown_preview.Block[]
---@return { tokens: table[]|false, problem: string? }[] drawn for each block the tokens in place of its text,
--- or false when it stays as it is: its language has no parser, or treesitter gave the error `problem`
function M.draw(blocks)
  return vim.tbl_map(function(block)
    local parsed, class_at = pcall(classes, block.code, block.language)
    if not parsed then return { tokens = false, problem = tostring(class_at) } end
    return { tokens = class_at and spans(block.code, class_at) or false }
  end, blocks)
end

local SCRIPT = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/colour.lua"

--- Colours the code blocks among `tokens` whose language has a parser here, in a Neovim of its own: only the
--- blocks go to it, and tokens that hold no block start none. When that Neovim gives no answer, no block is
--- coloured.
---@param tokens table[]
---@param run fun(cmd: string[], input: string): string?, string? what a program writes for an input, or nil
--- and why there is none
---@return table[] tokens
---@return string? problem why code is left uncoloured: what `run` said, or the languages whose blocks an error
--- of treesitter's cost their colours, each with the error
function M.colour(tokens, run)
  local found = blocks_among(tokens)
  if not found[1] then return tokens end
  -- (a Neovim that is ended leaves its socket behind: this one's is in the temporary directory, which goes
  -- when the Neovim that asks exits)
  local neovim = { vim.v.progpath, "--clean", "--headless", "-i", "NONE", "--listen", vim.fn.tempname(), "-l", SCRIPT }
  local written, why = run(neovim, vim.json.encode { runtimepath = vim.o.runtimepath, blocks = found })
  if not written then return tokens, "No colours for code: " .. why end

  local drawn, in_place_of, problems = vim.json.decode(written), {}, {}
  for n, block in ipairs(found) do
    in_place_of[block.at] = drawn[n].tokens or nil
    if drawn[n].problem then
      local problem = ("No colours for %s code: %s"):format(block.language, drawn[n].problem)
      if not vim.list_contains(problems, problem) then problems[#problems + 1] = problem end
    end
  end
  local out = {}
  for index, token in ipairs(tokens) do
    vim.list_extend(out, in_place_of[index] or { token })
  end
  return out, problems[1] and table.concat(problems, "\n")
end

return M
