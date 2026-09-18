-- Run with the real config from a local fixture checkout. See tests/README.md.
local counts, messages = {}, {}
local original_system = vim.system
vim.system = function(cmd, opts, callback)
  if cmd[1] ~= 'gh' then
    return original_system(cmd, opts, callback)
  end
  assert(cmd[2] == 'pr' and cmd[3] == 'view', 'unexpected network command')
  local number = tonumber(cmd[4])
  counts[number] = (counts[number] or 0) + 1
  local killed = false
  vim.defer_fn(function()
    callback {
      code = killed and 143 or 0,
      stdout = vim.json.encode {
        number = number,
        title = 'Fixture ' .. number,
        body = 'Summary fixture',
        author = { login = 'tester' },
        baseRefName = 'production',
        headRefName = 'feature',
        state = 'OPEN',
        url = 'https://example.invalid/' .. number,
      },
      stderr = '',
    }
  end, 40)
  return {
    kill = function()
      killed = true
    end,
  }
end
vim.notify = function(message)
  messages[#messages + 1] = message
end
local function pr(number)
  return { number = number, title = 'Fixture ' .. number, baseRefName = 'production', headRefName = 'feature' }
end
local function summary_visible(number)
  return vim.api.nvim_buf_get_name(0):match('PR #' .. number .. '$') ~= nil
end
vim.defer_fn(function()
  local ok, err = xpcall(function()
    local review = require 'config.review'
    local start = vim.uv.hrtime()
    review.open(pr(1))
    assert(
      vim.wait(5000, function()
        return summary_visible(1)
      end),
      'populated PR summary: ' .. table.concat(messages, '\n')
    )
    local first_ms = (vim.uv.hrtime() - start) / 1e6
    assert(first_ms < 1900, 'summary still waits on fallback timer')
    local view = require('diffview.lib').get_current_view()
    assert(view and view.files:len() == 1, 'diff must contain feature change')
    view:set_file(view.panel:ordered_file_list()[1], true)
    assert(
      vim.wait(2000, function()
        return vim.api.nvim_buf_get_name(0):match 'sample.txt$' ~= nil
      end),
      'file navigation after summary'
    )
    start = vim.uv.hrtime()
    review.open(pr(2))
    assert(
      vim.wait(5000, function()
        return summary_visible(2)
      end),
      'empty PR summary'
    )
    local empty_ms = (vim.uv.hrtime() - start) / 1e6
    assert(empty_ms < 1900, 'empty PR still waits two seconds')
    review.open(pr(1))
    assert(
      vim.wait(5000, function()
        return summary_visible(1)
      end),
      'reopen summary'
    )
    assert(counts[1] == 1, 'reopen should reuse summary')
    review.info()
    assert(
      vim.wait(2000, function()
        return counts[1] == 2
      end),
      'explicit refresh'
    )
    vim.wait(100, function()
      return false
    end)
    review.open(pr(2))
    review.open(pr(1))
    assert(
      vim.wait(5000, function()
        return review.current.number == 1 and summary_visible(1)
      end),
      'latest request wins'
    )
    vim.wait(300, function()
      return false
    end)
    assert(review.current.number == 1, 'stale fetch must not replace review')
    review.open_number(2)
    review.open(pr(1))
    vim.wait(400, function()
      return false
    end)
    assert(review.current.number == 1, 'late metadata must not supersede a newer open')
    vim.o.columns = 160
    vim.o.lines = 50
    local before_picker = counts[1]
    review.show_picker({ pr(1) }, nil)
    local prompt = vim.api.nvim_get_current_buf()
    local picker = require('telescope.actions.state').get_current_picker(prompt)
    assert(
      vim.wait(2000, function()
        local buf = picker.previewer.state and picker.previewer.state.bufnr
        return buf and table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'):find 'Summary fixture'
      end),
      'real Telescope preview must render cached summary'
    )
    require('telescope.actions').select_default(prompt)
    assert(
      vim.wait(2000, function()
        return summary_visible(1)
      end),
      'picker selection opens review'
    )
    assert(counts[1] == before_picker, 'picker-to-open must reuse summary without another request')
    vim.fn.writefile(
      { ('PASS populated %.1fms; empty %.1fms; navigation, cache, refresh, latest-open, metadata race, Telescope handoff'):format(first_ms, empty_ms) },
      vim.env.REVIEW_TEST_RESULT
    )
  end, debug.traceback)
  if not ok then
    vim.fn.writefile({ err, table.concat(messages, '\n') }, vim.env.REVIEW_TEST_RESULT)
    vim.cmd 'cquit 1'
  end
  vim.cmd 'qa!'
end, 300)
