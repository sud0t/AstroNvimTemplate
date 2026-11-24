-- Takes global mappings out of single buffers where they have no use.
local M = {}

--- Shadows the global normal and visual mode mappings that `hides` accepts with no-ops local to `buf`, which
--- which-key leaves out of its popup: the keys do nothing there, and a group left empty drops out of the popup.
--- A key the buffer maps itself is left alone, so calling this again only picks up new global mappings.
---@param buf integer
---@param hides fun(lhs: string): boolean
function M.hide(buf, hides)
  for _, mode in ipairs { "n", "x" } do
    local own = {}
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
      own[map.lhs] = true
    end
    for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
      if not own[map.lhs] and hides(map.lhs) then
        vim.keymap.set(mode, map.lhs, function() end, { buffer = buf, desc = "which_key_ignore" })
      end
    end
  end
end

return M
