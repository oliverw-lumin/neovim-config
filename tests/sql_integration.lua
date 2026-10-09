local root = vim.fn.tempname()
local other = vim.fn.tempname()
vim.fn.mkdir(root .. '/.git', 'p')
vim.fn.mkdir(root .. '/queries', 'p')
vim.fn.mkdir(other .. '/.git', 'p')
root = vim.uv.fs_realpath(root)
other = vim.uv.fs_realpath(other)
local ddl = 'CREATE TABLE prod.payments (`customer_id` String, `amount` Int64, `properties.name` Array(String)) ENGINE = MergeTree ORDER BY customer_id;'
vim.fn.writefile({ ddl }, root .. '/schema.sql')
vim.fn.writefile({ 'CREATE TABLE other.private_table (secret String) ENGINE = MergeTree ORDER BY secret;' }, other .. '/schema.sql')

local function open(path, text)
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { text })
  vim.bo.modified = false
  local buf = vim.api.nvim_get_current_buf()
  local client
  assert(
    vim.wait(15000, function()
      client = vim.lsp.get_clients({ bufnr = buf, name = 'sql_schema' })[1]
      return client and client.initialized and client._sql_schema
    end, 20),
    'SQL server must attach and load repository schema'
  )
  return buf, client
end

local function complete(buf, client, text)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  vim.bo[buf].modified = false
  local done, result, error
  client:request('textDocument/completion', {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = 0, character = #text },
  }, function(err, response)
    error, result, done = err, response, true
  end, buf)
  assert(
    vim.wait(5000, function()
      return done
    end, 20),
    'completion timed out'
  )
  assert(not error, vim.inspect(error))
  local items = result.items or result
  for _, item in ipairs(items) do
    item.client_id = client.id
  end
  return require('config.sql').completions({}, items)
end

local function has(items, name)
  for _, item in ipairs(items) do
    if item.insertText == name or item.label == name then
      return true
    end
  end
  return false
end

local buf, client = open(root .. '/queries/value.sql', 'SELECT * FROM ')
assert(client.config.root_dir == root, 'SQL must resolve the repository root')
local tables = complete(buf, client, 'SELECT * FROM ')
assert(has(tables, 'prod.payments'), vim.inspect(tables))
local columns = complete(buf, client, 'SELECT * FROM prod.payments WHERE ')
assert(has(columns, 'customer_id') and has(columns, 'amount'), vim.inspect(columns))
assert(has(columns, '`properties.name`'), 'dotted ClickHouse column names must be quoted')
assert(not client.server_capabilities.documentFormattingProvider, 'do not autoformat SQL with a generic formatter')

local otherbuf, otherclient = open(other .. '/value.sql', 'SELECT * FROM ')
assert(otherclient.id ~= client.id, 'repositories need separate LSP clients')
local otheritems = complete(otherbuf, otherclient, 'SELECT * FROM ')
assert(has(otheritems, 'other.private_table') and not has(otheritems, 'prod.payments'), 'schemas must not leak between repositories')

vim.fn.writefile({ ddl:gsub('`amount` Int64', '`updated_amount` Int64') }, root .. '/schema.sql')
local previous = client._sql_schema
local schema_buf = vim.fn.bufadd(root .. '/schema.sql')
vim.fn.bufload(schema_buf)
vim.api.nvim_exec_autocmds('BufWritePost', { buffer = schema_buf })
assert(
  vim.wait(5000, function()
    return client._sql_schema ~= previous
  end, 20),
  'saving schema.sql must reload metadata'
)
local refreshed = complete(buf, client, 'SELECT * FROM prod.payments WHERE ')
assert(has(refreshed, 'updated_amount') and not has(refreshed, 'amount'), 'completion must reflect saved schema changes')

-- A nested repository with no schema must not inherit its parent's schema.
vim.fn.mkdir(root .. '/nested/.git', 'p')
local nested = vim.fn.bufadd(root .. '/nested/query.sql')
assert(require('config.sql').root(nested) == root .. '/nested')
for _, c in ipairs(vim.lsp.get_clients()) do
  c:stop(true)
end
vim.fn.delete(root, 'rf')
vim.fn.delete(other, 'rf')
io.stdout:write 'PASS SQL LSP startup, table/column completion, quoting, schema refresh and repository isolation\n'
vim.cmd 'qa!'
