# Neovim configuration

A personal Neovim configuration built on [AstroNvim](https://github.com/AstroNvim/AstroNvim) v6, with lazy.nvim
managing the plugins. It has one user. This README is for that user and for an AI agent that works on the
repository: what the configuration needs, where things are, and how to check a change.

On top of AstroNvim it has language packs from AstroCommunity, Git that is changed only from the file tree,
debugging with nvim-dap-view, Jupyter cells in Python files, and AI on `<Leader>A`: actions and a chat with a local
model, Claude or another provider, with the chat's tools in a sandbox. which-key shows the keys, and the header of
each file in lua/plugins/ says what that file changes.

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

## Layout

| Path | What is there |
|---|---|
| init.lua | Clones lazy.nvim on the first start, then runs lua/lazy_setup.lua and lua/polish.lua |
| lua/lazy_setup.lua | lazy.nvim's setup: AstroNvim v6, then lua/community.lua, then lua/plugins/ |
| lua/community.lua | The AstroCommunity modules that are imported: language packs, neotest, CodeCompanion, Diffview |
| lua/plugins/ | One spec file per plugin or topic: what this configuration changes in AstroNvim's and the community's plugins, and the plugins it adds |
| lua/polish.lua | Plain Lua that runs after the plugins are set up |
| lua/user/ | This configuration's own modules: Git from the file tree (git.lua, git_prompts.lua, git_commit.lua), Jupyter cells (jupyter.lua), two helpers for windows and keys, and ai/ |
| lua/user/ai/ | The AI actions, the chat and its tool sandbox: [docs/ai-modules.md](docs/ai-modules.md) is the map |
| srt-ai.json | The rules of the tool sandbox: what the chat's commands and file tools may read and write |
| ai-rules-local.md, ai-rules-cloud.md | Optional, and made from `<Leader>AS`: the instructions that go along with every chat (lua/user/ai/chat.lua) |
| tests/ | run.sh, the shared harness.lua, and one Lua file per test |
| docs/ | The documents listed under "Documentation" |
| lazy-lock.json | The commit of every plugin, as lazy.nvim installed it |
| .stylua.toml, selene.toml, neovim.yml, .luarc.json | The settings of stylua, of selene (neovim.yml declares the `vim` global) and of lua-language-server |
| .gitignore | Keeps nvim.log and, at the root, the names srt denies to commands (.bashrc, .claude and the like) out of the repository |

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
- stylua and selene are Mason's, and are not on `$PATH` outside Neovim. Run both from the root of the tree: from
  another directory selene does not find selene.toml and reports `vim` as undefined.

## Licence

GNU General Public License, version 3: see [LICENSE](LICENSE).
