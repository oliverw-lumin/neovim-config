-- Shared PR summaries. Requests belong to a repository, not the current tab.
local M = {}
local cache, pending = {}, {}
local fields = table.concat({
  'number',
  'title',
  'state',
  'isDraft',
  'author',
  'baseRefName',
  'headRefName',
  'url',
  'body',
  'labels',
  'reviewDecision',
  'additions',
  'deletions',
  'changedFiles',
  'comments',
  'reviews',
}, ',')

function M.summary(root, number, callback, force)
  local key = root .. '\0' .. number
  local hit = cache[key]
  if not force and hit and vim.uv.now() - hit.time < 60000 then
    callback(nil, hit.data)
    return function() end
  end
  local request = pending[key]
  local listener = { callback = callback }
  if request then
    table.insert(request.listeners, listener)
  else
    request = { listeners = { listener } }
    pending[key] = request
    request.job = vim.system({ 'gh', 'pr', 'view', tostring(number), '--json', fields }, {
      text = true,
      cwd = root,
      timeout = 30000,
    }, function(result)
      vim.schedule(function()
        if pending[key] ~= request then
          return
        end
        pending[key] = nil
        local err, data
        if result.code ~= 0 then
          err = 'gh pr view failed: ' .. (result.stderr or '')
        else
          local ok, decoded = pcall(vim.json.decode, result.stdout)
          if ok and type(decoded) == 'table' and decoded.number == tonumber(number) then
            data = decoded
            cache[key] = { data = data, time = vim.uv.now() }
          else
            err = 'could not parse gh output'
          end
        end
        for _, item in ipairs(request.listeners) do
          if item.callback then
            item.callback(err, data)
          end
        end
      end)
    end)
  end
  return function()
    listener.callback = nil
    -- Allow picker -> open to adopt the request before cancelling it.
    vim.defer_fn(function()
      if pending[key] ~= request then
        return
      end
      for _, item in ipairs(request.listeners) do
        if item.callback then
          return
        end
      end
      pending[key] = nil
      request.job:kill(15)
    end, 100)
  end
end

return M
