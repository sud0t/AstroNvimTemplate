-- LaTeX snippets: the Obsidian LaTeX Suite snippets (~/Obsidian/Math/.obsidian/plugins/obsidian-latex-suite/data.json,
-- including the ossu-course-builder additions) ported to .tex, plus a few text-mode snippets for documents.
-- The LaTeX Suite entries keep that plugin's format; lua/user/latex_suite.lua turns them into LuaSnip snippets and
-- explains the options. Strings are copied as-is (JS and Lua escapes match); JS /regex/ literals became [=[...]=].
-- Changes for .tex: mk -> $...$, dm -> \[...\], `align` inside math -> aligned (align can't nest in math),
-- the Markdown-only snippets (list display math, Mathpad `chk`) are left out and `prob` writes LaTeX.

local ls = require "luasnip"
local s, i = ls.snippet, ls.insert_node
local fmta = require("luasnip.extras.fmt").fmta
local rep = require("luasnip.extras").rep
local line_begin = require("luasnip.extras.expand_conditions").line_begin
local suite = require "user.latex_suite"

local function in_text() return not suite.in_math() end

-- stylua: ignore start
local snippets, autosnippets = suite.build {
  -- Math mode
  { "mk", "$$0$", "tA" },
  { "dm", "\\[\n$0\n\\]", "tAw", description = "Display math" },
  { [=[([^\\\w])beg]=], "[[0]]\\begin{$0}\n$1\n\\end{$0}", "rMA" },
  { [=[([^\\\w])beg]=], "[[0]]\\begin{$0} $1 \\end{$0}", "rnA" },

  -- Greek letters
  { "@a", "\\alpha", "mA" },
  { "@b", "\\beta", "mA" },
  { "@g", "\\gamma", "mA" },
  { "@G", "\\Gamma", "mA" },
  { "@d", "\\delta", "mA" },
  { "@D", "\\Delta", "mA" },
  { "@e", "\\epsilon", "mA" },
  { ":e", "\\varepsilon", "mA" },
  { "@z", "\\zeta", "mA" },
  { "@t", "\\theta", "mA" },
  { "@T", "\\Theta", "mA" },
  { ":t", "\\vartheta", "mA" },
  { "@i", "\\iota", "mA" },
  { "@k", "\\kappa", "mA" },
  { "@l", "\\lambda", "mA" },
  { "@L", "\\Lambda", "mA" },
  { "@s", "\\sigma", "mA" },
  { "@S", "\\Sigma", "mA" },
  { "@u", "\\upsilon", "mA" },
  { "@U", "\\Upsilon", "mA" },
  { "@o", "\\omega", "mA" },
  { "@O", "\\Omega", "mA" },
  { "ome", "\\omega", "mA" },
  { "Ome", "\\Omega", "mA" },

  -- Text environment
  { [=[^(\s*)"]=], "[[0]]\\text{$0 } $1", "rmA", description = "Text at the beginning of a line" },
  { "text", "\\text{$0}$1", "mA", priority = -1 },
  { "\"", "\\text{$0}$1", "mA", priority = -1 },

  -- Basic operations
  { "sr", "^{2}", "mA" },
  { "cb", "^{3}", "mA" },
  { "rd", "^{$0}$1", "mA", description = "Raise to (D)the power of" },
  { "_", "_{$0}$1", "mA" },
  { "sts", "_\\text{$0}", "mA" },
  { "sq", "\\sqrt{ $0 }$1", "mA" },
  { [=[(\d)rt]=], "\\sqrt[[[0]]]{ $0 }$1", "rmA", description = "Nth RooT" },
  { "//", "\\frac{$0}{$1}$2", "mA" },
  { [=[\bee]=], "e^{ $0 }$1", "rmA" },
  { "invs", "^{-1}", "mA" },

  { [=[([^\\])(exp|log|ln)]=], "[[0]]\\[[1]]", "rmA" },
  { "conj", "^{*}", "mA" },
  { "Re", "\\mathrm{Re}", "mA" },
  { "Im", "\\mathrm{Im}", "mA" },
  { "bf", "\\mathbf{$0}", "mA" },
  { "rm", "\\mathrm{$0}$1", "mA" },

  -- Linear algebra
  { [=[([^\\])(det)]=], "[[0]]\\[[1]]", "rmA" },
  { "trace", "\\mathrm{Tr}", "mA" },

  -- More operations
  { "([a-zA-Z])hat", "\\hat{[[0]]}", "rmA" },
  { "([a-zA-Z])bar", "\\bar{[[0]]}", "rmA" },
  { "([a-zA-Z])dot", "\\dot{[[0]]}", "rmA", priority = -1 },
  { "([a-zA-Z])ddot", "\\ddot{[[0]]}", "rmA", priority = 1 },
  { "([a-zA-Z])tilde", "\\tilde{[[0]]}", "rmA" },
  { "([a-zA-Z])und", "\\underline{[[0]]}", "rmA" },
  { "([a-zA-Z])vec", "\\vec{[[0]]}", "rmA" },
  { "([a-zA-Z]),\\.", "\\mathbf{[[0]]}", "rmA" },
  { "([a-zA-Z])\\.,", "\\mathbf{[[0]]}", "rmA" },
  { "\\\\(${GREEK}),\\.", "\\boldsymbol{\\[[0]]}", "rmA" },
  { "\\\\(${GREEK})\\.,", "\\boldsymbol{\\[[0]]}", "rmA" },

  { "hat", "\\hat{$0}$1", "mA" },
  { "bar", "\\bar{$0}$1", "mA" },
  { "dot", "\\dot{$0}$1", "mA", priority = -1 },
  { "ddot", "\\ddot{$0}$1", "mA" },
  { "cdot", "\\cdot", "mA" },
  { "tilde", "\\tilde{$0}$1", "mA" },
  { "und", "\\underline{$0}$1", "mA" },
  { "vec", "\\vec{$0}$1", "mA" },
  { "pmod", "\\pmod{${0:n}}$1", "mA", description = "Parenthesized modulo (\\pmod{n})" },

  -- Auto letter subscript and add space after other macros
  -- - x3 -> x_{3}
  -- - \alpha3 -> \alpha_{3}
  -- - \leq3 -> \leq 3
  {
    [=[(\\?)([A-Za-z]+)(\d)]=],
    function(c)
      if c[1] ~= "\\" then return c[2] .. "_{" .. c[3] .. "}" end
      if suite.greek[c[2]] then return "\\" .. c[2] .. "_{" .. c[3] .. "}" end
      return "\\" .. c[2] .. " " .. c[3]
    end,
    "rmA",
    priority = -1,
    description = "Auto letter subscript for variables and greek letters, add space after other macros",
  },
  -- x_{3}4 -> x_{34}, \alpha_{3}4 -> \alpha_{34}
  { "(\\\\${GREEK}|[A-Za-z])_{(\\d+)}(\\d)", "[[0]]_{[[1]][[2]]}", "rmA", priority = -1,
    description = "Combine subscripts for variables and greek letters" },
  -- \dot{x}3 -> \dot{x}_{3}, \dot{\alpha}3 -> \dot{\alpha}_{3}
  -- \dot{x}_{3}4 -> \dot{x}_{34}
  { "\\\\(${ACCENT})\\{(\\\\${GREEK}|[A-Za-z])\\}(?:_\\{(\\d+)\\})?(\\d)", "\\[[0]]{[[1]]}_{[[2]][[3]]}", "rmA", priority = -1 },
  -- \dot{\vec{a}}3 -> \dot{\vec{a}}_{3}
  -- \dot{\vec{a}}_{3}4 -> \dot{\vec{a}}_{34}
  { "\\\\(${ACCENT})\\{\\\\(${ACCENT})\\{(\\\\${GREEK}|[A-Za-z])\\}\\}(?:_\\{(\\d+)\\})?(\\d)",
    "\\[[0]]{\\[[1]]{[[2]]}}_{[[3]][[4]]}", "rmA", priority = -1 },

  { "xnn", "x_{n}", "mA" },
  { "\\xii", "x_{i}", "mA", priority = 1 },
  { "xjj", "x_{j}", "mA" },
  { "xp1", "x_{n+1}", "mA" },
  { "ynn", "y_{n}", "mA" },
  { "yii", "y_{i}", "mA" },
  { "yjj", "y_{j}", "mA" },

  -- Symbols
  { "ooo", "\\infty", "mA" },
  { "sum", "\\sum", "mA" },
  { "prod", "\\prod", "mA" },
  { "\\sum", "\\sum_{${0:i}=${1:1}}^{${2:N}} $3", "m" },
  { "\\prod", "\\prod_{${0:i}=${1:1}}^{${2:N}} $3", "m" },
  { "lim", "\\lim_{ ${0:n} \\to ${1:\\infty} } $2", "mA" },
  { "+-", "\\pm", "mA" },
  { "-+", "\\mp", "mA" },
  { "...", "\\dots", "mA" },
  { "nabl", "\\nabla", "mA" },
  { "xx", "\\times", "mA" },
  { "**", "\\cdot", "mA" },
  { "para", "\\parallel", "mA" },
  { "deg", "^{\\circ}", "mA", description = "Degree sign (LaTeX Suite's \\degree needs the gensymb package)" },

  { "===", "\\equiv", "mA" },
  { "!=", "\\neq", "mA" },
  { ">=", "\\geq", "mA" },
  { "<=", "\\leq", "mA" },
  { ">>", "\\gg", "mA" },
  { "<<", "\\ll", "mA" },
  { "simm", "\\sim", "mA" },
  { "sim=", "\\simeq", "mA" },
  { "prop", "\\propto", "mA" },

  { "<->", "\\leftrightarrow ", "mA" },
  { "->", "\\to", "mA" },
  { "!>", "\\mapsto", "mA" },
  { "=>", "\\implies", "mA" },
  { "=<", "\\impliedby", "mA" },

  { "and", "\\cap", "wmA" },
  { "orr", "\\cup", "mA" },
  { "inn", "\\in", "mA" },
  { "notin", "\\not\\in", "mA" },
  { "\\\\\\", "\\setminus", "mA" },
  { "sub=", "\\subseteq", "mA" },
  { "sup=", "\\supseteq", "mA" },
  { "eset", "\\emptyset", "mA" },
  { "set", "\\{ $0 \\}$1", "wmA" },
  { [=[(n?)e\\xi sts]=], "\\[[0]]exists", "rmA", priority = 1 },

  { "LL", "\\mathcal{L}", "mA" },
  { "HH", "\\mathcal{H}", "mA" },
  { "CC", "\\mathbb{C}", "mA" },
  { "RR", "\\mathbb{R}", "mA" },
  { "ZZ", "\\mathbb{Z}", "mA" },
  { "NN", "\\mathbb{N}", "mA" },
  { "QQ", "\\mathbb{Q}", "mA" },

  -- Handle spaces and backslashes
  { "([^\\\\])(${GREEK})", "[[0]]\\[[1]]", "rmA", description = "Add backslash before Greek letters" },
  { "([^\\\\])(${SYMBOL})", "[[0]]\\[[1]]", "rmA", description = "Add backslash before symbols" },

  { "\\\\(${GREEK}|${SYMBOL}) sr", "\\[[0]]^{2}", "rmA" },
  { "\\\\(${GREEK}|${SYMBOL}) cb", "\\[[0]]^{3}", "rmA" },
  { "\\\\(${GREEK}|${SYMBOL}) rd", "\\[[0]]^{$0}$1", "rmA" },
  { "\\\\(${GREEK}) hat", "\\hat{\\[[0]]}", "rmA" },
  { "\\\\(${GREEK}) dot", "\\dot{\\[[0]]}", "rmA" },
  { "\\\\(${GREEK}) bar", "\\bar{\\[[0]]}", "rmA" },
  { "\\\\(${GREEK}) vec", "\\vec{\\[[0]]}", "rmA" },
  { "\\\\(${GREEK}) tilde", "\\tilde{\\[[0]]}", "rmA" },
  { "\\\\(${GREEK}) und", "\\underline{\\[[0]]}", "rmA" },

  -- Derivatives and integrals
  { "par", "\\frac{ \\partial ${0:y} }{ \\partial ${1:x} } $2", "m" },
  { [=[par([0-9])]=], "\\frac{ \\partial^{[[0]]} ${0:y} }{ \\partial ${1:x}^{[[0]]} } $2", "rmA" },
  { [=[parn]=], "\\frac{ \\partial^{${0:n}} ${1:y} }{ \\partial ${2:x}^{${0:n}} } $2", "rmA" },
  { [=[pa([A-Za-z])([A-Za-z])]=], "\\frac{ \\partial [[0]] }{ \\partial [[1]] } ", "rm" },
  { "ddt", "\\frac{d}{dt} ", "mA" },

  { [=[([^\\])int]=], "[[0]]\\int", "rmA", priority = -1 },
  { "\\int", "\\int $0 \\, d${1:x} $2", "m" },
  { "dint", "\\int_{${0:0}}^{${1:1}} $2 \\, d${3:x} $4", "mA", description = "Definite integral" },
  { "oint", "\\oint", "mA" },
  { "iint", "\\iint", "mA" },
  { "iiint", "\\iiint", "mA" },
  { "oinf", "\\int_{0}^{\\infty} $0 \\, d${1:x} $2", "mA" },
  { "infi", "\\int_{-\\infty}^{\\infty} $0 \\, d${1:x} $2", "mA" },

  -- Trigonometry
  { [=[([^\\])(arcsin|sin|arccos|cos|arctan|tan|csc|sec|cot)]=], "[[0]]\\[[1]]", "rmA",
    description = "Add backslash before trig funcs" },
  { [=[(arccsc|arcsec|arccot)]=], "\\operatorname{[[0]]}$0", "rmA", priority = 1,
    description = "Inverse trig functions, Are not built-in MathJax functions" },

  -- Visual operations (select, <Tab>, then type the letter)
  { "U", "\\underbrace{ ${VISUAL} }_{ $0 }", "mv" },
  { "O", "\\overbrace{ ${VISUAL} }^{ $0 }", "mv" },
  { "B", "\\underset{ $0 }{ ${VISUAL} }", "mv" },
  { "C", "\\cancel{ ${VISUAL} }", "mv" },
  { "K", "\\cancelto{ $0 }{ ${VISUAL} }", "mv" },
  { "S", "\\sqrt{ ${VISUAL} }", "mv" },

  -- Physics
  { "kbt", "k_{B}T", "mA" },
  { "msun", "M_{\\odot}", "mA" },

  -- Quantum mechanics
  { "dag", "^{\\dagger}", "mA" },
  { "o+", "\\oplus ", "mA" },
  { "ox", "\\otimes ", "wmA" },
  { "bra", "\\bra{$0} $1", "mA" },
  { "ket", "\\ket{$0} $1", "mA" },
  { "brk", "\\braket{ $0 | $1 } $2", "mA" },
  { "outer", "\\ket{${0:\\psi}} \\bra{${0:\\psi}} $1", "mA" },

  -- Chemistry
  { "pu", "\\pu{ $0 }", "mA" },
  { "cee", "\\ce{ $0 }", "mA" },
  { "he4", "{}^{4}_{2}He ", "mA" },
  { "he3", "{}^{3}_{2}He ", "mA" },
  { "iso", "{}^{${0:4}}_{${1:2}}${2:He}", "mA" },

  -- Environments
  { [=[([pbBvV]mat)]=], "\\begin{[[0]]rix}\n$0\n\\end{[[0]]rix}", "rMA", description = "Matrix environments with new lines" },
  { [=[(matrix|cases|array)]=], "\\begin{[[0]]}\n$0\n\\end{[[0]]}", "rMA",
    description = "Miscellaneous environments with new lines" },
  { "align", "\\begin{aligned}\n$0\n\\end{aligned}", "MA" },
  { [=[([pbBvV]mat)]=], "\\begin{[[0]]rix}$0\\end{[[0]]rix}", "rnA" },
  { [=[(matrix|cases|array)]=], "\\begin{[[0]]}$0\\end{[[0]]}", "rnA" },
  { "align", "\\begin{aligned}$0\\end{aligned}", "nA" },

  -- Brackets
  { "avg", "\\langle $0 \\rangle $1", "mA" },
  { "norm", "\\lvert $0 \\rvert $1", "mA", priority = 1 },
  { "Norm", "\\lVert $0 \\rVert $1", "mA", priority = 1 },
  { "ceil", "\\lceil $0 \\rceil $1", "mA" },
  { "floor", "\\lfloor $0 \\rfloor $1", "mA" },
  { "mod", "|$0|$1", "mA" },
  { "(", "(${VISUAL})", "mv" },
  { "[", "[${VISUAL}]", "mv" },
  { "{", "{${VISUAL}}", "mv" },
  { "(", "($0)$1", "mA" },
  { "{", "{$0}$1", "mA" },
  { "[", "[$0]$1", "mA" },
  { "lr(", "\\left( $0 \\right) $1", "mA" },
  { "lr{", "\\left\\{ $0 \\right\\} $1", "mA" },
  { "lr[", "\\left[ $0 \\right] $1", "mA" },
  { "lr|", "\\left| $0 \\right| $1", "mA" },
  { "lra", "\\left< $0 \\right> $1", "mA" },

  -- Add space after macros if not part of another macro: \leqa -> \leq a (while the text is still the start of a
  -- known macro, the other autosnippets wait, see latex_suite.lua)
  {
    [=[(\\[A-Za-z]{2,})]=],
    function(c) return c[1]:sub(1, -2) .. " " .. c[1]:sub(-1) end,
    "rmA",
    priority = 3,
    while_typing_macro = true,
    condition = function(_, matched) return not suite.is_macro_prefix(matched) end,
    description = "Insert space after macros if not part of another macro",
  },

  -- Snippet replacements can have placeholders.
  { "tayl", "${0:f}(${1:x} + ${2:h}) = ${0:f}(${1:x}) + ${0:f}'(${1:x})${2:h} + ${0:f}''(${1:x}) \\frac{${2:h}^{2}}{2!} + \\dots$3",
    "mA", description = "Taylor expansion" },

  {
    [=[iden(\d)]=],
    function(c)
      local n, rows = tonumber(c[1]), {}
      for row = 1, n do
        local cells = {}
        for col = 1, n do
          cells[col] = row == col and "1" or "0"
        end
        rows[row] = table.concat(cells, " & ")
      end
      return "\\begin{pmatrix}\n" .. table.concat(rows, " \\\\\n") .. "\n\\end{pmatrix}"
    end,
    "rmA",
    description = "N x N identity matrix",
  },

  -- ===== ossu-course-builder additions (typing-only math workflow) =====
  -- Letter triggers that are also the start of a LaTeX command use the ([^\\A-Za-z{])xyz regex form
  -- (like the default `beg` snippet) so typing e.g. \angle or \dfrac by hand doesn't misfire.

  -- step-by-step work (inside \[ … \])
  { [=[([^\\A-Za-z{])ali]=], "[[0]]\\begin{aligned}\n$0 &= $1 && \\text{$2}\n\\end{aligned}", "rMA", priority = 1,
    description = "aligned steps block" },
  { "stp", " \\\\\n&= $0 && \\text{$1}", "MA", description = "next aligned step (ends the current line)" },
  { "bx", "\\boxed{$0}$1", "mA", description = "boxed final answer" },
  { "tx", "\\text{$0}$1", "mA", description = "text inside math" },

  -- algebra
  { [=[([^\\A-Za-z{])dfr]=], "[[0]]\\dfrac{$0}{$1}$2", "rmA", description = "display-size fraction" },
  { [=[([^\\A-Za-z{])sys]=], "[[0]]\\begin{cases} $0 \\\\ $1 \\end{cases} $2", "rmA", description = "system of equations" },
  { [=[([^\\A-Za-z{])abs]=], "[[0]]\\lvert $0 \\rvert $1", "rmA", description = "absolute value" },

  -- geometry / trig
  { [=[([^\\A-Za-z{])ang]=], "[[0]]\\angle ", "rmA", description = "angle" },
  { [=[([^\\A-Za-z{])tri]=], "[[0]]\\triangle ", "rmA", description = "triangle" },
  { [=[([^\\A-Za-z{])cong]=], "[[0]]\\cong ", "rmA", description = "congruent" },
  { [=[([^\\A-Za-z{])seg]=], "[[0]]\\overline{$0}$1", "rmA", description = "segment AB" },

  -- outside math: note scaffolding (type prob then Tab)
  { "prob",
    "\\subsection*{Problem $0}\n\\textbf{Given:} $$1$\n\n\\[\n\\begin{aligned}\n$2 &= $3 && \\text{$4}\n\\end{aligned}\n\\]\n\n\\textbf{Answer:} $\\boxed{$5}$ \\quad \\textbf{Key:} $6",
    "tw", description = "Problem block" },
}
-- stylua: ignore end

table.insert(autosnippets, suite.autofraction())

-- text-mode document snippets
vim.list_extend(autosnippets, {
  s(
    { trig = "ali", condition = function(...) return in_text() and line_begin(...) end },
    fmta("\\begin{align*}\n\t<>\n\\end{align*}", { i(1) })
  ),
})

vim.list_extend(snippets, {
  s(
    { trig = "beg", condition = function(...) return in_text() and line_begin(...) end },
    fmta("\\begin{<>}\n\t<>\n\\end{<>}", { i(1), i(0), rep(1) })
  ),
  s(
    { trig = "template", condition = line_begin },
    fmta(
      [[
\documentclass[11pt]{article}
\usepackage[margin=1in]{geometry}
\usepackage{amsmath, amssymb, amsthm, mathtools}

\newtheorem{theorem}{Theorem}
\newtheorem{definition}{Definition}

\title{<>}
\author{<>}
\date{\today}

\begin{document}
\maketitle

<>

\end{document}
]],
      { i(1, "Notes"), i(2), i(0) }
    )
  ),
  s({ trig = "thm", condition = line_begin }, fmta("\\begin{theorem}\n\t<>\n\\end{theorem}", { i(1) })),
  s({ trig = "def", condition = line_begin }, fmta("\\begin{definition}\n\t<>\n\\end{definition}", { i(1) })),
  s({ trig = "prf", condition = line_begin }, fmta("\\begin{proof}\n\t<>\n\\end{proof}", { i(1) })),
})

return snippets, autosnippets
