-- <Leader>h labels every word on screen; it is a motion too (visual mode, after an operator).
---@type LazySpec
return {
  "smoka7/hop.nvim",
  version = "*",
  lazy = true, -- the first <Leader>h loads it, by requiring it
  opts = {},
  specs = {
    {
      "AstroNvim/astrocore",
      opts = function(_, opts)
        local maps = opts.mappings
        local hop = { function() require("hop").hint_words() end, desc = "Hop to word" }
        maps.n["<Leader>h"], maps.x["<Leader>h"] = hop, hop
        -- after an operator hop takes the character it lands on with it: stop one short of the word
        maps.o["<Leader>h"] = { function() require("hop").hint_words { hint_offset = -1 } end, desc = "Hop to word" }
      end,
    },
  },
}
