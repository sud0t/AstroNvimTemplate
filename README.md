# Neovim configuration

A personal Neovim configuration built on [AstroNvim](https://github.com/AstroNvim/AstroNvim) v6, with lazy.nvim
managing the plugins. It has one user. This README is for that user and for an AI agent that works on the
repository: what the configuration needs, where things are, and how to check a change.

On top of AstroNvim it has language packs from AstroCommunity, Git that is changed only from the file tree,
debugging with nvim-dap-view, Jupyter cells in Python files, a preview of a Markdown buffer as github.com would
show it (`<Leader>gm`, see "Markdown preview"), and AI on `<Leader>A`: actions and a chat with a local model,
Claude or another provider, with the chat's tools in a sandbox. which-key shows the keys, and the header of each
file in lua/plugins/ says what that file changes.

## Install

```sh
git clone https://github.com/sud0t/AstroNvimTemplate.git ~/.config/nvim
nvim
```

Move an existing ~/.config/nvim, ~/.local/share/nvim, ~/.local/state/nvim and ~/.cache/nvim out of the way first.
The first start clones lazy.nvim (init.lua), which installs the plugins at the commits in lazy-lock.json. Mason
then installs the language servers, formatters and debug adapters.

## Requirements

The tests pass on Neovim 0.12.6. AstroNvim v6, which lua/lazy_setup.lua pins, refuses a Neovim older than 0.11.
Linux is assumed: lua/plugins/toggleterm.lua and lua/user/ai/claude_code.lua read /proc. The first start needs
`git`; every other program is needed only by the feature named.

| Program | What calls it |
|---|---|
| `git` | lazy.nvim's first start (init.lua); the file tree's Git keys and the commit window (lua/user/git.lua, lua/user/git_commit.lua) |
| `curl` | every AI request (lua/user/ai/stream.lua) |
| Ollama on localhost:11434 | the local model `qwen3:4b-instruct` of the AI actions and the chat (lua/user/ai/ollama.lua), and `qwen2.5-coder:1.5b-base` of the ghost-text completion (lua/plugins/minuet.lua) |
| `claude` (Claude Code) | Claude through its login: `<Leader>AC` (lua/user/ai/claude_code.lua) and the AI actions (lua/user/ai/claude.lua) |
| `claude-agent-acp` | CodeCompanion chats with Claude through the login; a Mason package that `<Leader>As` offers to install (lua/user/ai/chat.lua) |
| `srt`, `env`, `rg` | the CodeCompanion chat's tools (lua/user/ai/sandbox/checks.lua): a command runs under `srt` and, through `env`, without the variables that are named like secrets, or not at all; `rg` lists what a search would read |
| `secret-tool` | API keys in the system keyring; without it a key lasts for the session (lua/user/ai/keys.lua) |
| `jupytext` | .ipynb notebooks (lua/plugins/jupytext.lua) |
| kitty, ImageMagick, and the Python packages pynvim, jupyter_client and ipykernel | Jupyter cells and their plots (lua/plugins/jupyter.lua) |
| `node` | the debug adapters for JavaScript and Lua (lua/plugins/dap.lua) |
| `rustup` | finding the rust-analyzer of the active toolchain (lua/plugins/rust.lua) |
| `cmark-gfm` | the Markdown preview on `<Leader>gm`; the Arch and Artix package of that name (lua/user/markdown_preview/init.lua) |
| `xdg-open` | `vim.ui.open`: the page of the Markdown preview (lua/user/markdown_preview/init.lua) and the links in the Claude Code window (lua/user/ai/claude_code.lua) |

## Layout

| Path | What is there |
|---|---|
| init.lua | Clones lazy.nvim on the first start, then runs lua/lazy_setup.lua and lua/polish.lua |
| lua/lazy_setup.lua | lazy.nvim's setup: AstroNvim v6, then lua/community.lua, then lua/plugins/ |
| lua/community.lua | The AstroCommunity modules that are imported: language packs, neotest, CodeCompanion, Diffview |
| lua/plugins/ | One spec file per plugin or topic: what this configuration changes in AstroNvim's and the community's plugins, and the plugins it adds |
| lua/polish.lua | Plain Lua that runs after the plugins are set up |
| lua/user/ | This configuration's own modules: Git from the file tree (git.lua, git_prompts.lua, git_commit.lua), Jupyter cells (jupyter.lua), two helpers for windows and keys, ai/ and markdown_preview/ |
| lua/user/ai/ | The AI actions, the chat and its tool sandbox: [docs/ai-modules.md](docs/ai-modules.md) is the map |
| lua/user/markdown_preview/ | The Markdown preview of `<Leader>gm`: "Markdown preview" says what each module does, and "Licence" where github-markdown-dark.css and emoji.json come from |
| srt-ai.json | The rules of the tool sandbox: what the chat's commands and file tools may read and write |
| ai-rules-local.md, ai-rules-cloud.md | Optional, and made from `<Leader>AS`: the instructions that go along with every chat (lua/user/ai/chat.lua) |
| tests/ | run.sh, the shared harness.lua, and one Lua file per test |
| docs/ | The documents listed under "Documentation" |
| lazy-lock.json | The commit of every plugin, as lazy.nvim installed it |
| .stylua.toml, selene.toml, neovim.yml, .luarc.json | The settings of stylua, of selene (neovim.yml declares the `vim` global) and of lua-language-server |
| .gitignore | Keeps nvim.log and, at the root, the names srt denies to commands (.bashrc, .claude and the like) out of the repository |

## Markdown preview

`<Leader>gm` in a Markdown buffer opens a page in the default browser that shows the buffer as github.com would
show it, in GitHub's dark theme. Only Markdown buffers have the key (lua/plugins/markdown.lua). The page shows the
buffer's text as it is, unsaved changes included. Each press writes a new page into Neovim's temporary directory,
which is gone when Neovim exits, and opens it with `vim.ui.open`. What goes wrong is said in a notification titled
"Markdown preview": an error when `cmark-gfm` is missing, fails or does not finish within 10 s, or when nothing
opens the page, and a warning that says why when the colouring of code fails.

The page is made on this machine, by lua/user/markdown_preview/. `cmark-gfm`, the public release of GitHub's
parser, writes the HTML (init.lua). html.lua keeps of it only the tags, attributes and addresses that it lists,
and writes the HTML anew. github.lua then adds what github.com adds: an id on each heading, links into the page
that work whatever their case, task lists, the five alert boxes (`> [!NOTE]` and the like) and the emoji of a name
such as `:tada:`. code.lua colours fenced code in the colour classes of GitHub's stylesheet, with the treesitter
parsers of a second Neovim: nothing inside a Neovim can stop a parser, and a fault in one ends the Neovim it runs
in. That Neovim, started only when a fence names a language, runs colour.lua without configuration and with the
editor's `runtimepath`, so it finds the same parsers and queries, and it gets the same 10 s. page.lua puts around
the result that stylesheet, the rules that github.com's own page has besides it (measured there on 2026-11-25),
and a content security policy.

What a page shows differently from github.com:

- A remote image shows as its alt text, and a `<picture>` shows only its `<img>`, without the variants for dark
  and light.
- An address of a local file is left out, in a link and in an image, when a part of its path ends in .desktop:
  Firefox reads such a file as a link, and goes to the address written in it.
- Maths and Mermaid diagrams stay source text.
- An uploaded video and a permalink to code are plain links.
- The colours of code are close, not exact: about nine characters in ten had GitHub's colour when it was measured.
- A code block has no colours when its language has no installed parser or treesitter gives an error for it, and
  no block has any when the second Neovim gives no answer.
- A heading has no link icon, a code block no copy button, and the page no frame of the repository around it.
- A relative link opens the local file. An address that starts with `/` leads to the root of the file system, not
  of the repository.
- A reference to an issue (`#123`) is not a link.
- A named character reference in an attribute of raw HTML (`alt="caf&eacute;"`) shows as it is written.
- A task list inside a quote shows its `[ ]` as text, not as a box.

Nothing of the text leaves the machine, and the page asks no other machine for anything. An image with a remote
address is left out, and `srcset` and `<source>` are dropped. An image with a relative address is read from the
directory of the Markdown file. The page's content security policy allows no script, frame or form, no style but
the page's own, no image but a local file, and no `<base>` but one that names a file. The comment on addresses in
html.lua says what to change, there and in page.lua, to allow remote images.

What the page does not prevent:

- A link leads where its address says when you click it, to another machine if it names one, and the text of a
  link can say something else than its address.
- A relative link opens whatever local file it names, a .desktop file excepted, as the browser treats a file of
  that kind. An .html or .svg file runs its own script there, which can learn its own path, find out which files
  exist and use the network.
- An image can be any local file that its address names, and a symbolic link in a repository is followed. A
  symbolic link to a .desktop file under another name is one case: only the page's policy keeps the picture from
  the address written in that file, and a click on a link that names it leads there.
- The installed treesitter parsers read the code in a second Neovim that has your rights and is no sandbox: it
  keeps a parser that hangs or aborts from the editor, and nothing else.
- The page is a file that holds the buffer's text, unsaved changes included, until Neovim exits, and it stays in
  the temporary directory after a crash of Neovim.

## Tests and linters

```sh
tests/run.sh                      # every test
tests/run.sh ai_sandbox git_keys  # the tests named: a file in tests/, without .lua
~/.local/share/nvim/mason/bin/stylua --check .
~/.local/share/nvim/mason/bin/selene .
```

tests/run.sh prints the result of each test. It exits with 0, with 1 when a test failed, and with 2 when it could
not run them. Before you run a test or add one:

- The directory of the tree must be named nvim: the tests that run the whole configuration set `$XDG_CONFIG_HOME`
  to its parent. A clone or a work tree anywhere else is fine as long as its last component is nvim.
- tests/run.sh gives each test of the whole configuration data, state and cache directories of its own. The data
  directory has links to your plugins, tools and parsers (~/.local/share/nvim), so the plugins must be installed
  there. The header of tests/run.sh says what still lands in your directories.
- A Neovim started without tests/run.sh, only to check something, has your data directory, and AstroNvim replaces
  the sessions saved there when it exits. Call `whole_config()` of tests/harness.lua first: it switches that off.
- A new test file must be in one of the two lists at the top of tests/run.sh, which otherwise stops with 2. The
  header of tests/harness.lua shows how a test starts and ends. A test that makes no check fails.
- No test reaches a model, a provider, the keyring, the real `srt` or the real `claude`: they are stand-ins, and
  tests/harness.lua fails a test that starts `secret-tool` or `curl` with `vim.system`. The header of a test
  file says what it covers and what is left to check by hand.
- Run `tests/run.sh ai_sandbox ai_sandbox_chat` before you keep an update of CodeCompanion in lazy-lock.json: the
  sandbox wraps functions that are not part of the plugin's API.
- tests/jupyter.lua needs `jupytext`.
- tests/markdown_preview.lua needs `cmark-gfm` and the treesitter parsers of lua, python, bash, json and markdown
  (with markdown_inline). It starts no browser, but the second Neovim that colours code. Run it after an update of
  `cmark-gfm`, or of those parsers or their queries: the pages are made of the HTML that `cmark-gfm` writes, and
  the colours of code are the parsers'.
- stylua and selene are Mason's, and are not on `$PATH` outside Neovim. Run both from the root of the tree: from
  another directory selene does not find selene.toml and reports `vim` as undefined.

## Licence

GNU General Public License, version 3: see [LICENSE](LICENSE).

Three parts of lua/user/markdown_preview/ come from elsewhere:

- github-markdown-dark.css is github-markdown-css 5.9.0, unmodified, under the MIT licence:
  [github-markdown-dark.css.license](lua/user/markdown_preview/github-markdown-dark.css.license) is beside it.
- The icons of the five alert boxes, in github.lua, are paths from GitHub's Octicons, under the MIT licence:
  [octicons.license](lua/user/markdown_preview/octicons.license) is beside github.lua.
- emoji.json has the names that GitHub's `GET /emojis` listed on 2026-11-25, but for GitHub's own pictures
  (`:octocat:`), each with the characters that Unicode's list of emoji gives for it.
