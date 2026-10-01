-- Rust overrides on top of the AstroCommunity rust pack (community.lua)

---@type LazySpec
return {
  {
    "mrcjkb/rustaceanvim",
    -- the pack's `config` already writes these opts into `vim.g.rustaceanvim`
    opts = function(_, opts)
      opts.server = opts.server or {}
      -- use the rust-analyzer that matches the active rustup toolchain
      opts.server.cmd = function()
        local ra_path = vim.fn.system("rustup which rust-analyzer"):gsub("%s+$", "")
        -- rustup missing / no toolchain: don't hand an error message to the LSP client as the command
        if vim.v.shell_error ~= 0 or ra_path == "" then return { "rust-analyzer" } end
        return { ra_path }
      end
      return opts
    end,
  },
}
