-- nvim-autopairs maps its keys in the current buffer when a buffer is entered or gets its filetype, and AstroNvim
-- lets it do so in a listed buffer only: in another one it deletes them. The file tree enters a file before it
-- lists it, so such a file has no pairs until it is left and entered again, and none at all when it had pairs
-- before (the keys are gone, but the buffer still counts as mapped). AstroNvim hides this where it detects the
-- filetype of a new file a second time, which it stops doing after the first file of a git repository. Here the
-- keys are mapped when a buffer becomes listed.

---@type LazySpec
return {
  "windwp/nvim-autopairs",
  config = function(...)
    require "astronvim.plugins.configs.nvim-autopairs"(...)
    vim.api.nvim_create_autocmd("BufAdd", {
      group = vim.api.nvim_create_augroup("autopairs_listed", { clear = true }),
      desc = "Map the autopairs keys in a buffer when it becomes listed",
      callback = function(args)
        -- nvim-autopairs reads the filetype and the listing of the current buffer, whichever buffer it is given,
        -- and `:edit` lists a new file while the old one is still current. (That file gets its keys when it is
        -- entered; a buffer that is listed in the background is the current one here.)
        if args.buf == vim.api.nvim_get_current_buf() then require("nvim-autopairs").force_attach(args.buf) end
      end,
    })
  end,
}
