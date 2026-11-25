-- <Leader>gm in a Markdown buffer shows the buffer in the browser as github.com would show it
-- (lua/user/markdown_preview/). The key is among the Git keys of <Leader>g, and in Markdown buffers only.

---@type LazySpec
return {
  "AstroNvim/astrocore",
  opts = function(_, opts)
    opts.autocmds = opts.autocmds or {}
    opts.autocmds.markdown_mappings = {
      {
        event = "FileType",
        pattern = "markdown",
        desc = "The Markdown preview's <Leader> mapping",
        callback = function(ev)
          local function preview() require("user.markdown_preview").open(ev.buf) end
          local maps = { n = { ["<Leader>gm"] = { preview, desc = "Markdown as GitHub shows it" } } }
          require("astrocore").set_mappings(maps, { buffer = ev.buf })
        end,
      },
    }
  end,
}
