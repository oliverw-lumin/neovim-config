local lazy = require 'lazy'
local f5 = vim.fn.maparg('<F5>', 'n', false, true).desc
lazy.load { plugins = { 'cmake-tools.nvim' } }
assert(vim.fn.exists ':CMakeBuild' == 2)
assert(vim.fn.maparg('<F5>', 'n', false, true).desc == f5, 'CMake must not overwrite general debugging')
local dap = require 'dap'
assert(dap.adapters.python and dap.configurations.python and dap.configurations.go, 'missing LLDB must not disable Python/Go')
assert(require('mason-nvim-dap.settings').current.automatic_installation == false)
assert(vim.fn.maparg('<space>c', 'n') == '', 'CMake prefix must not also be a change operator')
assert(vim.fn.maparg('<space>b', 'n') == '', 'buffer prefix must not also toggle breakpoints')
assert(vim.fn.maparg('<space>Y', 'n', false, true).desc == 'Yank absolute file path')
io.stdout:write 'PASS full config, CMake/DAP loading, independent debuggers, unambiguous key prefixes\n'
vim.cmd 'qa!'
