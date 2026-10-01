-- refactoring.nvim (imported from AstroCommunity in community.lua). Every refactor is an operator: in normal
-- mode it waits for a motion/textobject (`<Leader>re` then `ip`, `_` = current line, ...), in visual mode it
-- uses the selection. The community mappings are replaced: they predate the current refactoring.nvim API,
-- overlap (`<Leader>rb` / `<Leader>rbf` made `rb` wait for the timeout) and were also set in select mode,
-- where typing a space into a snippet placeholder would trigger them.

local function refactor(name, opts)
  return function() return require("refactoring")[name](opts) end
end
local function debug(name, opts, suffix)
  return function() return require("refactoring.debug")[name](opts) .. (suffix or "") end
end

-- Inline variable/function, started from the definition. From a usage, basedpyright answers
-- `textDocument/references` with includeDeclaration = false by leaving out the *requested* position instead of the
-- declaration, so refactoring.nvim deleted the definition but never replaced the usage. Jumping to the definition
-- first (in the same buffer) avoids that and works the same for every language server.
local function inline_from_definition(name)
  return function()
    -- refactoring.nvim only ships the queries inline_func needs for some languages (currently only Lua)
    local refactoring = require "refactoring" -- loads the plugin, and with it its queries
    local lang = vim.treesitter.language.get_lang(vim.bo.filetype) or vim.bo.filetype
    if name == "inline_func" and not vim.treesitter.query.get(lang, "refactor_function_call") then
      return vim.notify(
        "Inline function is not supported for " .. lang,
        vim.log.levels.WARN,
        { title = "refactoring.nvim" }
      )
    end
    if vim.fn.mode():match "^[vV\22]" then vim.cmd.normal { "\27", bang = true } end
    local client = vim.lsp.get_clients({ bufnr = 0, method = "textDocument/definition" })[1]
    if client then
      local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
      local res = client:request_sync("textDocument/definition", params, 2000, 0)
      local loc = res and res.result and (res.result[1] or res.result)
      local uri = loc and (loc.uri or loc.targetUri)
      local range = loc and (loc.range or loc.targetSelectionRange)
      if uri == vim.uri_from_bufnr(0) and range then
        local row = range.start.line
        local line = vim.api.nvim_buf_get_lines(0, row, row + 1, false)[1] or ""
        local ok, col = pcall(vim.str_byteindex, line, client.offset_encoding, range.start.character, false)
        vim.api.nvim_win_set_cursor(0, { row + 1, ok and col or range.start.character })
      end
    end
    vim.cmd.normal { refactoring[name](), bang = true }
  end
end

-- debug print clean-up for the whole buffer (normal mode); in visual mode it cleans up the selection
local function cleanup_buffer()
  vim.cmd.normal { "ggVG" .. require("refactoring.debug").cleanup { restore_view = true }, bang = true }
end

local below = { output_location = "below" }

---@type LazySpec
return {
  "ThePrimeagen/refactoring.nvim",
  event = function() return {} end, -- the mappings and :Refactor load it, no need on every file
  cmd = "Refactor",
  specs = {
    {
      "AstroNvim/astrocore",
      opts = function(_, opts)
        local maps = opts.mappings
        maps.x = maps.x or {}
        for _, mode in ipairs { "n", "x", "v" } do
          for lhs in pairs(maps[mode] or {}) do
            if lhs:match "^<Leader>r" then maps[mode][lhs] = nil end
          end
        end
        local group = { desc = require("astroui").get_icon("Refactoring", 1, true) .. "Refactor" }
        local both = {
          ["<Leader>re"] = { refactor "extract_func", desc = "Extract function", expr = true },
          ["<Leader>rE"] = { refactor "extract_func_to_file", desc = "Extract function to file", expr = true },
          ["<Leader>rv"] = { refactor "extract_var", desc = "Extract variable", expr = true },
          ["<Leader>ri"] = { inline_from_definition "inline_var", desc = "Inline variable" },
          ["<Leader>rI"] = { inline_from_definition "inline_func", desc = "Inline function" },
          ["<Leader>rs"] = { function() require("refactoring").select_refactor() end, desc = "Select refactor" },
          ["<Leader>rP"] = { debug("print_exp", below), desc = "Debug: print expression", expr = true },
        }
        maps.n["<Leader>r"], maps.x["<Leader>r"] = group, group
        for lhs, map in pairs(both) do
          maps.n[lhs], maps.x[lhs] = map, map
        end
        maps.n["<Leader>rp"] = { debug("print_var", below, "iw"), desc = "Debug: print variable", expr = true }
        maps.x["<Leader>rp"] = { debug("print_var", below), desc = "Debug: print variables", expr = true }
        maps.n["<Leader>rl"] = { debug("print_loc", below), desc = "Debug: print location", expr = true }
        maps.n["<Leader>rc"] = { cleanup_buffer, desc = "Debug: clean up prints (buffer)" }
        maps.x["<Leader>rc"] = {
          debug("cleanup", { restore_view = true }),
          desc = "Debug: clean up prints (selection)",
          expr = true,
        }
      end,
    },
  },
}
