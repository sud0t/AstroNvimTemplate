-- trouble.nvim (imported from AstroCommunity in community.lua): lists of diagnostics, quickfix, todos, ...
-- The community module maps everything under <Leader>x, which is "Close buffer" here (any <Leader>x... mapping
-- would make <Leader>x wait for the which-key timeout), so its mappings move to the <Leader>z lists group.

local moved = { -- community key -> key here
  ["<Leader>xx"] = "<Leader>zx", -- document diagnostics
  ["<Leader>xX"] = "<Leader>zX", -- workspace diagnostics
  ["<Leader>xL"] = "<Leader>zL", -- location list
  ["<Leader>xQ"] = "<Leader>zQ", -- quickfix list
  ["<Leader>xt"] = "<Leader>zt", -- todo comments
  ["<Leader>xT"] = "<Leader>zT", -- TODO/FIX/FIXME only
}

-- The community module's snacks picker integration (<C-t> in a picker sends the results to trouble) reads
-- require("trouble.sources.snacks").actions while snacks is set up at startup, which loaded trouble on every
-- start (~2.5ms). This stand-in provides the same actions and loads the real module only when one is used.
local function lazy_snacks_actions()
  local name = "trouble.sources.snacks"
  local function real(action)
    return function(...)
      package.preload[name], package.loaded[name] = nil, nil
      return require(name).actions[action].action(...)
    end
  end
  package.preload[name] = function()
    return {
      actions = {
        trouble_open = { action = real "trouble_open", desc = "smart-open-with-trouble" },
        trouble_open_selected = { action = real "trouble_open_selected", desc = "open-with-trouble" },
        trouble_open_all = { action = real "trouble_open_all", desc = "open-all-with-trouble" },
      },
    }
  end
end

---@type LazySpec
return {
  "folke/trouble.nvim",
  init = lazy_snacks_actions, -- runs before snacks (a startup plugin) is set up
  specs = {
    {
      "AstroNvim/astrocore",
      opts = function(_, opts)
        local maps = opts.mappings
        for from, to in pairs(moved) do
          if maps.n[from] then
            maps.n[to] = maps.n[from]
            maps.n[from] = nil
          end
        end
      end,
    },
  },
}
