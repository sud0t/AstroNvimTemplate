-- <Leader>tf / <Leader>th / <Leader>tv open the terminal in the directory of the current buffer instead of the
-- directory Neovim was started in (AstroNvim's default). A terminal that already exists comes back as it was and
-- is only `cd`ed to the buffer's directory when its shell is sitting idle at the prompt somewhere else, so a
-- program running in it never gets a `cd` typed into it. `<F7>` still just toggles the last terminal.

local function buffer_dir()
  local name = vim.api.nvim_buf_get_name(0)
  local dir = vim.bo.buftype == "" and name ~= "" and vim.fs.dirname(name) or nil
  -- special buffers (dashboard, explorer, help, the terminal itself): Neovim's working directory
  if not dir or vim.fn.isdirectory(dir) == 0 then return vim.fn.getcwd() end
  return dir
end

local function read_file(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local content = file:read "*a"
  file:close()
  return content
end

local shells = { sh = true, bash = true, zsh = true, fish = true, nu = true, dash = true, ksh = true, tcsh = true }

--- Whether a shell is waiting at its prompt in the terminal, and the directory it is in. Linux only (/proc);
--- elsewhere an existing terminal keeps its directory.
---@param job_id integer
---@return boolean? idle, string? cwd
local function shell_state(job_id)
  local ok, pid = pcall(vim.fn.jobpid, job_id)
  if not ok then return end
  local stat = read_file("/proc/" .. pid .. "/stat")
  if not stat then return end
  -- fields after "(comm)": state ppid pgrp session tty_nr tpgid ...; tpgid is the process group that owns the
  -- terminal. `termopen` runs the shell through `'shell' -c`, so the job's own pid is an outer, non-interactive
  -- shell: look at whatever is in the foreground instead. A shell there is waiting at its prompt.
  local fields = vim.split(stat:match "^.*%)%s*(.*)$" or "", "%s+", { trimempty = true })
  local foreground = tonumber(fields[6])
  if not foreground or foreground <= 0 then return false end
  local comm = (read_file("/proc/" .. foreground .. "/comm") or ""):gsub("%s+$", "")
  local idle = shells[comm] == true or comm == vim.fs.basename(vim.o.shell)
  return idle, vim.uv.fs_readlink("/proc/" .. foreground .. "/cwd")
end

local function same_dir(a, b)
  if not a or not b then return false end
  return (vim.uv.fs_realpath(a) or a) == (vim.uv.fs_realpath(b) or b)
end

---@param direction "float"|"horizontal"|"vertical"
---@param size integer?
local function toggle_in_buffer_dir(direction, size)
  return function()
    local dir = buffer_dir()
    require("toggleterm").toggle(vim.v.count, size, dir, direction) -- a new terminal starts in `dir`
    for _, term in ipairs(require("toggleterm.terminal").get_all()) do
      if term:is_open() and term:is_focused() then
        local idle, cwd = shell_state(term.job_id)
        if idle and not same_dir(cwd, dir) then term:send("cd " .. vim.fn.shellescape(dir)) end
      end
    end
  end
end

---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@type AstroCoreOpts
  opts = {
    mappings = {
      n = {
        ["<Leader>tf"] = { toggle_in_buffer_dir "float", desc = "ToggleTerm float (buffer's directory)" },
        ["<Leader>th"] = {
          toggle_in_buffer_dir("horizontal", 10),
          desc = "ToggleTerm horizontal split (buffer's directory)",
        },
        ["<Leader>tv"] = {
          toggle_in_buffer_dir("vertical", 80),
          desc = "ToggleTerm vertical split (buffer's directory)",
        },
      },
    },
  },
}
