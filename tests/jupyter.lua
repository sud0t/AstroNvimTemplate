-- Notebooks and `# %%` cells inside the whole configuration (lua/plugins/jupytext.lua, lua/plugins/jupyter.lua).
--   tests/run.sh jupyter
-- prints "ok: N checks", or what failed and exits with 1. It needs the jupytext program. Run it after changing
-- either file and after an update of jupytext.nvim, image.nvim or jupytext itself: jupytext.nvim builds the
-- arguments jupytext reads a notebook with, and image.nvim decides which documents it draws in by default.
-- No kernel is started and no image is drawn here: molten and kitty need a check by hand.

local harness = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/harness.lua")
harness.whole_config()
local ok = harness.ok

local dir = vim.fn.tempname()

--- Writes a notebook of one code cell, `x = 1`, with the metadata given, and returns its path.
local function notebook(name, metadata)
  local cell = {
    cell_type = "code",
    source = { "x = 1" },
    metadata = vim.empty_dict(),
    outputs = {},
    execution_count = vim.NIL,
  }
  local path = ("%s/%s.ipynb"):format(dir, name)
  local json = vim.json.encode { cells = { cell }, metadata = metadata, nbformat = 4, nbformat_minor = 4 }
  vim.fn.writefile({ json }, path)
  return path
end

--- The code of the first cell in a notebook file
local function first_cell(path)
  local source = vim.json.decode(table.concat(vim.fn.readfile(path), "\n")).cells[1].source
  return type(source) == "table" and table.concat(source) or source
end

--- Opens a notebook and returns whether the buffer holds its cell as Python, and what it holds or why not.
local function opens_as_cells(path)
  local opened, problem = pcall(vim.cmd.edit, path)
  if not opened then return false, problem end
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  return vim.bo.filetype == "python" and text:find("# %%\nx = 1", 1, true) ~= nil, text
end

--- Whether the current window tints the lines that start a cell
local function tints_cell_markers()
  for _, match in ipairs(vim.fn.getmatches()) do
    if match.pattern:find("# %%", 1, true) then return true end
  end
  return false
end

local run, err = xpcall(function()
  assert(vim.fn.executable "jupytext" == 1, "the jupytext program is not installed")
  vim.fn.mkdir(dir)

  local no_kernel = notebook("no_kernel", { language_info = { name = "python", file_extension = ".py" } })
  ok("a notebook that names no kernel opens as Python cells", opens_as_cells(no_kernel))
  local no_language = notebook("no_language", vim.empty_dict())
  ok("and so does one that names no language either", opens_as_cells(no_language))
  vim.api.nvim_buf_set_lines(0, -2, -1, false, { "x = 2" })
  vim.cmd "silent write"
  ok("which is written back as a notebook", first_cell(no_language) == "x = 2", first_cell(no_language))

  vim.fn.writefile({ "# %% first", "x = 1" }, dir .. "/cells.py")
  vim.cmd.edit(dir .. "/cells.py")
  ok("a Python window tints its cell markers", tints_cell_markers())
  vim.cmd.split()
  ok("and so does a second window on the buffer", tints_cell_markers())
  vim.cmd.new()
  ok("a window on another kind of buffer does not", not tints_cell_markers())

  require("lazy").load { plugins = { "image.nvim" } }
  local draws_in = vim.tbl_filter(
    function(name) return vim.startswith(name, "image/integrations/") end,
    vim.tbl_keys(package.loaded)
  )
  ok("image.nvim draws in no document: molten draws its own images", #draws_in == 0, table.concat(draws_in, " "))
  -- when Neovim exits, image.nvim would write kitty's escape sequence that clears all images to this test's output
  require("image/backends/kitty").clear = function() end

  ok("nothing reported an error", vim.v.errmsg == "", vim.v.errmsg)
end, debug.traceback)

vim.fn.delete(dir, "rf")
harness.finish(run, err)
