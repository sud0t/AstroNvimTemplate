-- refactoring.nvim. Extract and the debug prints are operators: in normal mode they wait for a motion
-- (`<Leader>re` then `ip`; `_` is the current line), in visual mode they take the selection. The keys are not
-- set in select mode, where a space typed over a snippet placeholder would start them.

local function refactor(name)
  return function() return require("refactoring")[name]() end
end
local function debug_operator(name, suffix)
  return function() return require("refactoring.debug")[name]() .. (suffix or "") end
end

-- Inline variable/function, started from the definition. From a usage, basedpyright answers the references
-- request without the requested position, not without the declaration, so refactoring.nvim deletes the
-- definition and never replaces the usage. Jumping to the definition first works for every language server.
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

local function cleanup_buffer() vim.cmd.normal { "ggVG" .. require("refactoring.debug").cleanup(), bang = true } end

---@type LazySpec
return {
  "ThePrimeagen/refactoring.nvim",
  cmd = "Refactor", -- the mappings load it too, by requiring it
  dependencies = { "lewis6991/async.nvim" },
  opts = {},
  specs = {
    { "AstroNvim/astroui", opts = { icons = { Refactoring = "󰣪" } } },
    {
      "AstroNvim/astrocore",
      opts = function(_, opts)
        local maps = opts.mappings
        local group = { desc = require("astroui").get_icon("Refactoring", 1, true) .. "Refactor" }
        local both = {
          ["<Leader>re"] = { refactor "extract_func", desc = "Extract function", expr = true },
          ["<Leader>rE"] = { refactor "extract_func_to_file", desc = "Extract function to file", expr = true },
          ["<Leader>rv"] = { refactor "extract_var", desc = "Extract variable", expr = true },
          ["<Leader>ri"] = { inline_from_definition "inline_var", desc = "Inline variable" },
          ["<Leader>rI"] = { inline_from_definition "inline_func", desc = "Inline function" },
          ["<Leader>rs"] = { function() require("refactoring").select_refactor() end, desc = "Select refactor" },
          ["<Leader>rP"] = { debug_operator "print_exp", desc = "Debug: print expression", expr = true },
        }
        maps.n["<Leader>r"], maps.x["<Leader>r"] = group, group
        for lhs, map in pairs(both) do
          maps.n[lhs], maps.x[lhs] = map, map
        end
        maps.n["<Leader>rp"] = { debug_operator("print_var", "iw"), desc = "Debug: print variable", expr = true }
        maps.x["<Leader>rp"] = { debug_operator "print_var", desc = "Debug: print variables", expr = true }
        maps.n["<Leader>rl"] = { debug_operator "print_loc", desc = "Debug: print location", expr = true }
        maps.n["<Leader>rc"] = { cleanup_buffer, desc = "Debug: clean up prints (buffer)" }
        maps.x["<Leader>rc"] = { debug_operator "cleanup", desc = "Debug: clean up prints (selection)", expr = true }
      end,
    },
  },
}
