-- What the Neovim that code.lua starts to colour code runs. Its input is JSON: the `runtimepath` of the Neovim
-- that asks, by which this one finds code.lua, the parsers and the queries where that one would, and the `blocks`
-- to draw. Its output is what `draw` makes of them, as JSON.
local asked = vim.json.decode(io.read "*a")
vim.o.runtimepath = asked.runtimepath
io.write(vim.json.encode(require("user.markdown_preview.code").draw(asked.blocks)))
