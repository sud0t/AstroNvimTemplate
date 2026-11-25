-- The Markdown preview inside the whole configuration (lua/user/markdown_preview/, lua/plugins/markdown.lua).
--   tests/run.sh markdown_preview
-- prints "ok: N checks", or what failed and exits with 1. It needs the cmark-gfm program and the treesitter
-- parsers of lua, python, bash, json and markdown (with markdown_inline). Run it after changing those files,
-- after an update of cmark-gfm (the pages are made of the HTML it writes) and after an update of those parsers
-- or their queries (the colours of code are theirs).
-- No browser is started here. That a browser takes the stylesheet's hash for the right one, draws a picture
-- that is a file and asks no other machine for one, and draws an alert, a task list and a key as github.com
-- does, needs a check by hand, in a browser.

local harness = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/harness.lua")
harness.whole_config()
local ok = harness.ok

local github = require "user.markdown_preview.github"
local html = require "user.markdown_preview.html"
local page = require "user.markdown_preview.page"
local preview = require "user.markdown_preview"

local function press(keys) vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false) end
local function read(path) return table.concat(vim.fn.readfile(path), "\n") end

-- Hostile HTML and, written out by hand, what must be left of it. The rules: a tag that is not listed is gone
-- and what is inside it stays; an attribute that is not listed is gone, and so is an address that is refused;
-- the attributes that stay are in the order of their names, in double quotes, with & < > " encoded; a < that
-- opens no tag and a > in text are encoded; a comment or a declaration is gone; what follows a tag, a quote or
-- a comment that is not closed is gone. An expected text is never made by the code under test.
local SANITISED = {
  -- scripts and event handlers
  { [[<script>alert(1)</script>]], "alert(1)" },
  { [[<img/onerror=alert(1)/src=a.png>]], "<img>" },
  { [[<img src="a.png"onload="alert(1)">]], [[<img src="a.png">]] },
  { [[<p onclick="alert(1)" onmouseover=alert(2)>x</p>]], "<p>x</p>" },
  { [[<details open ontoggle="alert(1)">x</details>]], [[<details open="">x</details>]] },
  { [[<body onload="alert(1)">hi</body>]], "hi" },
  -- javascript: in a link, in the spellings a browser reads as that scheme
  { [[<a href="javascript:alert(1)">x</a>]], "<a>x</a>" },
  { [[<a href="&#x6A;avascript:alert(1)">x</a>]], "<a>x</a>" },
  { [[<a href="&#106;avascript:alert(1)">x</a>]], "<a>x</a>" },
  { [[<a href="jav&#x0A;ascript:alert(1)">x</a>]], "<a>x</a>" },
  { [[<a href="&#31;javascript:alert(1)">x</a>]], "<a>x</a>" },
  { [[<a href="jav&#13;ascript:alert(1)">x</a>]], "<a>x</a>" },
  { [[<a href="javascript:alert(1)" href="ok.html">x</a>]], "<a>x</a>" },
  -- references that html.lua does not read stay text: their & is encoded, so the browser does not read them
  -- either, and the address is a relative one
  { [[<a href="javascript&colon;alert(1)">x</a>]], [[<a href="javascript&amp;colon;alert(1)">x</a>]] },
  { [[<a href="&#x6a&#x61vascript:alert(1)">x</a>]], [[<a href="&amp;#x6a&amp;#x61vascript:alert(1)">x</a>]] },
  -- other schemes in a link
  { [[<a href="vbscript:msgbox(1)">x</a>]], "<a>x</a>" },
  { [[<a href="data:text/html,<script>alert(1)</script>">x</a>]], "<a>x</a>" },
  { [[<a href="file:///etc/passwd">x</a>]], "<a>x</a>" },
  { [[<a href="ftp://example.com/x">x</a>]], "<a>x</a>" },
  { [[<a href="x-custom+scheme.1:y">x</a>]], "<a>x</a>" },
  -- styles
  { [[<style>body{background:red}</style>]], "body{background:red}" },
  { [[<p style="color:red">x</p>]], "<p>x</p>" },
  { [[<link rel="stylesheet" href="http://evil.example/x.css">]], "" },
  -- forms
  {
    [[<form action="http://evil.example/"><input type="text" name="q"><button type="submit">go</button></form>]],
    "go",
  },
  { [[<textarea><b>x</b></textarea>]], "<b>x</b>" },
  { [[<select><option>a</option></select>]], "a" },
  { [[<input>]], "" },
  { [[<input type="CHECKBOX">]], "" },
  { [[<input type="checkbox" formaction="javascript:alert(1)" onclick="alert(1)">]], [[<input type="checkbox">]] },
  -- what sends the page elsewhere
  { [[<meta http-equiv="refresh" content="0;url=http://evil.example/">]], "" },
  { [[<base href="http://evil.example/">]], "" },
  -- frames and plugins
  { [[<iframe src="http://evil.example/"></iframe>]], "" },
  { [[<object data="x.swf"><param name="a" value="b"></object>]], "" },
  { [[<embed src="x.swf">]], "" },
  {
    [[<video src="http://evil.example/x.mp4" poster="http://evil.example/p.png"></video><audio src="//x.example/a"></audio>]],
    "",
  },
  -- svg and math
  { [[<svg onload="alert(1)"><circle r="1"/></svg>]], "" },
  { [[<svg><a href="javascript:alert(1)"><text>x</text></a></svg>]], "<a>x</a>" },
  { [[<math><mi xlink:href="javascript:alert(1)">x</mi></math>]], "x" },
  -- the names of an alert's icon are this configuration's own: a document's are gone like any other
  { [[<SVG><PATH D="M0 0"/></SVG><p d="M0 0" viewBox="0 0 1 1" viewbox="0 0 1 1">x</p>]], "<p>x</p>" },
  -- elements that change how a browser reads what follows
  { [[<plaintext><b>x</b>]], "<b>x</b>" },
  { [[<xmp><img src=x onerror=alert(1)></xmp>]], [[<img src="x">]] },
  {
    [[<noscript><p title="</noscript><img src=x onerror=alert(1)>">]],
    [[<p title="&lt;/noscript&gt;&lt;img src=x onerror=alert(1)&gt;">]],
  },
  { [[<title><img src=x onerror=alert(1)></title>]], [[<img src="x">]] },
  { [[<template><script>alert(1)</script></template>]], "alert(1)" },
  -- comments
  { [[a<!-- x --!><script>alert(1)</script> -->b]], "ab" },
  { [[a<!--><script>alert(1)</script>-->b]], "aalert(1)--&gt;b" },
  { [[a<!-- never closed <b>x</b>]], "a" },
  { [[a<!- x -><b>y</b>]], "a<b>y</b>" },
  -- CDATA, processing instructions and declarations: a browser ends each at the first >
  { "<![CDATA[<script>alert(1)</script>]]>", "alert(1)]]&gt;" },
  { [[<?xml version="1.0"?><b>x</b>]], "<b>x</b>" },
  { [[</ script><b>x</b>]], "<b>x</b>" },
  -- a tag and a quote that are not closed, and a < that opens no tag
  { [[x<img src="a.png]], "x" },
  { [[x<b]], "x" },
  { [[1 < 2 > 1 <3 <-]], "1 &lt; 2 &gt; 1 &lt;3 &lt;-" },
  -- attributes
  { [[<a href='x" onclick="alert(1)'>y</a>]], [[<a href="x&quot; onclick=&quot;alert(1)">y</a>]] },
  { [[<IMG SRC="a.png" ALT="x" ONERROR="alert(1)">]], [[<img alt="x" src="a.png">]] },
  {
    [[<p class="evil" id="p1" data-x="1" aria-label="l" role="button" tabindex="0" contenteditable>x</p>]],
    [[<p id="p1">x</p>]],
  },
  { [[<p class="footnotes x">x</p>]], "<p>x</p>" },
  {
    [[<a href="ok.html" ping="http://evil.example/p" target="_blank" rel="opener">x</a>]],
    [[<a href="ok.html">x</a>]],
  },
  {
    [[<table background="http://evil.example/x.png"><tr><td background="//evil.example/y.png">x</td></tr></table>]],
    "<table><tr><td>x</td></tr></table>",
  },
  { [[<blockquote cite="http://evil.example/">x</blockquote>]], "<blockquote>x</blockquote>" },
  { [[a</br>b</img>c]], "abc" },
  -- a NUL byte
  { '<a href="\0javascript:alert(1)">x</a>', "<a>x</a>" },
  -- pictures of another machine, and other addresses that are no file's
  { [[<img src="https://evil.example/x.png" alt="badge">]], [[<img alt="badge">]] },
  { [[<img src="http://evil.example/x.png">]], "<img>" },
  { [[<img src="//evil.example/x.png">]], "<img>" },
  { [[<img src="\\evil.example\x.png">]], "<img>" },
  { [[<img src="data:image/png;base64,AAAA">]], "<img>" },
  { [[<img src="file:///etc/passwd">]], "<img>" },
  { [[<img src="javascript:alert(1)">]], "<img>" },
  {
    [[<img src="a.png" lowsrc="http://evil.example/x.png" longdesc="http://evil.example/" usemap="#m">]],
    [[<img src="a.png">]],
  },
  -- an address that starts with a host has the scheme of its page: https on github.com, and so it is written.
  -- A link keeps it; a picture does not, as the lines above show
  { '<a href=" /\t\\host\\x ">x</a>', [[<a href="https://host\x">x</a>]] },
  -- a .desktop file is no address, however it is spelled: Firefox reads one as a link to what is written in it
  { [[<img src="logo.desktop"><a href="logo.desktop">x</a>]], "<img><a>x</a>" },
  { [[<img src="LOGO.DESKTOP"><a href="LOGO.DESKTOP">x</a>]], "<img><a>x</a>" },
  { [[<img src="logo%2Edesktop"><a href="logo%2Edesktop">x</a>]], "<img><a>x</a>" },
  { [[<img src="logo.desktop?x"><a href="logo.desktop?x">x</a>]], "<img><a>x</a>" },
  { [[<img src="logo.desktop#y"><a href="logo.desktop#y">x</a>]], "<img><a>x</a>" },
  { [[<img src="dir/x.desktop"><a href="dir/x.desktop">x</a>]], "<img><a>x</a>" },
  { [[<img src="a.desktop "><a href="x.desktop/y.png">x</a>]], "<img><a>x</a>" },
  -- (spellings Firefox follows to the file v.desktop)
  { [[<img src="v.desktop/"><a href="v.desktop/">x</a>]], "<img><a>x</a>" },
  { [[<img src="v.desktop/."><a href="v.desktop/.">x</a>]], "<img><a>x</a>" },
  { [[<img src="v.desktop\"><a href="v.desktop\">x</a>]], "<img><a>x</a>" },
  { [[<img src="v.desktop%2F"><a href="v.desktop%2F">x</a>]], "<img><a>x</a>" },
  { [[<img src="v.desktop//"><a href="v.desktop//">x</a>]], "<img><a>x</a>" },
  { [[<img src="v.desktop/x/.."><a href="v.desktop/x/..">x</a>]], "<img><a>x</a>" },
  { [[<img src="v.desktop/%2e"><a href="v.desktop/%2e">x</a>]], "<img><a>x</a>" },
  {
    [[<img src="desktop.png"><img src="a.desktop.png"><a href="a.desktopx/y">x</a>]],
    [[<img src="desktop.png"><img src="a.desktop.png"><a href="a.desktopx/y">x</a>]],
  },
  -- an address with a scheme leads to another machine, whatever its path ends in
  {
    [[<a href="https://h/a.desktop">x</a><a href="//h/a.desktop">y</a><a href="mailto:a@b.desktop">z</a>]],
    [[<a href="https://h/a.desktop">x</a><a href="https://h/a.desktop">y</a><a href="mailto:a@b.desktop">z</a>]],
  },
  -- srcset and <source> are not kept, whatever they name: a <picture> is left with its <img>
  { [[<img src="a.png" srcset="https://evil.example/x.png 2x">]], [[<img src="a.png">]] },
  { [[<p media="print" srcset="//evil.example/x.png">x</p>]], "<p>x</p>" },
  {
    [[<picture><source media="(prefers-color-scheme: dark)" srcset="https://evil.example/dark.png"><img src="light.png" alt="logo"></picture>]],
    [[<picture><img alt="logo" src="light.png"></picture>]],
  },
  -- what must stay
  {
    [[<section class="footnotes" data-footnotes><ol><li id="fn-1">x</li></ol></section>]],
    [[<section class="footnotes" data-footnotes=""><ol><li id="fn-1">x</li></ol></section>]],
  },
  { [[<a href="https://example.com/?a=1&amp;b=2">x</a>]], [[<a href="https://example.com/?a=1&amp;b=2">x</a>]] },
  {
    [[<a href="mailto:a@example.com">x</a> <a href="#top">y</a> <a href="docs/x.md">z</a> <a href="HTTP://example.com/">w</a>]],
    [[<a href="mailto:a@example.com">x</a> <a href="#top">y</a> <a href="docs/x.md">z</a> <a href="HTTP://example.com/">w</a>]],
  },
  { [[<a href="x" title="&quot;q&quot; &lt;b&gt;">y</a>]], [[<a href="x" title="&quot;q&quot; &lt;b&gt;">y</a>]] },
}

-- Made-up Markdown: a heading, a footnote, an id and a name given in HTML, links to all of them, a task list,
-- and what the other extensions of cmark-gfm write: struck text, an address that is a link, and a table.
local LINKED = [[
<a name="top"></a>

# Title

Text with a note[^one] and [a link down](#given) and [up](#top), [to the title](#title) and [again](#Title).

<h2 id="given">Given</h2>

- [x] done
- [ ] open

~~Struck~~ and https://example.com/a.

| a |
|---|
| 1 |

[^one]: The note.
]]
local LINKED_HTML = [[
<p><a name="top"></a></p>
<h1 id="title">Title</h1>
<p>Text with a note<sup><a data-footnote-ref="" href="#fn-one" id="fnref-one">1</a></sup> and <a href="#given">a link down</a> and <a href="#top">up</a>, <a href="#title">to the title</a> and <a href="#title">again</a>.</p>
<h2 id="given">Given</h2>
<ul>
<li><input checked="" disabled="" type="checkbox"> done</li>
<li><input disabled="" type="checkbox"> open</li>
</ul>
<p><del>Struck</del> and <a href="https://example.com/a">https://example.com/a</a>.</p>
<table>
<thead>
<tr>
<th>a</th>
</tr>
</thead>
<tbody>
<tr>
<td>1</td>
</tr>
</tbody>
</table>
<section class="footnotes" data-footnotes="">
<ol>
<li id="fn-one">
<p>The note. <a href="#fnref-one">↩</a></p>
</li>
</ol>
</section>
]]

-- Made-up Markdown whose pictures are another machine's, but for two.
local REMOTE = [[
![badge](https://img.shields.io/badge/a-b-green)
![local](img/logo.png)
<img src="//evil.example/x.png" alt="relative to the protocol">

<picture>
<source media="(prefers-color-scheme: dark)" srcset="https://evil.example/dark.png">
<source srcset="img/small.png 1x, img/large.png 2x">
<img src="http://evil.example/light.png" alt="logo">
</picture>
<picture><source srcset="img/dark.png"><img src="img/light.png" alt="local logo"></picture>
]]
local REMOTE_HTML = [[
<p><img alt="badge">
<img alt="local" src="img/logo.png">
<img alt="relative to the protocol"></p>
<picture>


<img alt="logo">
</picture>
<picture><img alt="local logo" src="img/light.png"></picture>
]]

-- Task lists. cmark-gfm writes the box of an item that has paragraphs before the first of them; GitHub writes
-- it inside, so the paragraph is made to start before the box. Nothing else of a list changes.
local TASKS = {
  {
    "- [ ] One paragraph\n\n- [x] Another",
    '<ul>\n<li><p><input disabled="" type="checkbox"> \nOne paragraph</p>\n</li>\n'
      .. '<li><p><input checked="" disabled="" type="checkbox"> \nAnother</p>\n</li>\n</ul>\n',
  },
  {
    "1. [ ] First paragraph\n\n   Second paragraph",
    '<ol>\n<li><p><input disabled="" type="checkbox"> \nFirst paragraph</p>\n<p>Second paragraph</p>\n</li>\n</ol>\n',
  },
  {
    "- [ ] Outer\n\n  - [x] inner\n\n- ordinary",
    '<ul>\n<li><p><input disabled="" type="checkbox"> \nOuter</p>\n'
      .. '<ul>\n<li><input checked="" disabled="" type="checkbox"> inner</li>\n</ul>\n</li>\n'
      .. "<li>\n<p>ordinary</p>\n</li>\n</ul>\n",
  },
  {
    "- [ ] no paragraph\n- ordinary",
    '<ul>\n<li><input disabled="" type="checkbox"> no paragraph</li>\n<li>ordinary</li>\n</ul>\n',
  },
  -- text between the box and the paragraph: the box is not the paragraph's
  {
    "<ul><li><input type=checkbox> text <p>paragraph</p></li></ul>",
    '<ul><li><input type="checkbox"> text <p>paragraph</p></li></ul>\n',
  },
  { "<li><input type=checkbox>\n<p>", '<li><p><input type="checkbox">\n\n' },
  { "<li><input type=checkbox>\n", '<li><input type="checkbox">\n' },
}

-- Headings and, written out by hand, what GitHub names them. The rule: the text of the heading in lower case;
-- of ASCII the letters, the digits, _ and - stay, of the other characters the letters, marks and digits; each
-- space becomes a hyphen, and none is trimmed; a second heading of one name gets -1, the third -2. The name is
-- the heading's id, unless the document gave it one.
local HEADINGS = {
  { "# Hello, World!", '<h1 id="hello-world">Hello, World!</h1>\n' },
  { "## What is new in v2.0?", '<h2 id="what-is-new-in-v20">What is new in v2.0?</h2>\n' },
  { "## snake_case and kebab-case", '<h2 id="snake_case-and-kebab-case">snake_case and kebab-case</h2>\n' },
  { "## Install & run", '<h2 id="install--run">Install &amp; run</h2>\n' },
  { "## a  b   c", '<h2 id="a--b---c">a  b   c</h2>\n' },
  { "## Not trimmed <!-- a comment -->", '<h2 id="not-trimmed-">Not trimmed </h2>\n' },
  { "## Über die Größe", '<h2 id="über-die-größe">Über die Größe</h2>\n' },
  { "## ÉCOUTE ÇA", '<h2 id="écoute-ça">ÉCOUTE ÇA</h2>\n' },
  { "## Привет, мир", '<h2 id="привет-мир">Привет, мир</h2>\n' },
  { "## 你好，世界！", '<h2 id="你好世界">你好，世界！</h2>\n' },
  { "## 2 × 3 ÷ 1 µm", '<h2 id="2--3--1-µm">2 × 3 ÷ 1 µm</h2>\n' },
  { "## 🚀 Launch", '<h2 id="-launch">🚀 Launch</h2>\n' },
  -- the name is made from the name of an emoji, not from the emoji
  { "## :rocket: Launch", '<h2 id="rocket-launch">🚀 Launch</h2>\n' },
  { "## The `apply()` function", '<h2 id="the-apply-function">The <code>apply()</code> function</h2>\n' },
  {
    "## See [the docs](https://example.com/a) now",
    '<h2 id="see-the-docs-now">See <a href="https://example.com/a">the docs</a> now</h2>\n',
  },
  { "Setext *title*\n===", '<h1 id="setext-title">Setext <em>title</em></h1>\n' },
  { '<h3 align="center">Raw <em>HTML</em></h3>', '<h3 align="center" id="raw-html">Raw <em>HTML</em></h3>\n' },
  {
    "# Usage\n\n## Usage\n\n### usage\n\n## Other\n\n## Usage",
    '<h1 id="usage">Usage</h1>\n<h2 id="usage-1">Usage</h2>\n<h3 id="usage-2">usage</h3>\n'
      .. '<h2 id="other">Other</h2>\n<h2 id="usage-3">Usage</h2>\n',
  },
  -- an id of the document's own stays, and the heading counts as one of its name
  { '<h2 id="Own">Usage</h2>\n\n## Usage', '<h2 id="Own">Usage</h2>\n<h2 id="usage-1">Usage</h2>\n' },
  -- a name of no characters is no id
  { "## 🎉\n\n## 🎉", '<h2>🎉</h2>\n<h2 id="-1">🎉</h2>\n' },
  -- a heading ends where the next one starts, as in a browser
  { "<h2>One<h3>Two</h3>", '<h2 id="one">One<h3 id="two">Two</h3>\n' },
  { "<h2>never closed", "<h2>never closed\n" },
}

-- Made-up Markdown for the links that github.com follows whatever their case: a link into the page that names
-- no id and no name of it, but an id once it is in lower case, is written in lower case. Nothing else changes.
-- cmark-gfm writes the address of link 13 percent-encoded.
local CASE = [[
# Usage

## Setup

<h2 id="Setup">An id of its own</h2>

## Notes

## Über uns

<a name="Notes"></a><a name="Top"></a>

[1](#Usage) [2](#USAGE) [3](#usage)
[4](#Setup) [5](#setup)
[6](#Notes) [7](#NOTES)
[8](#Top) [9](#top) [10](#Nowhere) [11](other.md#Usage) [12](#)
[13](#Über-uns)
]]
local CASE_HTML = [[
<h1 id="usage">Usage</h1>
<h2 id="setup">Setup</h2>
<h2 id="Setup">An id of its own</h2>
<h2 id="notes">Notes</h2>
<h2 id="über-uns">Über uns</h2>
<p><a name="Notes"></a><a name="Top"></a></p>
<p><a href="#usage">1</a> <a href="#usage">2</a> <a href="#usage">3</a>
<a href="#Setup">4</a> <a href="#setup">5</a>
<a href="#Notes">6</a> <a href="#notes">7</a>
<a href="#Top">8</a> <a href="#top">9</a> <a href="#Nowhere">10</a> <a href="other.md#Usage">11</a> <a href="#">12</a>
<a href="#über-uns">13</a></p>
]]

-- The five alerts and GitHub's title of each.
local ALERTS = { note = "Note", tip = "Tip", important = "Important", warning = "Warning", caution = "Caution" }

--- The box of an alert around `body`, with an icon whose path is left out.
local function alert(kind, body)
  return (
    '<div class="markdown-alert markdown-alert-%s"><p class="markdown-alert-title">'
    .. '<svg class="octicon mr-2" height="16" viewBox="0 0 16 16" width="16"><path d=""></path></svg>'
    .. "%s</p>%s</div>\n"
  ):format(kind, ALERTS[kind], body)
end

--- `text` without the path of each icon. (Only what a path is made of is taken out.)
local function pathless(text) return (text:gsub(' d="M[%w .-]+"', ' d=""')) end

-- Quotes and what GitHub shows for them. A quote at the top level whose first paragraph starts with the mark
-- of an alert, alone on its line, is the box of that alert, and the mark is gone; any other quote stays.
local QUOTES = {
  { "> [!WARNING]\n>\n> A paragraph of its own.", alert("warning", "\n<p>A paragraph of its own.</p>\n") },
  { "> [!NOTE]", alert("note", "\n") },
  { "> [!tip]\n> In lower case.", alert("tip", "<p>In lower case.</p>\n") },
  { "> [!NOTE]\n> One.\n\n> [!TIP]\n> Two.", alert("note", "<p>One.</p>\n") .. alert("tip", "<p>Two.</p>\n") },
  {
    "> [!NOTE]\n> > [!TIP]\n> > A quote in an alert.",
    alert("note", "\n<blockquote>\n<p>[!TIP]\nA quote in an alert.</p>\n</blockquote>\n"),
  },
  { "- item\n\n> [!TIP]\n> After a list.", "<ul>\n<li>item</li>\n</ul>\n" .. alert("tip", "<p>After a list.</p>\n") },
  { "</li>\n\n> [!TIP]\n> After an end tag.", "</li>\n" .. alert("tip", "<p>After an end tag.</p>\n") },
  -- not alerts
  { "> [!NOTE] Text on its line.", "<blockquote>\n<p>[!NOTE] Text on its line.</p>\n</blockquote>\n" },
  { "> [!NOTE] *Text* on its line.", "<blockquote>\n<p>[!NOTE] <em>Text</em> on its line.</p>\n</blockquote>\n" },
  { "> Text first.\n> [!NOTE]", "<blockquote>\n<p>Text first.\n[!NOTE]</p>\n</blockquote>\n" },
  { "> [!DANGER]\n> No such kind.", "<blockquote>\n<p>[!DANGER]\nNo such kind.</p>\n</blockquote>\n" },
  { "[!NOTE]\nNo quote.", "<p>[!NOTE]\nNo quote.</p>\n" },
  {
    "- > [!NOTE]\n  > In a list.",
    "<ul>\n<li>\n<blockquote>\n<p>[!NOTE]\nIn a list.</p>\n</blockquote>\n</li>\n</ul>\n",
  },
  {
    "> > [!NOTE]\n> > In a quote.",
    "<blockquote>\n<blockquote>\n<p>[!NOTE]\nIn a quote.</p>\n</blockquote>\n</blockquote>\n",
  },
}

-- HTML that cmark-gfm does not write: quotes and headings that end early or hold nothing. github.lua changes
-- none of it, and raises nothing.
local CUT_SHORT = {
  "<blockquote>\n<p>[!NOTE]\ntext</p>\n",
  "<blockquote>",
  "<blockquote></blockquote><p>[!NOTE]</p>",
  "<h1><h1>",
  "</h1></blockquote></li></code>",
}

-- Text and the emoji GitHub writes for the names in it: none in code, and none for a name it does not know.
local EMOJI = {
  { "Ship it :rocket: and :+1:.", "<p>Ship it 🚀 and 👍.</p>\n" },
  -- U+26A0 and the U+FE0F that makes a picture of it
  { ":warning:", "<p>\226\154\160\239\184\143</p>\n" },
  { ":nope: :octocat: : rocket :", "<p>:nope: :octocat: : rocket :</p>\n" },
  { "`:rocket:` and :rocket:", "<p><code>:rocket:</code> and 🚀</p>\n" },
  {
    "```\n:rocket:\n```\n\n    :tada:\n\n:tada:",
    "<pre><code>:rocket:\n</code></pre>\n<pre><code>:tada:\n</code></pre>\n<p>🎉</p>\n",
  },
  { "<kbd>:+1:</kbd> <tt>:tada:</tt> <b>:tada:</b>", "<p><kbd>:+1:</kbd> <tt>:tada:</tt> <b>🎉</b></p>\n" },
  { "<pre>:tada:</pre>\n\n:tada:", "<pre>:tada:</pre>\n<p>🎉</p>\n" },
  -- an end tag that ends nothing
  { "</kbd> :tada:", "<p></kbd> 🎉</p>\n" },
  { '[:rocket:](x.md ":rocket:")', '<p><a href="x.md" title=":rocket:">🚀</a></p>\n' },
}

-- Hostile Markdown for what github.lua adds, and what must be left of it.
local HOSTILE = {
  {
    [[<h2 id='x" onclick="alert(1)'>Own</h2>]] .. "\n\n" .. [[<a href='#X" ONCLICK="ALERT(1)'>link</a>]],
    '<h2 id="x&quot; onclick=&quot;alert(1)">Own</h2>\n<p><a href="#x&quot; onclick=&quot;alert(1)">link</a></p>\n',
  },
  {
    "> [!CAUTION]\n> A <script>alert(1)</script> and [a link](javascript:alert(2)),\n"
      .. [[> <a href="javascript:alert(3)" onclick="alert(4)">raw</a> <img src=x onerror=alert(5)>]]
      .. "\n>\n> <script>alert(6)</script>",
    alert(
      "caution",
      '<p>A &lt;script&gt;alert(1)&lt;/script&gt; and <a>a link</a>,\n<a>raw</a> <img src="x"></p>\n'
        .. "&lt;script&gt;alert(6)&lt;/script&gt;\n"
    ),
  },
}

--- The sha256 of `text` as a policy names it, from a program that is not Neovim's.
local function hash_of(text)
  local summed = vim.system({ "sha256sum" }, { stdin = text }):wait()
  assert(summed.code == 0, summed.stderr)
  local bytes = summed.stdout:match("^%x+"):gsub("%x%x", function(byte) return string.char(tonumber(byte, 16)) end)
  return vim.base64.encode(bytes)
end

local notes, opened = {}, {}
local opener_error
local notify, ui_open, path_before = vim.notify, vim.ui.open, vim.env.PATH
---@diagnostic disable-next-line: duplicate-set-field
vim.notify = function(message, level, opts)
  notes[#notes + 1] = { message = message, level = level, title = (opts or {}).title }
end
---@diagnostic disable-next-line: duplicate-set-field
vim.ui.open = function(path)
  opened[#opened + 1] = path
  return nil, opener_error
end

--- Previews buffer `buf` with `open`, or with the key when `key` is given. Returns the page's path, or nil when
--- nothing was opened, and the notifications.
local function open(buf, key)
  notes, opened = {}, {}
  if key then
    press(key)
  else
    preview.open(buf)
  end
  return opened[1], notes
end

--- A directory with a cmark-gfm in it that is the shell script `script`.
local function stand_in(dir, script)
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ "#!/bin/sh", script }, dir .. "/cmark-gfm")
  assert(vim.uv.fs_chmod(dir .. "/cmark-gfm", tonumber("755", 8)))
  return dir
end

--- Runs `run` while `owner[name]` is what `replace` makes of it. Returns what `pcall(run)` does.
local function standing_in(owner, name, replace, run)
  local real = owner[name]
  owner[name] = replace(real)
  local results = { pcall(run) }
  owner[name] = real
  return unpack(results)
end

local ERROR = vim.log.levels.ERROR
local base = vim.fn.tempname()

local run_ok, err = xpcall(function()
  assert(vim.fn.executable "cmark-gfm" == 1, "the cmark-gfm program is not installed")

  for _, case in ipairs(SANITISED) do
    local input, expected = case[1], case[2]
    local made = html.write(html.parse(input))
    ok(("sanitised: %q"):format(input), made == expected, ("%q\n      not %q"):format(made, expected))
  end

  local a_link = { { tag = "a", attrs = { href = 'x"y' } }, { text = "1 < 2 &amp; 3" }, { close = "a" } }
  ok("write escapes values and text", html.write(a_link) == [[<a href="x&quot;y">1 &lt; 2 &amp; 3</a>]])
  local an_icon = {
    { tag = "svg", attrs = { viewBox = "0 0 16 16", width = "16" } },
    { tag = "path", attrs = { d = 'M0 0"<' } },
    { close = "path" },
    { close = "svg" },
  }
  ok(
    "write takes the names of an alert's icon",
    html.write(an_icon) == [[<svg viewBox="0 0 16 16" width="16"><path d="M0 0&quot;&lt;"></path></svg>]],
    html.write(an_icon)
  )
  for name, tokens in pairs {
    ["an unknown tag"] = { { tag = "script", attrs = {} } },
    ["an unknown end tag"] = { { close = "script" } },
    ["an unknown attribute"] = { { tag = "a", attrs = { onclick = "alert(1)" } } },
    ["a tag that only looks like a listed one"] = { { tag = "a onclick=alert(1)", attrs = {} } },
  } do
    local wrote, problem = pcall(html.write, tokens)
    ok("write refuses " .. name, not wrote and tostring(problem):find("not listed", 1, true), problem)
  end
  local uri = "file:///tmp/p.html"
  ok(
    "and no page is built of such a token",
    not pcall(page.build, { title = "t", tokens = { { close = "script" } }, uri = uri })
  )

  local function two_links() return html.parse [[<a href="#x">x</a><a href="y.md">y</a><a id="x"></a>]] end
  local built = page.build { title = 'a<b>&"c.md', tokens = two_links(), uri = uri, dir = "/tmp/x/a b#c?d%e" }
  local style = built:match "<style>(.-)</style>"
  local policy = built:match '<meta http%-equiv="Content%-Security%-Policy" content="([^"]*)">'
  ok(
    "the policy allows the one stylesheet, pictures and a <base> that are files, and nothing else",
    policy
      == ("default-src 'none'; img-src file:; style-src 'sha256-%s'; base-uri file:; form-action 'none'"):format(
        hash_of(style)
      ),
    policy
  )
  ok("the page has one style element", select(2, built:gsub("<style", "")) == 1)
  local undefined = {}
  for name in style:gmatch "var%((%-%-[%w-]+)" do
    if not style:find(name .. ":", 1, true) then undefined[name] = true end
  end
  ok(
    "every colour the stylesheet uses is defined, but for the one that its release does not define",
    vim.deep_equal(vim.tbl_keys(undefined), { "--bgColor-danger-muted" }),
    vim.inspect(undefined)
  )
  ok("the title is escaped", built:find("<title>a&lt;b&gt;&amp;&quot;c.md</title>", 1, true), built:match "<title>.-\n")
  ok(
    "<base> is the directory, whatever its name",
    built:match "<base [^>]*>" == [[<base href="file:///tmp/x/a%20b%23c%3fd%25e/">]],
    built:match "<base [^>]*>"
  )
  ok(
    "the document is the body, and of its links the one into the page names the page",
    built:find(
      '<body class="markdown-body">\n<a href="file:///tmp/p.html#x">x</a><a href="y.md">y</a><a id="x"></a>\n</body></html>',
      1,
      true
    ),
    built:match "<body.*"
  )
  local alone = page.build { title = "Markdown", tokens = two_links(), uri = uri }
  ok("a page without a directory has no <base>", not alone:find("<base", 1, true))
  ok(
    "and its links into the page stay bare",
    alone:find('\n<a href="#x">x</a><a href="y.md">y</a><a id="x"></a>\n', 1, true)
  )

  ok(
    "render: links, ids, names, footnotes, task lists and the other extensions",
    preview.render(LINKED) == LINKED_HTML,
    preview.render(LINKED)
  )
  ok("render: no picture of another machine", preview.render(REMOTE) == REMOTE_HTML, preview.render(REMOTE))

  -- what github.lua adds
  local function renders(name, cases, made_of)
    for _, case in ipairs(cases) do
      local made = made_of(case[1])
      ok(("%s: %q"):format(name, case[1]), made == case[2], ("%q\n      not %q"):format(made, case[2]))
    end
  end
  renders("task list", TASKS, preview.render)
  renders("heading", HEADINGS, preview.render)
  ok("render: a link finds a heading whatever its case", preview.render(CASE) == CASE_HTML, preview.render(CASE))
  for kind in pairs(ALERTS) do
    local made = pathless(preview.render(("> [!%s]\n> Body *one*."):format(kind:upper())))
    local expected = alert(kind, "<p>Body <em>one</em>.</p>\n")
    ok("alert: " .. kind, made == expected, ("%q\n      not %q"):format(made, expected))
  end
  renders("quote", QUOTES, function(markdown) return pathless(preview.render(markdown)) end)
  renders("emoji", EMOJI, preview.render)
  renders("hostile", HOSTILE, function(markdown) return pathless(preview.render(markdown)) end)
  -- (`tolower()`, which github.lua calls, takes no NUL byte: cmark-gfm writes U+FFFD for one)
  ok("a NUL byte in a heading and in a link raises nothing", pcall(preview.render, "# a\0b\n\n[x](#A\0B) [y](#A%00B)"))
  for _, input in ipairs(CUT_SHORT) do
    local applied, made = pcall(function() return html.write(github.apply(html.parse(input))) end)
    ok(("cut short: %q"):format(input), applied and made == input, made)
  end

  -- Input that the code read once for every space or every tag in it, which took 40 s, 82 s and 179 s.
  for name, input in pairs {
    ["an address with 100,000 spaces in it"] = '<a href="x' .. (" "):rep(100000) .. 'y">l</a>',
    ["20,000 headings inside each other"] = ("<h1>x"):rep(20000) .. ("</h1>"):rep(20000),
    ["160,000 quotes inside each other"] = ("<blockquote>"):rep(160000),
  } do
    local start = vim.uv.hrtime()
    html.write(github.apply(html.parse(input)))
    local seconds = (vim.uv.hrtime() - start) / 1e9
    ok(name .. " takes no more than 3 seconds", seconds <= 3, seconds)
  end

  vim.fn.mkdir(base .. "/docs", "p")
  local temporary = vim.fs.dirname(vim.fn.tempname())
  local file = base .. "/docs/notes.md"
  vim.fn.writefile(vim.split(LINKED, "\n"), file)
  vim.cmd.edit(file)
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "Not saved **yet**.", "" })
  local path, said = open(buf)
  ok("open gives the opener one page and says nothing", #opened == 1 and #said == 0, vim.inspect { opened, said })
  ok(
    "the page is in Neovim's temporary directory",
    vim.startswith(path, temporary .. "/") and path:find "%.html$" and vim.fn.filereadable(path) == 1,
    path
  )
  local text = read(path)
  ok("unsaved changes are in it", text:find("<p>Not saved <strong>yet</strong>.</p>", 1, true))
  ok("and are still unsaved", vim.bo[buf].modified and not read(file):find("Not saved", 1, true))
  ok("its title is the file's name", text:find("<title>notes.md</title>", 1, true), text:match "<title>.-\n")
  ok(
    "its <base> is the file's directory",
    text:find(('<base href="%s/">'):format(vim.uri_from_fname(base .. "/docs")), 1, true),
    text:match "<base [^>]*>"
  )
  ok(
    "a link into the page names the page",
    text:find(('<a href="%s#given">a link down</a>'):format(vim.uri_from_fname(path)), 1, true),
    text:match "<body.*"
  )

  vim.cmd.enew()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Text." })
  text = read(open(vim.api.nvim_get_current_buf()))
  ok("a buffer without a file gets no <base>", not text:find("<base", 1, true))
  ok("and a title", text:find("<title>Markdown</title>", 1, true))

  opener_error = "vim.ui.open: no handler found (tried: xdg-open)"
  path, said = open(buf)
  ok(
    "without a program to open the page, the error and the page's path are said",
    #said == 1
      and said[1].level == ERROR
      and said[1].title == "Markdown preview"
      and said[1].message == opener_error .. "\nThe page is " .. path
      and vim.fn.filereadable(path) == 1,
    vim.inspect(said)
  )
  opener_error = nil

  local function failure(name, dir, message)
    vim.env.PATH = dir
    path, said = open(buf)
    vim.env.PATH = path_before
    ok(
      name,
      path == nil
        and #said == 1
        and said[1].level == ERROR
        and said[1].title == "Markdown preview"
        and said[1].message == message,
      vim.inspect { path, said }
    )
  end
  vim.fn.mkdir(base .. "/empty")
  failure("without cmark-gfm, that is said", base .. "/empty", "cmark-gfm is not installed")
  failure(
    "a cmark-gfm that fails has its say",
    stand_in(base .. "/fails", "echo 'cannot read this' >&2; exit 3"),
    "cannot read this"
  )
  failure(
    "or its exit code when it says nothing",
    stand_in(base .. "/silent", "exit 3"),
    "cmark-gfm ended with code 3 and signal 0"
  )
  failure(
    "or the signal that ended it",
    stand_in(base .. "/killed", "kill -TERM $$"),
    "cmark-gfm ended with code 0 and signal 15"
  )
  -- (the limit is asked for and not waited for)
  local waited
  standing_in(
    vim,
    "system",
    function(real)
      return function(cmd, opts)
        local job = real(cmd, opts)
        return {
          wait = function(_, ms)
            waited = ms
            return job:wait(50)
          end,
        }
      end
    end,
    function()
      failure(
        "a cmark-gfm that does not finish is ended, and that is said",
        stand_in(base .. "/hangs", "exec sleep 60") .. ":" .. path_before,
        "cmark-gfm did not finish within 10 s"
      )
    end
  )
  ok("after the ten seconds it was given", waited == 10000, waited)

  vim.cmd.edit(base .. "/docs/other.md")
  local other = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(other, 0, -1, false, { "# Only in the other buffer" })
  local key = vim.fn.maparg("<Leader>gm", "n", false, true)
  ok("<Leader>gm is a key of a Markdown buffer", key.buffer == 1 and (key.desc or "") ~= "", vim.inspect(key))
  path, said = open(nil, "<Leader>gm")
  ok(
    "pressing it previews that buffer",
    #opened == 1
      and #said == 0
      and read(path):find('<h1 id="only-in-the-other-buffer">Only in the other buffer</h1>', 1, true),
    vim.inspect { opened, said }
  )
  vim.cmd.edit(base .. "/docs/plain.txt")
  ok(
    "a buffer of another filetype has no such key",
    vim.fn.maparg("<Leader>gm", "n") == "",
    vim.fn.maparg("<Leader>gm", "n")
  )
  ok(
    "and pressing it there previews nothing",
    open(nil, "<Leader>gm") == nil and #notes == 0,
    vim.inspect { opened, notes }
  )

  -- The colours of code (code.lua), with the parsers and queries that are installed. An expected class is
  -- worked out by hand, from the highlights query of the language and the tables of code.lua.
  do
    local code = require "user.markdown_preview.code"
    local WARN = vim.log.levels.WARN
    for _, language in ipairs { "lua", "python", "bash", "json", "markdown", "markdown_inline" } do
      assert(vim.treesitter.language.add(language), ("the treesitter parser of %s is not installed"):format(language))
    end

    local function fence(language, source) return ("````%s\n%s\n````\n"):format(language, source) end
    --- What the Neovim that colours answers to `input`, made in this process: the stand-ins for treesitter
    --- below are this process's.
    local function drawn_here(input) return vim.json.encode(code.draw(vim.json.decode(input).blocks)) end
    --- A `vim.system` whose Neovim ends as `result` says, or with the answer of `drawn_here`.
    local function system_with(result)
      return function(real)
        return function(cmd, opts)
          if cmd[1] ~= vim.v.progpath then return real(cmd, opts) end
          return { wait = function() return result or { code = 0, signal = 0, stdout = drawn_here(opts.stdin) } end }
        end
      end
    end
    local function render(markdown, result)
      notes = {}
      local ran, rendered = standing_in(
        vim,
        "system",
        system_with(result),
        function() return preview.render(markdown) end
      )
      return assert(ran and rendered, rendered)
    end
    --- A rendering without its colours.
    local function plain(rendered) return (rendered:gsub('<span class="pl%-%w+">', ""):gsub("</span>", "")) end
    --- Checks that a rendering of `markdown` has each piece of `expected` (as the HTML has it) in its class.
    local function coloured(name, markdown, expected)
      local found, wrong = {}, {}
      for class, piece in render(markdown):gmatch '<span class="([^"]*)">([^<]*)</span>' do
        found[piece] = class
      end
      for piece, class in pairs(expected) do
        if found[piece] ~= class then wrong[piece] = found[piece] or "no class" end
      end
      ok(name, next(wrong) == nil and #notes == 0, vim.inspect { wrong = wrong, notes = notes })
    end
    coloured(
      "Lua: a keyword, a function's name, a number, a comment and a string",
      fence("lua", 'local function double(n)\n  return n * 2 -- twice\nend\nprint("done")'),
      { ["local"] = "pl-k", double = "pl-en", ["2"] = "pl-c1", ["-- twice"] = "pl-c", ["&quot;done&quot;"] = "pl-s" }
    )
    coloured(
      "Python: a keyword, a function's name, a number, a comment and a string",
      fence("python", 'def area(width):\n    # in metres\n    return width * 3.5 + len("m")'),
      { def = "pl-k", area = "pl-en", ["3.5"] = "pl-c1", ["# in metres"] = "pl-c", ["&quot;m&quot;"] = "pl-s" }
    )
    coloured(
      "Lua's own classes for a call and a field, and a method the query captures a second time as `_method`",
      fence("lua", 'halve(opts.width):find "x"'),
      { halve = "pl-c1", width = "pl-e", find = "pl-en" }
    )
    coloured(
      "Bash's own class for the first line, which the query also captures as `nospell`",
      fence("bash", '#!/bin/sh\necho "hi"'),
      { ["#!/bin/sh"] = "pl-c", ["&quot;hi&quot;"] = "pl-s" }
    )
    coloured("a block of sh is coloured as one of bash", fence("sh", "# note"), { ["# note"] = "pl-c" })
    coloured("and one of LUA as one of lua", fence("LUA", "local x"), { ["local"] = "pl-k" })

    ok("the text of a coloured block is the text of the code", plain(render(fence(
      "lua",
      [[
local s = "a < b && c > d" .. 'x'
-- grüße, 日本語, 🚀
if 1 < 2 and s ~= "&amp;" then print(s) end]]
    ))) == [[
<pre lang="lua"><code>local s = &quot;a &lt; b &amp;&amp; c &gt; d&quot; .. 'x'
-- grüße, 日本語, 🚀
if 1 &lt; 2 and s ~= &quot;&amp;amp;&quot; then print(s) end
</code></pre>
]])

    for name, block in pairs {
      ["a language without a parser"] = { fence("mermaid", "graph TD;"), '<pre lang="mermaid"><code>graph TD;\n' },
      ["a fence without a language"] = { fence("", "local x = 1"), "<pre><code>local x = 1\n" },
      ["a block of another shape"] = {
        '<pre lang="lua"><code>local <b>x</b> = 1\n</code></pre>\n',
        '<pre lang="lua"><code>local <b>x</b> = 1\n',
      },
    } do
      local rendered = render(block[1])
      ok(name .. " is left as it is", rendered == block[2] .. "</code></pre>\n" and #notes == 0, rendered)
    end

    for name, language in pairs {
      ["a path"] = "../../evil",
      ["a NUL"] = "lua\0",
      ["nothing"] = "",
    } do
      local block = html.parse '<pre lang="x"><code>local x = 1\n</code></pre>'
      block[1].attrs.lang = language
      local ran, tokens, problem = pcall(code.colour, block, function(_, input) return drawn_here(input) end)
      ok(
        "a language whose name is " .. name .. " is not coloured, and nothing is said",
        ran and problem == nil and vim.deep_equal(tokens, block),
        vim.inspect { tokens, problem }
      )
    end

    local hostile = render(fence("lua", 'local s = "</code></pre><script>alert(1)</script>" -- &amp; &#60; &copy;'))
    local HOSTILE_STRING = "&quot;&lt;/code&gt;&lt;/pre&gt;&lt;script&gt;alert(1)&lt;/script&gt;&quot;"
    ok(
      "code that holds tags and character references keeps them as text",
      hostile:find(('<span class="pl-s">%s</span>'):format(HOSTILE_STRING), 1, true)
        and plain(hostile)
          == ('<pre lang="lua"><code>local s = %s -- &amp;amp; &amp;#60; &amp;copy;\n</code></pre>\n'):format(
            HOSTILE_STRING
          ),
      hostile
    )
    -- (the text of a block is written anew from its code: these two would not come back as they were)
    for name, block in pairs {
      ["references that are not cmark-gfm's"] = '<pre lang="lua"><code>local n &#61; &quot;&copy;&quot;</code></pre>\n',
      ["a quote that is no reference"] = '<pre lang="lua"><code>local n = "one"</code></pre>\n',
    } do
      local rendered = render(block)
      ok("a block written as HTML with " .. name .. " is left as it is", rendered == block and #notes == 0, rendered)
    end
    local as_html = render '<pre lang="lua"><code>local n = &quot;&amp;&quot; -- &lt;b&gt;</code></pre>\n'
    ok(
      "and one written as cmark-gfm writes is coloured",
      as_html
        == '<pre lang="lua"><code><span class="pl-k">local</span> <span class="pl-smi">n</span> <span class="pl-k">=</span> '
          .. '<span class="pl-s">&quot;&amp;&quot;</span> <span class="pl-c">-- &lt;b&gt;</span></code></pre>\n',
      as_html
    )

    local document = fence("lua", "local a = 1")
      .. fence("json", '{ "b": 2 }')
      .. fence("python", "c = 3")
      .. fence("lua", "local d = 4")
    local query_error = 'Query error at 1:2. Invalid node type "gone"'
    local ran, made = standing_in(vim.treesitter.query, "get", function(real)
      return function(language, kind)
        if language ~= "json" then error(query_error, 0) end
        return real(language, kind)
      end
    end, function() return render(document) end)
    ok(
      "a query that does not fit its parser costs the colours of its language, and not those of another",
      ran
        and made:find('<pre lang="lua"><code>local a = 1\n</code></pre>', 1, true)
        and made:find('<span class="pl-ent">&quot;b&quot;</span>', 1, true)
        and made:find('<pre lang="python"><code>c = 3\n</code></pre>', 1, true)
        and made:find('<pre lang="lua"><code>local d = 4\n</code></pre>', 1, true),
      made
    )
    local function warned(message)
      return #notes == 1
        and notes[1].level == WARN
        and notes[1].title == "Markdown preview"
        and notes[1].message == message
    end
    ok(
      "and one warning names each language once, and the error",
      warned(("No colours for lua code: %s\nNo colours for python code: %s"):format(query_error, query_error)),
      vim.inspect(notes)
    )
    ok("a token that is none is an error, not a warning", not pcall(code.colour, { { tag = "pre" } }, drawn_here))

    -- The Neovim of its own that draws the code. One that does not answer is a stand-in: a parser that hangs or
    -- ends its Neovim does so by a fault that will be mended.
    local started = {}
    local function counted(real)
      return function(cmd, opts)
        started[#started + 1] = cmd[1]
        return real(cmd, opts)
      end
    end
    notes = {}
    ran, made = standing_in(
      vim,
      "system",
      counted,
      function() return preview.render(fence("lua", "local a = 1") .. fence("python", "c = 3")) end
    )
    ok(
      "the code of a document is coloured by a Neovim of its own, which finds the parsers of this one",
      ran
        and made == '<pre lang="lua"><code><span class="pl-k">local</span> <span class="pl-smi">a</span> <span class="pl-k">=</span> <span class="pl-c1">1</span>\n</code></pre>\n' .. '<pre lang="python"><code><span class="pl-smi">c</span> <span class="pl-k">=</span> <span class="pl-c1">3</span>\n</code></pre>\n'
        and #notes == 0,
      vim.inspect { made, notes }
    )
    ok(
      "one for the document, started after cmark-gfm",
      vim.deep_equal(started, { "cmark-gfm", vim.v.progpath }),
      vim.inspect(started)
    )
    started = {}
    standing_in(vim, "system", counted, function() return preview.render "# Title\n\n```\nlocal a = 1\n```\n" end)
    ok(
      "a document without a block of a language starts none",
      vim.deep_equal(started, { "cmark-gfm" }),
      vim.inspect(started)
    )
    for name, case in pairs {
      ["does not finish"] = { { code = 124, signal = 9 }, "nvim did not finish within 10 s" },
      ["is ended by a signal"] = { { code = 0, signal = 6, stderr = "" }, "nvim ended with code 0 and signal 6" },
    } do
      made = render(fence("lua", "local a = 1") .. fence("python", "c = 3"), case[1])
      ok(
        "a Neovim that " .. name .. " leaves the code uncoloured",
        made == '<pre lang="lua"><code>local a = 1\n</code></pre>\n<pre lang="python"><code>c = 3\n</code></pre>\n',
        made
      )
      ok("and a warning says so", warned("No colours for code: " .. case[2]), vim.inspect(notes))
    end

    coloured(
      "a block of Markdown is coloured, and the Lua in a fence of its own by Lua's classes",
      fence("markdown", "# Title\n\n```lua\nlocal x = opts.width\n```"),
      { ["# Title\n"] = "pl-mh", ["local"] = "pl-k", width = "pl-e" }
    )

    local together = render '# Set up :tada:\n\n> [!NOTE]\n> Run it.\n\n```lua\nlocal s = ":rocket:" -- :tada:\n```\n'
    ok(
      "a heading, an alert and coloured code in one text, and the name of an emoji in the code stays",
      pathless(plain(together))
          == '<h1 id="set-up-tada">Set up 🎉</h1>\n' .. alert("note", "<p>Run it.</p>\n") .. '<pre lang="lua"><code>local s = &quot;:rocket:&quot; -- :tada:\n</code></pre>\n'
        and together:find('<span class="pl-s">&quot;:rocket:&quot;</span> <span class="pl-c">-- :tada:</span>', 1, true),
      together
    )
  end

  ok("nothing reported an error", vim.v.errmsg == "", vim.v.errmsg)
end, debug.traceback)

vim.notify, vim.ui.open, vim.env.PATH = notify, ui_open, path_before
vim.fn.delete(base, "rf")
harness.finish(run_ok, err)
