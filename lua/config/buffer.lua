local M = {}
-- Generated files should remain usable without expensive parsing/formatting.
M.max_bytes = 1024 * 1024
M.max_lines = 20000
function M.large(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then
    return true
  end
  if vim.api.nvim_buf_is_loaded(buf) then
    local lines = vim.api.nvim_buf_line_count(buf)
    return lines > M.max_lines or vim.api.nvim_buf_get_offset(buf, lines) > M.max_bytes
  end
  local stat = vim.uv.fs_stat(vim.api.nvim_buf_get_name(buf))
  return stat ~= nil and stat.size > M.max_bytes
end
function M.editable(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == '' and vim.bo[buf].modifiable and not M.large(buf)
end
return M
