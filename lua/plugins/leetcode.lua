-- LeetCode inside Neovim. Loaded only by :Leet (not by `nvim leetcode.nvim`), leave with :Leet exit

---@type LazySpec
return {
  "kawre/leetcode.nvim",
  cmd = "Leet",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "MunifTanjim/nui.nvim",
    "folke/snacks.nvim",
  },
  opts = {
    picker = { provider = "snacks-picker" },
    -- without this, :Leet only works in an empty session started as `nvim leetcode.nvim`
    plugins = { non_standalone = true },
  },
}
