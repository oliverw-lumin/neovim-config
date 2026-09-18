return {
  {
    'mfussenegger/nvim-dap',
    dependencies = {
      'rcarriga/nvim-dap-ui',
      'nvim-neotest/nvim-nio',
      'mason-org/mason.nvim',
      'jay-babu/mason-nvim-dap.nvim',
      'leoluz/nvim-dap-go',
    },
    keys = {
      {
        '<F5>',
        function()
          require('dap').continue()
        end,
        desc = 'Debug start/continue',
      },
      {
        '<F1>',
        function()
          require('dap').step_into()
        end,
        desc = 'Debug step into',
      },
      {
        '<F2>',
        function()
          require('dap').step_over()
        end,
        desc = 'Debug step over',
      },
      {
        '<F3>',
        function()
          require('dap').step_out()
        end,
        desc = 'Debug step out',
      },
      {
        '<leader>bb',
        function()
          require('dap').toggle_breakpoint()
        end,
        desc = 'Toggle breakpoint',
      },
      {
        '<leader>bB',
        function()
          require('dap').set_breakpoint(vim.fn.input 'Breakpoint condition: ')
        end,
        desc = 'Set breakpoint',
      },
      {
        '<F7>',
        function()
          require('dapui').toggle()
        end,
        desc = 'Debug UI',
      },
    },
    config = function()
      require('config.dap').setup()
    end,
  },

  {
    'mfussenegger/nvim-lint',
    event = { 'BufReadPre', 'BufNewFile' },
    config = function()
      local lint = require 'lint'

      -- cppcheck operates per translation unit and can't see cross-TU usage.
      -- Suppress checks that produce false positives in multi-file projects.
      lint.linters.cppcheck.args = vim.list_extend(vim.deepcopy(lint.linters.cppcheck.args), {
        '--suppress=unusedStructMember',
      })

      lint.linters_by_ft = {
        python = { 'ruff' },
        javascript = {},
        typescript = {},
        javascriptreact = {},
        typescriptreact = {},
        lua = { 'selene' },
        c = { 'cppcheck' },
        cpp = { 'cppcheck' },
        go = { 'staticcheck' },
        sh = { 'shellcheck' },
        bash = { 'shellcheck' },
        yaml = { 'yamllint' },
        markdown = {},
      }

      local lint_augroup = vim.api.nvim_create_augroup('lint', { clear = true })
      vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWritePost', 'InsertLeave' }, {
        group = lint_augroup,
        callback = function()
          if vim.bo.modifiable then
            lint.try_lint()
          end
        end,
      })
    end,
  },

  {
    'Civitasv/cmake-tools.nvim',
    lazy = true,
    cmd = {
      'CMakeGenerate',
      'CMakeBuild',
      'CMakeRun',
      'CMakeDebug',
      'CMakeRunTest',
      'CMakeSelectBuildType',
      'CMakeSelectBuildTarget',
      'CMakeSelectLaunchTarget',
    },
    keys = {
      { '<leader>cc', '<cmd>CMakeGenerate<CR>', desc = 'CMake configure' },
      { '<leader>cg', '<cmd>CMakeGenerate<CR>', desc = 'CMake generate' },
      { '<leader>cb', '<cmd>wall<CR><cmd>CMakeBuild<CR>', desc = 'CMake build' },
      { '<leader>cr', '<cmd>wall<CR><cmd>CMakeRun<CR>', desc = 'CMake run' },
      { '<leader>cd', '<cmd>wall<CR><cmd>CMakeDebug<CR>', desc = 'CMake debug' },
      { '<leader>ct', '<cmd>CMakeSelectBuildType<CR>', desc = 'Select build type' },
      { '<leader>cs', '<cmd>CMakeSelectBuildTarget<CR>', desc = 'Select build target' },
      { '<leader>cT', '<cmd>wall<CR><cmd>CMakeRunTest<CR>', desc = 'CMake tests' },
      { '<leader>cl', '<cmd>CMakeSelectLaunchTarget<CR>', desc = 'Select launch target' },
    },
    opts = function()
      return {
        cmake_build_directory = 'build',
        cmake_generate_options = { '-DCMAKE_EXPORT_COMPILE_COMMANDS=1' },
        cmake_build_args = { '-j', tostring(require('config.tasks').jobs()) },
        cmake_executor = { name = 'quickfix', opts = {} },
        cmake_runner = { name = 'terminal' },
        cmake_dap_configuration = {
          name = 'cpp',
          type = 'lldb',
          request = 'launch',
          stopOnEntry = false,
          runInTerminal = true,
          console = 'integratedTerminal',
        },
      }
    end,
  },
}
