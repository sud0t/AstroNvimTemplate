-- precognition to help with my nvim motions: off at startup, <Leader>ue turns it on and off (see astrocore.lua).
-- Loaded by that key (its :Precognition command), so it costs nothing until it is wanted.

---@type LazySpec
return {
  "tris203/precognition.nvim",
  cmd = "Precognition",
  opts = {
    startVisible = false, -- the first <Leader>ue loads it hidden and then toggles it on
    showBlankVirtLine = false,
    gutterHints = {
      G = { text = "G", prio = 0 },
      gg = { text = "gg", prio = 0 },
      PrevParagraph = { text = "{", prio = 8 },
      NextParagraph = { text = "}", prio = 8 },
    },
  },
}
