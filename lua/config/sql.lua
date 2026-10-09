local M = {}
local data = vim.fn.stdpath 'data' .. '/sql-schema'
local script = vim.fn.stdpath 'config' .. '/scripts/sql-schema.py'

-- Stop at the nearest Git root (including worktrees), never inherit a different
-- repository's schema. Outside Git, use the nearest schema.sql directory.
function M.root(buf)
  local dir = vim.fs.dirname(vim.api.nvim_buf_get_name(buf))
  return vim.fs.root(dir, '.git') or vim.fs.root(dir, 'schema.sql') or dir
end

function M.refresh(client)
  local path = client.config.root_dir .. '/schema.sql'
  client._schema_generation = (client._schema_generation or 0) + 1
  local generation = client._schema_generation
  local function publish(schema)
    if client:is_stopped() or generation ~= client._schema_generation then
      return
    end
    client._sql_schema = schema
    local files = vim.empty_dict()
    if schema then
      for buf in pairs(client.attached_buffers) do
        files[vim.uri_from_bufnr(buf)] = schema.id
      end
    end
    client:notify('workspace/didChangeConfiguration', {
      settings = { schemas = schema and { schema } or {}, fileSchemas = files },
    })
  end
  if vim.fn.filereadable(path) == 0 then
    publish(nil)
    return
  end
  vim.system({ data .. '/venv/bin/python', script, path }, { text = true, timeout = 10000 }, function(result)
    vim.schedule(function()
      if client:is_stopped() or generation ~= client._schema_generation then
        return
      end
      local ok, schema = pcall(vim.json.decode, result.stdout or '')
      if result.code ~= 0 or not ok then
        publish(nil)
        vim.notify(result.stderr ~= '' and result.stderr or 'Cannot parse ' .. path, vim.log.levels.ERROR)
        return
      end
      publish(schema)
    end)
  end)
end

function M.setup(capabilities)
  vim.lsp.config('sql_schema', {
    cmd = { data .. '/sql-lsp' },
    filetypes = { 'sql' },
    capabilities = capabilities,
    root_dir = function(buf, on_dir)
      if not require('config.buffer').large(buf) then
        on_dir(M.root(buf))
      end
    end,
    get_language_id = function()
      return 'clickhouse'
    end,
    handlers = {
      ['textDocument/publishDiagnostics'] = function(err, result, ctx, config)
        local client = vim.lsp.get_client_by_id(ctx.client_id)
        -- sql-lsp's generic tree-sitter grammar rejects valid ClickHouse DDL.
        -- The root schema is validated separately by our SQLGlot catalog loader.
        if result and client and vim.uri_to_fname(result.uri) == client.config.root_dir .. '/schema.sql' then
          result = vim.tbl_extend('force', result, { diagnostics = {} })
        end
        return vim.lsp.handlers['textDocument/publishDiagnostics'](err, result, ctx, config)
      end,
    },
    on_init = function(client)
      -- A metadata completion server must not format files on save.
      client.server_capabilities.documentFormattingProvider = false
      -- v0.1.3 advertises pull diagnostics but only implements push diagnostics.
      client.server_capabilities.diagnosticProvider = nil
      M.refresh(client)
    end,
    on_attach = function(client, buf)
      if client._sql_schema then
        client:notify('workspace/didChangeConfiguration', {
          settings = { fileSchemas = { [vim.uri_from_bufnr(buf)] = client._sql_schema.id } },
        })
      end
    end,
  })
  vim.lsp.enable 'sql_schema'
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = vim.api.nvim_create_augroup('sql-schema', { clear = true }),
    pattern = 'schema.sql',
    callback = function(event)
      local path = vim.fs.normalize(vim.api.nvim_buf_get_name(event.buf))
      for _, client in ipairs(vim.lsp.get_clients { name = 'sql_schema' }) do
        if path == client.config.root_dir .. '/schema.sql' then
          M.refresh(client)
        end
      end
    end,
  })
  vim.api.nvim_create_user_command('SqlSchemaReload', function()
    for _, client in ipairs(vim.lsp.get_clients { bufnr = 0, name = 'sql_schema' }) do
      M.refresh(client)
    end
  end, { desc = 'Reload the repository-root schema.sql' })
end

-- The server prefixes column display labels with its database name. The local
-- catalog uses fully qualified tables across databases, with no default database.
function M.completions(_, items)
  for _, item in ipairs(items) do
    local client = item.client_id and vim.lsp.get_client_by_id(item.client_id)
    if client and client.name == 'sql_schema' then
      item.label = item.label:gsub('^%.', '')
      if item.kind == vim.lsp.protocol.CompletionItemKind.Field then
        local name = item.insertText
        if name and not name:match '^[%a_][%w_]*$' then
          item.insertText = '`' .. name:gsub('`', '``') .. '`'
        end
      end
    end
  end
  return items
end

return M
