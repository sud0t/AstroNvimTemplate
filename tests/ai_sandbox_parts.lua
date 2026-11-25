-- Tests for how the AI chat's tool sandbox is put together (lua/user/ai/sandbox/: init.lua is what other code
-- requires, the other files are its parts). In each file `M` is that file's own table, so a name read from the
-- wrong one is nil and no error: a list of protected names that ends early, a refusal that says "nil". And a
-- part that does not load must not leave a sandbox that is half there. Run them after moving code between
-- those files.
--   tests/run.sh ai_sandbox_parts
-- prints what failed and exits with 1, or "ok". What the rules do is in tests/ai_sandbox.lua.
local uv = vim.uv

local harness = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/harness.lua")
local ok = harness.ok

local repo = vim.fs.dirname(vim.fs.dirname(assert(uv.fs_realpath(debug.getinfo(1, "S").source:sub(2)))))
local dir = repo .. "/lua/user/ai/sandbox"
local facade = "user.ai.sandbox"

-- (the sandbox works out where its files are when it loads: not in the user's directories)
local base = assert(uv.fs_realpath(assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/ai-sandbox-parts-test.XXXXXX"))))
vim.env.XDG_CONFIG_HOME = base .. "/config"
vim.env.XDG_STATE_HOME = base .. "/state"
vim.opt.rtp:prepend(repo)

---------------------------------------------------------------------------------------------------- names

-- per file (`init` is the facade): its lines of code, the fields of `M` it defines, and the parts it requires
-- by the local it gives each
local files, parts = {}, {}
for entry, kind in vim.fs.dir(dir) do
  local name = kind == "file" and entry:match "^(.+)%.lua$"
  if name then
    local file = { code = {}, defines = {}, takes = {} }
    for _, line in ipairs(vim.fn.readfile(dir .. "/" .. entry)) do
      if not line:find "^%s*%-%-" then
        file.code[#file.code + 1] = line
        local field = line:match "^M%.([%a_][%w_]*) =" or line:match "^function M%.([%a_][%w_]*)%("
        if field then file.defines[field] = true end
        local as, part = line:match('^local ([%a_][%w_]*) = require "' .. vim.pesc(facade) .. '%.([%a_]+)"$')
        if as then file.takes[as] = part end
      end
    end
    files[name] = file
    if name ~= "init" then parts[#parts + 1] = name end
  end
end
table.sort(parts)
ok("the sandbox has parts", #parts > 0 and files.init ~= nil, vim.inspect(parts))

local own, others, wrong = 0, 0, {}
for name, file in pairs(files) do
  for _, line in ipairs(file.code) do
    for field in line:gmatch "%f[%w_]M%.([%a_][%w_]*)" do
      own = own + 1
      if not file.defines[field] then
        wrong[#wrong + 1] = ("%s.lua reads M.%s, which it does not define"):format(name, field)
      end
    end
    for as, part in pairs(file.takes) do
      for field in line:gmatch("%f[%w_]" .. as .. "%.([%a_][%w_]*)") do
        others = others + 1
        if not (files[part] and files[part].defines[field]) then
          wrong[#wrong + 1] = ("%s.lua reads %s.%s, which %s.lua does not define"):format(name, as, field, part)
        end
      end
    end
  end
end
table.sort(wrong)
ok(
  "every name a file reads from its own table or from a part's is defined there",
  #wrong == 0 and own > 0 and others > 0,
  ("%s (of its own: %d, of a part: %d)"):format(table.concat(wrong, "\n      "), own, others)
)

----------------------------------------------------------------------------------------------------- load

local function unload()
  for name in pairs(package.loaded) do
    if name == facade or vim.startswith(name, facade .. ".") then package.loaded[name] = nil end
  end
end
for _, part in ipairs(parts) do
  unload()
  local name = facade .. "." .. part
  package.preload[name] = function() error("no " .. part) end
  local loaded, why = pcall(require, facade)
  package.preload[name] = nil
  ok(
    ("the sandbox does not load when %s.lua does not"):format(part),
    not loaded and tostring(why):find("no " .. part, 1, true) ~= nil,
    loaded and "it loaded" or why
  )
end
unload()
local loaded, sandbox = pcall(require, facade)
-- (a lua/user/ai/sandbox.lua that was left behind would be found first, and be what the editor runs)
local source = loaded and type(sandbox.install) == "function" and debug.getinfo(sandbox.install, "S").source
ok("with all of them it loads, from init.lua", source and uv.fs_realpath(source:sub(2)) == dir .. "/init.lua", source)

vim.fn.delete(base, "rf")
harness.report()
