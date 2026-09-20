local root = vim.fn.tempname()
vim.fn.mkdir(root .. '/.git', 'p')
vim.fn.writefile({ 'local function answer() return 42 end', 'return answer()' }, root .. '/example.lua')
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/example.lua'))
local buf = vim.api.nvim_get_current_buf()
local client
assert(
  vim.wait(15000, function()
    client = vim.lsp.get_clients({ bufnr = buf, name = 'lua_ls' })[1]
    return client and client.initialized
  end, 50),
  'normal file must lazy-load and initialise Lua LSP'
)
local complete, location
client:request('textDocument/definition', {
  textDocument = { uri = vim.uri_from_bufnr(buf) },
  position = { line = 1, character = 9 },
}, function(err, result)
  assert(not err, vim.inspect(err))
  location, complete = result, true
end, buf)
assert(vim.wait(15000, function()
  return complete
end, 50))
local loc = location[1] or location
assert((loc.range or loc.targetSelectionRange).start.line == 0)
for _, c in ipairs(vim.lsp.get_clients()) do
  c:stop(true)
end
vim.fn.delete(root, 'rf')
io.stdout:write 'PASS normal-file lazy LSP startup and real Lua definition lookup\n'
vim.cmd 'qa!'
