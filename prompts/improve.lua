-- Helpers for improve.md: review the visual selection, or the whole buffer when called from normal mode
return {
  code = function(args)
    local ctx = args.context
    if ctx.is_visual and ctx.code then return ctx.code end
    return table.concat(vim.api.nvim_buf_get_lines(ctx.bufnr, 0, -1, false), "\n")
  end,
  scope = function(args)
    local ctx = args.context
    if ctx.is_visual then return ("lines %d-%d of `%s`"):format(ctx.start_line, ctx.end_line, ctx.relative_path) end
    return ("the file `%s`"):format(ctx.relative_path)
  end,
}
