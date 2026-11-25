-- The page a rendering is shown in: GitHub's stylesheet in its dark theme around the HTML, and a policy that lets
-- the browser run no script and load nothing but pictures that are files of this machine.
local html = require "user.markdown_preview.html"

local M = {}

-- github-markdown-css 5.9.0, a copy of what github.com styles Markdown with (MIT: its licence is beside it).
local STYLESHEET = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/github-markdown-dark.css"
-- What github.com adds around it: the width of the column, and that an image marked for the light theme is
-- not shown in the dark one. What its own page has and the copy lacks, as measured on github.com in its dark
-- theme on 2026-11-25: `box-sizing` for every element (by a selector that outweighs none of the copy's),
-- underlined links, the height of a rule, and of a code block the square corners, the tab width and the margin
-- at the end of an alert. Then what the copy lacks here. It uses three colours without defining them (the
-- border of <kbd> is one): they get the values that github-markdown.css of the same release has for dark. And
-- it draws a task list by classes that cmark-gfm does not write: what it declares for .task-list-item and
-- .task-list-item-checkbox is given to an item that begins with a box, alone or in its first paragraph
-- (github.lua), and to the box. Every <input> of a page is such a box (html.lua).
local SITE = [[
body { min-width: 200px; max-width: 980px; margin: 0 auto; padding: 45px; }
.markdown-body [src$="#gh-light-mode-only"], .markdown-body [href$="#gh-light-mode-only"] { display: none; }
* { box-sizing: border-box; }
.markdown-body a { text-decoration: underline; text-underline-offset: .2rem; }
.markdown-body hr { height: 1px; }
.markdown-body pre { border-radius: 0; }
.markdown-body pre, .markdown-body code { tab-size: 4; }
.markdown-body .markdown-alert > pre:last-child { margin-bottom: 16px; }
.markdown-body { --borderColor-muted: #3d444db3; --borderColor-accent-emphasis: #1f6feb; --fgColor-danger: #f85149; }
.markdown-body li:has(> input:first-child, > p:first-child > input:first-child) {
  list-style-type: none;
  & + & { margin-top: 0.25rem; }
  & > input:first-child, & > p:first-child > input:first-child { margin: 0 .2em .25em -1.4em; vertical-align: middle; }
}
]]

-- The policy names the one stylesheet by its hash, so a style that got into the HTML against html.lua is not
-- applied either. It allows no script, frame, font or form, no picture but a file, and no <base> but one that
-- names a file, as the page's own does: a second guard behind html.lua (ADDRESSES). It would be none for a
-- `srcset`, whose pictures Firefox (160) asks another machine for although the policy forbids them, so html.lua
-- keeps no `srcset`.
local function policy(style)
  local digest = vim.fn.sha256(style):gsub("%x%x", function(byte) return string.char(tonumber(byte, 16)) end)
  return ("default-src 'none'; img-src file:; style-src 'sha256-%s'; base-uri file:; form-action 'none'"):format(
    vim.base64.encode(digest)
  )
end

---@class user.markdown_preview.Page
---@field title string
---@field tokens table[] the tokens of the file's HTML (html.lua)
---@field uri string the address the page will have
---@field dir? string the directory of the file: relative addresses of images and links are read from it

--- The text of the page that shows a Markdown file. The tokens given are changed: with a `dir`, their links
--- into the page name the page.
---@param page user.markdown_preview.Page
---@return string
function M.build(page)
  local style = table.concat(vim.fn.readfile(STYLESHEET), "\n") .. "\n" .. SITE
  local base = ""
  if page.dir then
    base = ('<base href="%s/">'):format(html.encode(vim.uri_from_fname(page.dir)))
    -- <base> makes every relative address one of the file's directory, a bare #name among them: a link to a
    -- place in the page has to name the page
    for _, token in ipairs(page.tokens) do
      if token.tag == "a" and (token.attrs.href or ""):sub(1, 1) == "#" then
        token.attrs.href = page.uri .. token.attrs.href
      end
    end
  end
  return table.concat({
    "<!DOCTYPE html>",
    '<html lang="en"><head><meta charset="utf-8">',
    ('<meta http-equiv="Content-Security-Policy" content="%s">'):format(policy(style)),
    base,
    ("<title>%s</title>"):format(html.encode(page.title)),
    "<style>" .. style .. "</style>",
    '</head><body class="markdown-body">',
    html.write(page.tokens),
    "</body></html>",
  }, "\n")
end

return M
