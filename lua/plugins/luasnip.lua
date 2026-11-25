---@type LazySpec
return {
  "L3MON4D3/LuaSnip",
  config = function(...)
    require "astronvim.plugins.configs.luasnip"(...)
    -- Reloading a buffer (`:e!`, a file changed on disk) removes the marks of the snippet it was in, but LuaSnip
    -- keeps that snippet active: the next InsertLeave or expansion fails with "Invalid 'end_row'", which can
    -- leave LuaSnip locked until Neovim is restarted.
    vim.api.nvim_create_autocmd("BufReadPost", {
      group = vim.api.nvim_create_augroup("luasnip_buffer_reload", { clear = true }),
      desc = "Forget the snippets of a buffer that was read again",
      callback = function(args)
        local session = require "luasnip.session"
        session.current_nodes[args.buf], session.snippet_roots[args.buf] = nil, nil
      end,
    })
  end,
}
