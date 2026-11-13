-- hop.nvim: jump to any word on screen. <Leader>h labels every word, typing a label moves the cursor there.
-- Works as a motion too: in visual mode it extends the selection, after an operator (d<Leader>h) it is the target.
-- Loaded on the first press. (<Leader>h was AstroNvim's home screen; :lua Snacks.dashboard() still opens it.)
---@type LazySpec
return {
  "smoka7/hop.nvim",
  version = "*",
  cmd = { "HopWord", "HopLine", "HopChar1", "HopChar2", "HopPattern", "HopAnywhere" },
  opts = {},
  specs = {
    {
      "AstroNvim/astrocore",
      opts = function(_, opts)
        local maps = opts.mappings
        local hop = { function() require("hop").hint_words() end, desc = "Hop to word" }
        for _, mode in ipairs { "n", "x", "o" } do
          maps[mode] = maps[mode] or {}
          maps[mode]["<Leader>h"] = hop
        end
        -- After an operator hop includes the character it lands on (d<Leader>h would take the first letter of the
        -- target word with it): stop one short, so the operator covers everything up to the word.
        maps.o["<Leader>h"] = { function() require("hop").hint_words { hint_offset = -1 } end, desc = "Hop to word" }
      end,
    },
  },
}
