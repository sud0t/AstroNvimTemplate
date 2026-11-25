-- <Leader>gm in a Markdown buffer (plugins/markdown.lua): the buffer as github.com would show it, as a page of
-- its own in the browser. Nothing of the text leaves this machine: cmark-gfm, the public release of GitHub's
-- parser, reads it here, github.lua adds what github.com adds to that parser's HTML, and the treesitter of a
-- Neovim started for it colours the code (code.lua).
local code = require "user.markdown_preview.code"
local github = require "user.markdown_preview.github"
local html = require "user.markdown_preview.html"
local page = require "user.markdown_preview.page"

local M = {}

-- GitHub's extensions; --unsafe keeps the HTML a file has in it (logos, badges, <details>), which html.lua then
-- reduces to what GitHub allows.
local CMARK = { "cmark-gfm", "--unsafe", "--github-pre-lang" }
for _, extension in ipairs { "footnotes", "table", "strikethrough", "autolink", "tagfilter", "tasklist" } do
  vim.list_extend(CMARK, { "-e", extension })
end
local SECONDS = 10
local TITLE = "Markdown preview"

--- What the program `cmd` writes when it is given `input`, or nil and why there is none: it is not installed,
--- does not finish within SECONDS, is ended by a signal or exits with an error. cmark-gfm and the Neovim that
--- colours the code (code.lua) are run by it.
---@param cmd string[]
---@param input string
---@return string? output
---@return string? problem
local function output_of(cmd, input)
  local name = vim.fs.basename(cmd[1])
  if vim.fn.executable(cmd[1]) == 0 then return nil, name .. " is not installed" end
  local result = vim.system(cmd, { stdin = input }):wait(SECONDS * 1000)
  -- (how `wait` reports a process that it ended itself)
  if result.code == 124 and result.signal == 9 then
    return nil, ("%s did not finish within %d s"):format(name, SECONDS)
  end
  if result.code ~= 0 or result.signal ~= 0 then
    local said = vim.trim(result.stderr or "")
    local ended = ("%s ended with code %d and signal %d"):format(name, result.code, result.signal)
    return nil, said ~= "" and said or ended
  end
  return result.stdout
end

-- The tokens (html.lua) of the HTML GitHub shows for a Markdown text, or nil and why there are none.
local function tokens_of(markdown)
  local written, problem = output_of(CMARK, markdown)
  if not written then return nil, problem end
  local tokens, uncoloured = code.colour(github.apply(html.parse(written)), output_of)
  if uncoloured then vim.notify(uncoloured, vim.log.levels.WARN, { title = TITLE }) end
  return tokens
end

--- The HTML GitHub shows for a Markdown text, without a page around it. An error when cmark-gfm gives none.
---@param markdown string
---@return string
function M.render(markdown) return html.write(assert(tokens_of(markdown))) end

--- Opens a page that shows buffer `buf` as it is now, unsaved changes included, in the browser. Every call makes
--- a new page, in Neovim's own temporary directory, which is gone when Neovim exits.
---@param buf integer
function M.open(buf)
  local function fail(problem) vim.notify(problem, vim.log.levels.ERROR, { title = TITLE }) end
  local tokens, problem = tokens_of(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
  if not tokens then return fail(problem) end

  local name = vim.api.nvim_buf_get_name(buf)
  local path = vim.fn.tempname() .. ".html"
  local text = page.build {
    title = name ~= "" and vim.fs.basename(name) or "Markdown",
    tokens = tokens,
    uri = vim.uri_from_fname(path),
    dir = name ~= "" and vim.fs.dirname(name) or nil,
  }
  vim.fn.writefile(vim.split(text, "\n"), path)
  local _, err = vim.ui.open(path)
  if err then fail(("%s\nThe page is %s"):format(err, path)) end
end

return M
