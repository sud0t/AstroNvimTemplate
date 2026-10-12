-- LaTeX snippets for fast math notes (loaded by LuaSnip's lua loader, autosnippets enabled in plugins/latex.lua)
-- Autosnippets expand as soon as the trigger is typed, math ones only inside a math zone (vimtex syntax).
-- Text:  mk -> $..$   dm -> \[..\]   ali -> align*   beg -> environment   template -> notes preamble
-- Math:  ff -> \frac   sr -> ^2   td -> ^{}   __ -> _{}   x1 -> x_1   x_12 -> x_{12}   sq -> \sqrt
--        ;a -> \alpha (;A -> \Alpha style capitals where they exist)   RR -> \mathbb{R}   xhat/xbar/xvec
--        sum/prod/int/lim with bounds   -> => <= >= != ~~ xx ** ooo ...   lr( lr[ lr|   pmat   case   tt

local ls = require "luasnip"
local s, t, i, f = ls.snippet, ls.text_node, ls.insert_node, ls.function_node
local fmta = require("luasnip.extras.fmt").fmta
local rep = require("luasnip.extras").rep
local line_begin = require("luasnip.extras.expand_conditions").line_begin

local function in_math() return vim.fn["vimtex#syntax#in_mathzone"]() == 1 end
local function in_text() return not in_math() end

-- math zone, and not right after a backslash so typing `\sum` or `\int` by hand doesn't expand again
local function math_word(line_to_cursor, trigger)
  return in_math() and line_to_cursor:sub(-#trigger - 1, -#trigger - 1) ~= "\\"
end

-- postfix/regex triggers: the matched letter must stand on its own, so `\cdot` or `\log2` don't turn into snippets
local function math_postfix(line_to_cursor, trigger)
  return in_math() and not line_to_cursor:sub(-#trigger - 1, -#trigger - 1):match "[%a\\]"
end

local function capture(n)
  return f(function(_, snip) return snip.captures[n] end)
end

-- math autosnippet that replaces the trigger with plain text
local function sym(trig, text) return s({ trig = trig, wordTrig = false, condition = math_word }, t(text)) end

local autosnippets = {
  -- entering math
  s({ trig = "mk", condition = in_text }, fmta("$<>$", { i(1) })),
  s({ trig = "dm", condition = in_text }, fmta("\\[\n\t<>\n\\]", { i(1) })),
  s(
    { trig = "ali", condition = function(...) return in_text() and line_begin(...) end },
    fmta("\\begin{align*}\n\t<>\n\\end{align*}", { i(1) })
  ),

  -- fractions, scripts, roots
  s({ trig = "ff", condition = math_word }, fmta("\\frac{<>}{<>}", { i(1), i(2) })),
  s({ trig = "//", wordTrig = false, condition = math_word }, fmta("\\frac{<>}{<>}", { i(1), i(2) })),
  sym("sr", "^2"),
  sym("cb", "^3"),
  sym("invs", "^{-1}"),
  s({ trig = "td", wordTrig = false, condition = math_word }, fmta("^{<>}", { i(1) })),
  s({ trig = "__", wordTrig = false, condition = math_word }, fmta("_{<>}", { i(1) })),
  s({ trig = "sq", wordTrig = false, condition = math_word }, fmta("\\sqrt{<>}", { i(1) })),
  -- x1 -> x_1, x_12 -> x_{12}
  s({ trig = "(%a)(%d)", trigEngine = "pattern", wordTrig = false, condition = math_postfix }, { capture(1), t "_", capture(2) }),
  s(
    { trig = "(%a)_(%d%d)", trigEngine = "pattern", wordTrig = false, condition = math_postfix },
    { capture(1), t "_{", capture(2), t "}" }
  ),

  -- decorations on the previous letter: xhat -> \hat{x}
  s({ trig = "(%a)hat", trigEngine = "pattern", wordTrig = false, condition = math_postfix }, { t "\\hat{", capture(1), t "}" }),
  s({ trig = "(%a)bar", trigEngine = "pattern", wordTrig = false, condition = math_postfix }, { t "\\overline{", capture(1), t "}" }),
  s({ trig = "(%a)vec", trigEngine = "pattern", wordTrig = false, condition = math_postfix }, { t "\\vec{", capture(1), t "}" }),
  s({ trig = "(%a)dot", trigEngine = "pattern", wordTrig = false, condition = math_postfix }, { t "\\dot{", capture(1), t "}" }),

  -- big operators
  s({ trig = "sum", condition = math_word }, fmta("\\sum_{<>}^{<>} ", { i(1, "i=1"), i(2, "n") })),
  s({ trig = "prod", condition = math_word }, fmta("\\prod_{<>}^{<>} ", { i(1, "i=1"), i(2, "n") })),
  s({ trig = "int", condition = math_word }, fmta("\\int_{<>}^{<>} <> \\, d<>", { i(1, "a"), i(2, "b"), i(3), i(4, "x") })),
  s({ trig = "lim", condition = math_word }, fmta("\\lim_{<> \\to <>} ", { i(1, "n"), i(2, "\\infty") })),
  s(
    { trig = "pd", condition = math_word },
    fmta("\\frac{\\partial <>}{\\partial <>}", { i(1), i(2) })
  ),
  s({ trig = "dv", condition = math_word }, fmta("\\frac{d <>}{d <>}", { i(1), i(2, "x") })),

  -- delimiters
  s({ trig = "lr(", wordTrig = false, condition = math_word }, fmta("\\left( <> \\right)", { i(1) })),
  s({ trig = "lr[", wordTrig = false, condition = math_word }, fmta("\\left[ <> \\right]", { i(1) })),
  s({ trig = "lr{", wordTrig = false, condition = math_word }, fmta("\\left\\{ <> \\right\\}", { i(1) })),
  s({ trig = "lr|", wordTrig = false, condition = math_word }, fmta("\\left| <> \\right|", { i(1) })),
  s({ trig = "norm", condition = math_word }, fmta("\\left\\| <> \\right\\|", { i(1) })),

  -- relations, arrows, operators
  sym("->", "\\to "),
  sym("=>", "\\implies "),
  sym("iff", "\\iff "),
  sym("<=", "\\le "),
  sym(">=", "\\ge "),
  sym("!=", "\\neq "),
  sym("~~", "\\approx "),
  sym("xx", "\\times "),
  sym("**", "\\cdot "),
  sym("ooo", "\\infty"),
  sym("...", "\\dots "),
  sym("inn", "\\in "),
  sym("notin", "\\notin "),
  sym("sub", "\\subseteq "),
  sym("cup", "\\cup "),
  sym("cap", "\\cap "),
  sym("EE", "\\exists "),
  sym("AA", "\\forall "),
  sym("nabl", "\\nabla "),
  sym("pm", "\\pm "),

  -- number sets
  sym("RR", "\\mathbb{R}"),
  sym("NN", "\\mathbb{N}"),
  sym("ZZ", "\\mathbb{Z}"),
  sym("QQ", "\\mathbb{Q}"),
  sym("CC", "\\mathbb{C}"),

  -- text, matrices, cases
  s({ trig = "tt", condition = math_word }, fmta("\\text{<>}", { i(1) })),
  s({ trig = "pmat", condition = math_word }, fmta("\\begin{pmatrix}\n\t<>\n\\end{pmatrix}", { i(1) })),
  s({ trig = "bmat", condition = math_word }, fmta("\\begin{bmatrix}\n\t<>\n\\end{bmatrix}", { i(1) })),
  s({ trig = "case", condition = math_word }, fmta("\\begin{cases}\n\t<>\n\\end{cases}", { i(1) })),
}

-- greek letters: ;a -> \alpha, ;D -> \Delta
local greek = {
  a = "alpha", b = "beta", g = "gamma", G = "Gamma", d = "delta", D = "Delta", e = "epsilon", ve = "varepsilon",
  z = "zeta", h = "eta", t = "theta", T = "Theta", k = "kappa", l = "lambda", L = "Lambda", m = "mu", n = "nu",
  x = "xi", p = "pi", P = "Pi", r = "rho", s = "sigma", S = "Sigma", u = "tau", f = "phi", vf = "varphi",
  F = "Phi", c = "chi", y = "psi", Y = "Psi", w = "omega", W = "Omega",
}
for key, name in pairs(greek) do
  table.insert(autosnippets, s({ trig = ";" .. key, wordTrig = false, condition = in_math }, t("\\" .. name)))
end

local snippets = {
  s(
    { trig = "beg", condition = line_begin },
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
}

return snippets, autosnippets
