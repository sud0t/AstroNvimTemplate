-- The <Leader>T keys that start a test run or a watch also open neotest's summary. What each key runs stays
-- with the neotest pack (lua/community.lua): its mappings are wrapped here, not written again.
local run_keys = { "t", "d", "f", "p", "Wt", "Wf", "Wp" }

---@type LazySpec
return {
  "AstroNvim/astrocore",
  opts = function(_, opts)
    for _, key in ipairs(run_keys) do
      local lhs = "<Leader>T" .. key
      local map = opts.mappings.n[lhs]
      assert(type(map) == "table" and type(map[1]) == "function", "the neotest pack maps no function to " .. lhs)
      local run = map[1]
      map[1] = function()
        -- The run first: it reads the file and the cursor before it yields, so the summary's split cannot change
        -- what runs. `open()` does nothing when the summary is open, and leaves the focus where it was.
        run()
        require("neotest").summary.open()
      end
    end
  end,
}
