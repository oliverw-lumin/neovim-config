vim.api.nvim_create_autocmd('TextYankPost', {
  desc = 'Highlight when yanking text',
  group = vim.api.nvim_create_augroup('highlight-yank', { clear = true }),
  callback = function()
    vim.highlight.on_yank()
  end,
})

vim.api.nvim_create_autocmd('FileType', {
  pattern = 'markdown',
  group = vim.api.nvim_create_augroup('markdown-settings', { clear = true }),
  callback = function()
    vim.opt_local.wrap = true
    vim.opt_local.linebreak = true
    vim.opt_local.breakindent = true
    vim.opt_local.spell = false
    vim.opt_local.conceallevel = 2
    vim.opt_local.concealcursor = 'i'
  end,
})

local numbergroup = vim.api.nvim_create_augroup('numbertoggle', { clear = true })
vim.api.nvim_create_autocmd({ 'BufEnter', 'FocusGained', 'InsertLeave', 'WinEnter' }, {
  pattern = '*',
  group = numbergroup,
  callback = function()
    if vim.opt.number:get() and vim.api.nvim_get_mode().mode ~= 'i' then
      vim.opt_local.relativenumber = true
    end
  end,
})
vim.api.nvim_create_autocmd({ 'BufLeave', 'FocusLost', 'InsertEnter', 'WinLeave' }, {
  pattern = '*',
  group = numbergroup,
  callback = function()
    if vim.opt.number:get() then
      vim.opt_local.relativenumber = false
    end
  end,
})

-- Quickfix and location lists own their buffers; update the list API only.
vim.api.nvim_create_autocmd('FileType', {
  pattern = 'qf',
  group = vim.api.nvim_create_augroup('quickfix-edit', { clear = true }),
  callback = function(event)
    vim.keymap.set('n', 'dd', function()
      local idx = vim.fn.line '.'
      local location = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].loclist == 1
      local list = location and vim.fn.getloclist(0) or vim.fn.getqflist()
      if idx > #list then
        return
      end
      table.remove(list, idx)
      local info = { items = list, idx = math.min(idx, #list) }
      if location then
        vim.fn.setloclist(0, {}, 'r', info)
      else
        vim.fn.setqflist({}, 'r', info)
      end
    end, { buffer = event.buf, desc = 'Delete list entry' })
  end,
})
