-- Work-machine LSP/formatter extras. Home C++ clangd-22 stays preferred when present.

local function capabilities()
  local ok, blink = pcall(require, 'blink.cmp')
  if ok then
    return blink.get_lsp_capabilities()
  end
  return nil
end

local typescript_filetypes = {
  javascript = true,
  javascriptreact = true,
  typescript = true,
  typescriptreact = true,
}

local function local_tsserver(bufnr, root_dir)
  local filename = vim.api.nvim_buf_get_name(bufnr)
  if filename == '' then
    return
  end

  local directory = vim.fs.dirname(filename)
  while directory and (not root_dir or directory == root_dir or vim.startswith(directory, root_dir .. '/')) do
    local candidate = vim.fs.joinpath(directory, 'node_modules', 'typescript', 'lib', 'tsserver.js')
    if (vim.uv or vim.loop).fs_stat(candidate) then
      return candidate
    end

    local parent = vim.fs.dirname(directory)
    if parent == directory then
      break
    end
    directory = parent
  end
end

local function project_tsserver(root_dir)
  local current = vim.api.nvim_get_current_buf()
  if typescript_filetypes[vim.bo[current].filetype] then
    local tsserver = local_tsserver(current, root_dir)
    if tsserver then
      return tsserver
    end
  end

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and typescript_filetypes[vim.bo[bufnr].filetype] then
      local tsserver = local_tsserver(bufnr, root_dir)
      if tsserver then
        return tsserver
      end
    end
  end
end

vim.lsp.config('ts_ls', {
  before_init = function(params, config)
    local tsserver = project_tsserver(config.root_dir)
    if tsserver then
      local init_options = vim.tbl_deep_extend('force', config.init_options or {}, {
        tsserver = { path = tsserver },
      })
      config.init_options = init_options
      params.initializationOptions = init_options
    end
  end,
})

local function package_biome_config(bufnr)
  local project_root = vim.fs.root(bufnr, {
    'package-lock.json',
    'yarn.lock',
    'pnpm-lock.yaml',
    'bun.lockb',
    'bun.lock',
    '.git',
  })
  if not project_root then
    return false
  end

  local filename = vim.api.nvim_buf_get_name(bufnr)
  local config = vim.fs.find({ 'biome.json', 'biome.jsonc' }, {
    path = vim.fs.dirname(filename),
    type = 'file',
    upward = true,
    stop = project_root,
    limit = 1,
  })[1]

  if not config then
    return false
  end

  local package_root = vim.fs.root(bufnr, 'package.json')
  if not package_root then
    return config
  end

  local config_dir = vim.fs.dirname(config)
  if config_dir == project_root and vim.fn.filereadable(project_root .. '/pnpm-workspace.yaml') == 1 then
    return
  end

  if config_dir == package_root or vim.startswith(config_dir, package_root .. '/') then
    return config
  end
end

local function javascript_formatters(bufnr)
  if package_biome_config(bufnr) then
    return { 'biome' }
  end
  return { 'prettier' }
end

vim.api.nvim_create_autocmd('User', {
  pattern = 'VeryLazy',
  callback = function()
    local caps = capabilities()

    vim.lsp.config.gopls = vim.tbl_deep_extend('force', vim.lsp.config.gopls or {}, {
      capabilities = caps,
    })
    vim.lsp.config.tailwindcss = vim.tbl_deep_extend('force', vim.lsp.config.tailwindcss or {}, {
      capabilities = caps,
    })
    local biome = vim.lsp.config.biome or {}
    local biome_root_dir = biome.root_dir
    vim.lsp.config.biome = vim.tbl_deep_extend('force', biome, {
      capabilities = caps,
      root_dir = function(bufnr, on_dir)
        if not package_biome_config(bufnr) then
          return
        end
        if biome_root_dir then
          return biome_root_dir(bufnr, on_dir)
        end
      end,
    })

    local eslint = vim.lsp.config.eslint or {}
    local eslint_root_dir = eslint.root_dir
    vim.lsp.config.eslint = vim.tbl_deep_extend('force', eslint, {
      capabilities = caps,
      root_dir = function(bufnr, on_dir)
        if package_biome_config(bufnr) then
          return
        end
        if eslint_root_dir then
          return eslint_root_dir(bufnr, on_dir)
        end
      end,
    })
    vim.lsp.enable { 'gopls', 'tailwindcss', 'biome', 'eslint' }

    if vim.fn.executable 'clangd-22' == 0 then
      local clangd = vim.fn.exepath 'clangd'
      if clangd ~= '' then
        vim.lsp.config('clangd', {
          capabilities = caps,
          cmd = { clangd, '--clang-tidy=false', '--pch-storage=disk' },
        })
      end
    end

    local ok, conform = pcall(require, 'conform')
    if ok then
      local fts = conform.formatters_by_ft
      fts.go = fts.go or { 'goimports', 'gofumpt' }
      fts.javascript = javascript_formatters
      fts.javascriptreact = javascript_formatters
      fts.typescript = javascript_formatters
      fts.typescriptreact = javascript_formatters
      fts.json = javascript_formatters
      fts.jsonc = javascript_formatters
    end
  end,
})
