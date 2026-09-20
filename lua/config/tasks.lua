-- Slow commands run outside the UI thread. Captured cwd/argv keep paths safe.
local M = {}
local busy = {}

function M.jobs()
  return vim.uv.available_parallelism and vim.uv.available_parallelism() or math.max(1, #(vim.uv.cpu_info() or {}))
end

function M.run(cmd, cwd, done)
  local key = cwd .. '\0' .. cmd[1]
  if busy[key] then
    vim.notify(cmd[1] .. ' is already running in ' .. cwd, vim.log.levels.WARN)
    return
  end
  busy[key] = true
  vim.notify('Running ' .. cmd[1] .. '…')
  local ok, job = pcall(vim.system, cmd, { cwd = cwd, text = true }, function(result)
    vim.schedule(function()
      busy[key] = nil
      if result.code ~= 0 then
        local output = (result.stdout or '') .. '\n' .. (result.stderr or '')
        local lines = vim.split(output, '\n')
        table.insert(lines, 1, '__NVIM_TASK_CWD__' .. cwd)
        vim.fn.setqflist({}, ' ', { title = table.concat(cmd, ' '), lines = lines, efm = '%D__NVIM_TASK_CWD__%f,' .. vim.o.errorformat })
        vim.cmd 'copen'
        vim.notify(cmd[1] .. ' failed; output is in quickfix', vim.log.levels.ERROR)
      else
        vim.notify(cmd[1] .. ' finished')
        if done then
          done(result)
        end
      end
    end)
  end)
  if not ok then
    busy[key] = nil
    vim.notify(tostring(job), vim.log.levels.ERROR)
  end
  return ok and job or nil
end

local function project(marker)
  local filename = vim.b.review_lsp_path or vim.api.nvim_buf_get_name(0)
  local path = filename ~= '' and not filename:match '^%w+://' and filename or vim.fn.getcwd()
  local root = vim.fs.root(path, marker)
  if not root then
    vim.notify('No ' .. marker .. ' found', vim.log.levels.WARN)
  end
  return root
end

function M.executables(dirs)
  local result, seen = {}, {}
  for _, dir in ipairs(dirs) do
    if vim.fn.isdirectory(dir) == 1 then
      for name in vim.fs.dir(dir) do
        local path = vim.fs.joinpath(dir, name)
        if not seen[path] and vim.fn.isdirectory(path) == 0 and vim.fn.executable(path) == 1 then
          seen[path] = true
          result[#result + 1] = path
        end
      end
    end
  end
  table.sort(result)
  return result
end

local remembered
local function choose_executable(root, callback)
  local state = vim.fn.stdpath 'data' .. '/make_last_exe.json'
  if not remembered then
    remembered = {}
    local ok, lines = pcall(vim.fn.readfile, state)
    if ok then
      local decoded, value = pcall(vim.json.decode, table.concat(lines, '\n'))
      if decoded and type(value) == 'table' then
        remembered = value
      end
    end
  end
  local previous = remembered[root]
  if type(previous) == 'string' and vim.fn.executable(previous) == 1 and vim.fn.isdirectory(previous) == 0 then
    return callback(previous)
  end
  local function selected(path)
    if not path or path == '' then
      return
    end
    path = vim.fn.fnamemodify(path, ':p')
    if vim.fn.executable(path) == 1 and vim.fn.isdirectory(path) == 0 then
      remembered[root] = path
      vim.fn.writefile({ vim.json.encode(remembered) }, state)
    end
    callback(path)
  end
  local candidates = M.executables { root .. '/build', root .. '/build/bin', root }
  if #candidates == 1 then
    return selected(candidates[1])
  end
  if #candidates > 1 then
    return vim.ui.select(candidates, { prompt = 'Executable:' }, selected)
  end
  vim.ui.input({ prompt = 'Executable: ', default = root .. '/', completion = 'file' }, selected)
end

function M.make(action)
  local root = project 'Makefile'
  if not root then
    return
  end
  vim.cmd 'wall'
  M.run({ 'make', '-j' .. M.jobs() }, root, function()
    if not action then
      return
    end
    choose_executable(root, function(exe)
      if not exe then
        return
      end
      if vim.fn.isdirectory(exe) == 1 or vim.fn.executable(exe) ~= 1 then
        return vim.notify('Not an executable: ' .. exe, vim.log.levels.ERROR)
      end
      if action == 'debug' then
        require('dap').run { type = 'lldb', request = 'launch', program = exe, cwd = root, stopOnEntry = false }
      else
        vim.cmd 'botright 15new'
        vim.fn.jobstart({ exe }, { term = true, cwd = root })
        vim.cmd 'startinsert'
      end
    end)
  end)
end

function M.cmake(command)
  local root = project 'CMakeLists.txt'
  if not root then
    return
  end
  -- cmake-tools owns build state by cwd; switch only this tab to the project.
  if vim.fn.getcwd() ~= root then
    vim.cmd('tcd ' .. vim.fn.fnameescape(root))
  end
  vim.cmd 'wall'
  vim.cmd(command)
end

function M.format_project()
  local root = project '.git' or vim.fn.getcwd()
  if vim.fn.executable 'rg' ~= 1 or vim.fn.executable 'clang-format' ~= 1 then
    return vim.notify('Project formatting requires rg and clang-format', vim.log.levels.ERROR)
  end
  vim.cmd 'wall'
  local dirs = {}
  for _, name in ipairs { 'src', 'tools' } do
    if vim.fn.isdirectory(root .. '/' .. name) == 1 then
      dirs[#dirs + 1] = name
    end
  end
  if #dirs == 0 then
    return vim.notify('No src/ or tools/ directory found', vim.log.levels.WARN)
  end
  local cmd = { 'rg', '--files', '-0', '-g', '*.c', '-g', '*.cc', '-g', '*.cpp', '-g', '*.h', '-g', '*.hpp' }
  vim.list_extend(cmd, dirs)
  vim.system(cmd, { cwd = root }, function(result)
    vim.schedule(function()
      if result.code == 1 and result.stdout == '' then
        return vim.notify 'No C/C++ source files found'
      end
      if result.code ~= 0 then
        return vim.notify(result.stderr, vim.log.levels.ERROR)
      end
      local files = vim.split(result.stdout, '\0', { trimempty = true, plain = true })
      -- Batches avoid OS argument-size limits on large projects.
      local index = 1
      local function next_batch()
        if index > #files then
          vim.cmd 'checktime'
          return
        end
        local args = { 'clang-format', '-i', '--' }
        for _ = 1, 100 do
          if not files[index] then
            break
          end
          args[#args + 1] = files[index]
          index = index + 1
        end
        M.run(args, root, next_batch)
      end
      next_batch()
    end)
  end)
end

function M.show_commit()
  local file, line = vim.api.nvim_buf_get_name(0), vim.fn.line '.'
  if vim.bo.buftype ~= '' or file == '' then
    return vim.notify 'Open a working-tree file first'
  end
  local root = vim.fs.root(file, '.git')
  if not root then
    return vim.notify 'Not inside a Git repository'
  end
  vim.system({ 'git', 'blame', '--porcelain', '-L', line .. ',' .. line, '--', file }, { cwd = root, text = true }, function(result)
    vim.schedule(function()
      local commit = result.code == 0 and result.stdout:match '^(%x+)'
      if not commit or commit:match '^0+$' then
        return vim.notify 'No committed change for this line'
      end
      -- Fugitive resolves its repository from the originating file.
      vim.cmd('tabedit ' .. vim.fn.fnameescape(file))
      vim.cmd('G show ' .. commit)
    end)
  end)
end

return M
